package plan

import (
	"fmt"
	"strings"

	"github.com/cloud-barista/cm-centipede/transx-ex"
	"github.com/rs/zerolog/log"

	commonmodel "github.com/cloud-barista/cm-centipede/dmdl/common-model"
	targetmodel "github.com/cloud-barista/cm-centipede/dmdl/target-model"
	"github.com/cloud-barista/cm-centipede/pkg/api/rest/model"
	"github.com/cloud-barista/cm-centipede/pkg/client/beetle"
	"github.com/cloud-barista/cm-centipede/pkg/client/honeybee"
	"github.com/cloud-barista/cm-centipede/pkg/core/migration"
)

// ValidationError is returned for logical plan validation failures (400).
// External-system errors (honeybee/beetle unreachable) are returned as plain errors (500).
type ValidationError struct{ msg string }

func (e *ValidationError) Error() string { return e.msg }

func validationErr(format string, args ...any) *ValidationError {
	return &ValidationError{msg: fmt.Sprintf(format, args...)}
}

// dataKind is the normalised connection-type category used for type-match validation.
type dataKind string

const (
	kindSSH           dataKind = "ssh"
	kindObjectStorage dataKind = "objectStorage"
	kindDBMS          dataKind = "dbms"
)

// dstKind resolves the dataKind of the destination ConnectionRef.
// For honeybee destinations the honeybee API is called each time.
func dstKind(ref commonmodel.ConnectionRef) (dataKind, error) {
	switch ref.Source {
	case commonmodel.ConnectionSourceBeetleSSH, commonmodel.ConnectionSourceSSH:
		return kindSSH, nil
	case commonmodel.ConnectionSourceBeetleObjectStorage, commonmodel.ConnectionSourceMinio:
		return kindObjectStorage, nil
	case commonmodel.ConnectionSourceBeetleDB, commonmodel.ConnectionSourceDB:
		return kindDBMS, nil
	case commonmodel.ConnectionSourceHoneybee:
		cfg, err := honeybee.GetConnectionInfo(*ref.Honeybee)
		if err != nil {
			return "", fmt.Errorf("get honeybee connection info: %w", err)
		}
		switch cfg.ConnType {
		case honeybee.ConnTypeSSH:
			return kindSSH, nil
		case honeybee.ConnTypeObjectStorage:
			return kindObjectStorage, nil
		case honeybee.ConnTypeDBMS:
			return kindDBMS, nil
		default:
			return "", fmt.Errorf("unrecognised honeybee connection type %q", cfg.ConnType)
		}
	}
	return "", fmt.Errorf("unknown connection source %q", ref.Source)
}

// dbmsIdentity holds the normalised DBMS engine type needed for validation.
type dbmsIdentity struct {
	dbType string // "mysql" | "mariadb" | "postgresql" | "mongodb"
}

// dbmsIdentityOf extracts the DBMS identity (engine type) from a DBMS
// ConnectionRef. honeybee carries the engine in its config; beetleDb is a
// managed cloud RDB whose engine comes from cm-beetle; db is inline.
func dbmsIdentityOf(ref commonmodel.ConnectionRef) (dbmsIdentity, error) {
	switch ref.Source {
	case commonmodel.ConnectionSourceHoneybee:
		cfg, err := honeybee.GetConnectionInfo(*ref.Honeybee)
		if err != nil {
			return dbmsIdentity{}, fmt.Errorf("get honeybee config for DB: %w", err)
		}
		return dbmsIdentity{dbType: cfg.DBType}, nil

	case commonmodel.ConnectionSourceBeetleDB:
		if ref.BeetleDB == nil {
			return dbmsIdentity{}, fmt.Errorf("beetleDb ref is nil")
		}
		acc, err := beetle.GetRDBMSAccessInfo(*ref.BeetleDB)
		if err != nil {
			return dbmsIdentity{}, err
		}
		return dbmsIdentity{dbType: acc.DBType}, nil

	case commonmodel.ConnectionSourceDB:
		if ref.DB == nil {
			return dbmsIdentity{}, fmt.Errorf("db config is nil")
		}
		return dbmsIdentity{dbType: ref.DB.DBMSType}, nil
	}
	return dbmsIdentity{}, fmt.Errorf("connection source %q is not a DBMS type", ref.Source)
}

// validateDBMSEngines rejects a heterogeneous pair up front. transx-ex refuses
// one too, but saying so at plan time costs nothing and reads better.
func validateDBMSEngines(srcRef, dstRef commonmodel.ConnectionRef) (string, error) {
	srcID, err := dbmsIdentityOf(srcRef)
	if err != nil {
		return "", fmt.Errorf("source DB identity: %w", err)
	}
	dstID, err := dbmsIdentityOf(dstRef)
	if err != nil {
		return "", fmt.Errorf("target DB identity: %w", err)
	}
	if srcID.dbType != "" && dstID.dbType != "" && srcID.dbType != dstID.dbType {
		return "", validationErr("dbType mismatch: source=%q target=%q (cross-DBMS migration is not supported)",
			srcID.dbType, dstID.dbType)
	}
	return srcID.dbType, nil
}

// validateDBMSVersion asks transx-ex whether the target can accept a dump taken
// from the source. transx-ex runs the same check for itself just before a
// migration starts; calling it here only moves the answer forward to plan time.
//
// A pair transx-ex cannot compare is reported rather than judged: a version it
// could not parse is not evidence of anything, so the plan proceeds.
func validateDBMSVersion(srcRef, dstRef commonmodel.ConnectionRef, database, dbType string) error {
	srcLoc, err := migration.ResolveDBMSLocation(srcRef, database, dbType)
	if err != nil {
		return fmt.Errorf("resolve source DB location: %w", err)
	}
	dstLoc, err := migration.ResolveDBMSLocation(dstRef, database, dbType)
	if err != nil {
		return fmt.Errorf("resolve target DB location: %w", err)
	}

	vc, err := transxex.CheckVersion(srcLoc, dstLoc)
	if err != nil {
		log.Warn().Err(err).Msg("cannot read both server versions; skipping the version check")
		return nil
	}
	if vc.Downgrade {
		return validationErr(
			"target DB version %q is older than source %q (downgrade migration is not supported)",
			vc.Target, vc.Source)
	}
	if !vc.Comparable {
		log.Debug().
			Str("srcVer", vc.Source).Str("dstVer", vc.Target).
			Msg("server versions are not comparable; skipping the version check")
	}
	return nil
}

// validateDBMSTargetReachable checks, at plan time, that every target database
// this plan needs either exists already or can be created (see
// migration.EnsureTargetDatabase). Creation is centipede's responsibility, and
// the conditions on it are knowable before the migration runs.
func validateDBMSTargetReachable(dstRef commonmodel.ConnectionRef, dstLoc transxex.DBMSLocation) error {
	switch dstRef.Source {
	case commonmodel.ConnectionSourceBeetleDB, commonmodel.ConnectionSourceDB:
	default:
		// honeybee is a source-only connection.
		return validationErr("connection source %q cannot be a DBMS migration target", dstRef.Source)
	}

	exists, err := migration.TargetDatabaseExists(dstRef, dstLoc)
	if err != nil {
		log.Warn().Err(err).Msg("cannot list target databases; deferring the creation check to execution")
		return nil
	}
	if exists {
		return nil // already provisioned — nothing to create
	}

	// MongoDB is exempt: there is no empty database to provision, and no way to
	// ask for one. A MongoDB database begins to exist when its first collection is
	// written, so it cannot be listed beforehand and cannot be "provisioned on the
	// provider first" - a managed MongoDB offers no create-database API (NCP has
	// none), and neither does the wire protocol. transx-ex says the same thing
	// from its own side: CreateDatabase for MongoDB logs "no-op without a
	// collection to create" and returns, so even the onprem branch below would
	// create nothing. The restore brings the database into existence by writing
	// into it, which is the only way there is.
	if dstLoc.DBMSType == transxex.DBMSTypeMongoDB {
		return nil
	}

	switch dstRef.Source {
	case commonmodel.ConnectionSourceBeetleDB:
		// cm-beetle creates a logical database inside the managed instance, so
		// an absent one is not an error here.
	case commonmodel.ConnectionSourceDB:
		if dstRef.DB == nil || !strings.EqualFold(dstRef.DB.ProviderName, commonmodel.ProviderOnPrem) {
			return validationErr(
				"target database %q does not exist; centipede creates one only for providerName %q — provision it on the provider first",
				dstLoc.Database, commonmodel.ProviderOnPrem)
		}
	}
	return nil
}

// selectMigrationPath resolves the single (srcPath, dstPath) to migrate for one
// source entry. scanRoot is the FSInfo/ObjectStorageInfo.Path (topmost folder);
// folders are the child folder/bucket paths listed under it.
//
//   - tm == nil            → migrate the scan root (topmost) to the same path.
//   - tm.SrcName matches   → migrate that path; DstName empty falls back to SrcName.
//     (matched against the scan root or any listed folder)
//   - no match             → ok=false; the caller reports a 400.
func selectMigrationPath(scanRoot string, folders []string, tm *commonmodel.TargetMapping) (src, dst string, ok bool) {
	if tm == nil {
		return scanRoot, scanRoot, true
	}
	candidates := append([]string{scanRoot}, folders...)
	for _, c := range candidates {
		if c == tm.SrcName {
			if tm.DstName != "" {
				return tm.SrcName, tm.DstName, true
			}
			return tm.SrcName, tm.SrcName, true
		}
	}
	return "", "", false
}

// resolveObjectStorageDstPath returns the DstPath an object storage destination
// should carry, given the one the mapping produced.
//
// For a beetleObjectStorage destination the bucket is decided by osId, and the
// first segment of DstPath is discarded: transx-ex builds its Tumblebug provider
// from the nsId/osId pair and never passes that segment to it (NewS3Provider
// checks only that it is non-empty, then calls NewTumblebugProvider without it),
// while the executor uses what follows it as the key prefix.
//
// Left as it comes out of the mapping, that segment is the *source* bucket's
// name — a bucket nothing writes to, printed in the plan and stored in the
// migration record as though it were the target. So an unmapped destination
// takes the osId instead.
//
// The transfer is unchanged: "raw-data/" and "cpbt-aws-bucket" both parse to an
// empty key prefix, and validation reads DstPath the same way transfer does.
// What changes is that the plan names the bucket the objects land in, and that a
// caller wanting a prefix writes "<osId>/archive/" rather than a source bucket
// name it does not mean.
//
// Two things are deliberately left alone:
//   - a DstName the caller supplied — the prefix is theirs to choose;
//   - every other destination — for minio and honeybee targets the first
//     segment IS the bucket, so rewriting it would retarget the transfer.
func resolveObjectStorageDstPath(dst commonmodel.ConnectionRef, tm *commonmodel.TargetMapping, dstPath string) string {
	if dst.Source != commonmodel.ConnectionSourceBeetleObjectStorage || dst.BeetleOS == nil {
		return dstPath
	}
	if tm != nil && strings.TrimSpace(tm.DstName) != "" {
		return dstPath
	}
	return dst.BeetleOS.OsID
}

// validateStorageMapping rejects a mapping that names nothing, or that carries
// PostgreSQL schema pairs where they have no meaning.
func validateStorageMapping(domain string, tm *commonmodel.TargetMapping) error {
	if tm == nil {
		return nil
	}
	if strings.TrimSpace(tm.SrcName) == "" {
		return validationErr("%s targetMapping.srcName is required when a filter is supplied", domain)
	}
	if len(tm.PgSchemas) > 0 {
		return validationErr("%s targetMapping.pgSchemas is DBMS-only", domain)
	}
	return nil
}

// validateRsyncCompatibleRules rejects path-filter rules that cannot be expressed
// as native rsync arguments. filesystem→objectstorage transfers apply the source
// filter on the rsync (ssh→local) relay step, where rsync supports size filters
// only as an "exclude" with a >/>=/</<= threshold; glob rules are always supported.
// (objectstorage→filesystem is unaffected — its filter runs on the S3 side.)
// validateSizeGateOrdering rejects a filesystem rule list whose result would
// depend on an ordering rsync does not have.
//
// The pipeline is first-match-wins: an "include" stops evaluation, so a rule
// below it never runs. rsync has no such precedence for size — --max-size and
// --min-size are GLOBAL gates applied to every file, independent of the
// --include/--exclude list and of where the rule sat. So a pipeline like
//
//	include glob  *.keep
//	exclude size  > 1048576
//
// keeps a 2 MB "backup.keep" when the pipeline is read in order, and drops it
// when rsync runs it. The plan would say one thing and the transfer do another,
// and validation — which reads the plan — would then report the file as missing
// from the destination.
//
// Only an include ABOVE a size rule is ambiguous. Below one it is unreachable
// for anything the size rule already matched, which is what rsync does too, so
// the two agree and the order is left alone.
func validateSizeGateOrdering(rules []commonmodel.PathFilterRule) error {
	seenInclude := false
	for _, r := range rules {
		if r.Action == commonmodel.FilterActionInclude {
			seenInclude = true
			continue
		}
		if seenInclude && r.Type == commonmodel.PathRuleSize {
			return validationErr(
				"fileSystemFilter: a size rule below an include rule is ambiguous — rsync applies size as a global gate, so the include cannot keep a file the size rule matches. Move the size rule above every include, or express the limit as a glob rule")
		}
	}
	return nil
}

func validateRsyncCompatibleRules(rules []commonmodel.PathFilterRule) error {
	for _, r := range rules {
		if r.Type != "size" {
			continue
		}
		if r.Action != "exclude" {
			return validationErr(
				"filesystem→objectstorage does not support a size filter with action %q (rsync supports size only as 'exclude'); use glob or an objectstorage source", r.Action)
		}
		switch r.Op {
		case ">", ">=", "<", "<=":
		default:
			return validationErr(
				"filesystem→objectstorage does not support size filter op %q (rsync supports only > >= < <=)", r.Op)
		}
	}
	return nil
}

// buildDBMigrationInfos turns the request's per-database filter entries into the
// execution items for one source connection's databases.
//
// With no filter every source database migrates under its own name with no
// rules. With one, only the databases it names migrate — the entries are a
// selection as much as a rule set — and every name must match a database the
// source actually holds.
func buildDBMigrationInfos(
	available []string,
	dbType string,
	filter *commonmodel.DBMSFilter,
) ([]targetmodel.DBMigrationInfo, error) {

	if filter == nil || len(filter.Databases) == 0 {
		out := make([]targetmodel.DBMigrationInfo, 0, len(available))
		for i, name := range available {
			out = append(out, targetmodel.DBMigrationInfo{
				Order:   i + 1,
				SrcName: name,
				DstName: name,
			})
		}
		return out, nil
	}

	have := make(map[string]bool, len(available))
	for _, n := range available {
		have[n] = true
	}

	seenSrc := make(map[string]bool, len(filter.Databases))
	seenDst := make(map[string]bool, len(filter.Databases))
	out := make([]targetmodel.DBMigrationInfo, 0, len(filter.Databases))

	for _, e := range filter.Databases {
		srcName := strings.TrimSpace(e.TargetMapping.SrcName)
		if srcName == "" {
			return nil, validationErr("dbmsFilter.databases[].targetMapping.srcName is required")
		}
		if !have[srcName] {
			// Only report a mismatch against a connection that actually lists
			// databases; a source that listed none is filtered elsewhere.
			return nil, validationErr("targetMapping.srcName %q matches no database in the source model", srcName)
		}
		if seenSrc[srcName] {
			return nil, validationErr("duplicate targetMapping.srcName %q in dbmsFilter.databases", srcName)
		}
		seenSrc[srcName] = true

		dstName := strings.TrimSpace(e.TargetMapping.DstName)
		if dstName == "" {
			dstName = srcName
		}
		if seenDst[dstName] {
			return nil, validationErr(
				"duplicate targetMapping.dstName %q in dbmsFilter.databases (merging databases is not supported)", dstName)
		}
		seenDst[dstName] = true

		if err := validatePgSchemas(dbType, srcName, e.TargetMapping.PgSchemas); err != nil {
			return nil, err
		}

		out = append(out, targetmodel.DBMigrationInfo{
			Order:     len(out) + 1,
			SrcName:   srcName,
			DstName:   dstName,
			PgSchemas: e.TargetMapping.PgSchemas,
			Rules:     e.Rules,
		})
	}
	return out, nil
}

// validatePgSchemas checks the PostgreSQL schema pairs of one database entry.
// The names themselves are matched against the source inventory by the caller's
// discovery result only when one is available; what is always checkable is the
// engine and the shape of the pairing.
func validatePgSchemas(dbType, database string, pairs []commonmodel.PgSchemaMapping) error {
	if len(pairs) == 0 {
		return nil
	}
	if dbType != string(commonmodel.DBMSTypePostgreSQL) {
		return validationErr("pgSchemas is PostgreSQL-only, but database %q is %s", database, dbType)
	}
	seenSrc := make(map[string]bool, len(pairs))
	seenDst := make(map[string]bool, len(pairs))
	for _, p := range pairs {
		src := strings.TrimSpace(p.SrcName)
		if src == "" {
			return validationErr("pgSchemas[].srcName is required (database %q)", database)
		}
		if seenSrc[src] {
			return validationErr("duplicate pgSchemas[].srcName %q (database %q)", src, database)
		}
		seenSrc[src] = true

		dst := strings.TrimSpace(p.DstName)
		if dst == "" {
			dst = src
		}
		if seenDst[dst] {
			return validationErr(
				"duplicate pgSchemas[].dstName %q (database %q); merging schemas is not supported", dst, database)
		}
		seenDst[dst] = true
	}
	return nil
}

// BuildTargetDataMigrationModel validates the plan request and builds the
// TargetDataMigrationModel from the source discovery results and filter options.
//
// Validation errors (→ 400 in the controller):
//   - unsupported source/target type combination (DBMS is same-type only;
//     filesystem↔objectstorage cross-storage is allowed)
//   - DBMS engine mismatch, or a target older than the source
//   - a target database that neither exists nor can be created
//   - filesystem→objectstorage with an rsync-incompatible size filter
//
// External-system errors (→ 500 in the controller) are wrapped and returned as-is.
func BuildTargetDataMigrationModel(req model.TargetPlanReq) (targetmodel.TargetDataMigrationModel, error) {
	src := req.Source.SourceDataMigrationModel

	dstType, err := dstKind(req.DstConnection)
	if err != nil {
		return targetmodel.TargetDataMigrationModel{}, fmt.Errorf("resolve destination connection type: %w", err)
	}

	var result targetmodel.TargetDataMigrationProperty

	// ── Filesystem ──────────────────────────────────────────────────────────
	// Normalise the filesystem transfer strategy; empty defaults to relay.
	fsStrategy := req.FileSystemStrategy
	if fsStrategy == "" {
		fsStrategy = commonmodel.StrategyRelay
	}
	var fsRules []commonmodel.PathFilterRule
	var fsMapping *commonmodel.TargetMapping
	if f := req.FileSystemFilter; f != nil {
		fsRules = f.Rules
		fsMapping = &f.TargetMapping
		if err := validateStorageMapping("fileSystemFilter", fsMapping); err != nil {
			return targetmodel.TargetDataMigrationModel{}, err
		}
		// Every filesystem source transfers with rsync, whichever destination it
		// lands on, so this one is checked before the destination is even known.
		if err := validateSizeGateOrdering(fsRules); err != nil {
			return targetmodel.TargetDataMigrationModel{}, err
		}
	}
	fsMatched := false
	for _, srcFS := range src.FileSystems {
		// Destination must be filesystem (SSH→SSH) or object storage (filesystem→S3
		// cross-storage). DBMS destinations are invalid for filesystem sources.
		var fsDstType string
		switch dstType {
		case kindSSH:
			fsDstType = commonmodel.StorageTypeFilesystem
		case kindObjectStorage:
			fsDstType = commonmodel.StorageTypeObjectStorage
			// filesystem→objectstorage applies the source filter on the rsync
			// (ssh→local) relay step, which cannot express every size rule.
			if err := validateRsyncCompatibleRules(fsRules); err != nil {
				return targetmodel.TargetDataMigrationModel{}, err
			}
		default:
			return targetmodel.TargetDataMigrationModel{}, validationErr(
				"source contains filesystem data but destination type is %q; filesystem source requires SSH or object storage destination", dstType)
		}

		folderPaths := make([]string, 0, len(srcFS.Folders))
		for _, entry := range srcFS.Folders {
			folderPaths = append(folderPaths, entry.Path)
		}
		srcPath, dstPath, ok := selectMigrationPath(srcFS.Path, folderPaths, fsMapping)
		if !ok {
			continue
		}
		// filesystem→objectstorage lands in a bucket too, so an unmapped DstPath
		// would otherwise carry the source *directory* ("/testdata") into the
		// bucket-name position. Same treatment, same reasons.
		dstPath = resolveObjectStorageDstPath(req.DstConnection, fsMapping, dstPath)
		fsMatched = true

		result.FileSystems = append(result.FileSystems, targetmodel.MigrationFileSystemModel{
			SrcConnection: srcFS.Connection,
			DstConnection: req.DstConnection,
			DstType:       fsDstType,
			Strategy:      fsStrategy,
			Folders: []targetmodel.FSMigrationInfo{{
				Order:   1,
				SrcPath: srcPath,
				DstPath: dstPath,
				Rules:   fsRules,
			}},
		})
	}
	if fsMapping != nil && len(src.FileSystems) > 0 && !fsMatched {
		return targetmodel.TargetDataMigrationModel{}, validationErr(
			"targetMapping.srcName %q matches no folder in the source filesystem model", fsMapping.SrcName)
	}

	// ── ObjectStorage ────────────────────────────────────────────────────────
	var osRules []commonmodel.PathFilterRule
	var osMapping *commonmodel.TargetMapping
	if f := req.ObjectStorageFilter; f != nil {
		osRules = f.Rules
		osMapping = &f.TargetMapping
		if err := validateStorageMapping("objectStorageFilter", osMapping); err != nil {
			return targetmodel.TargetDataMigrationModel{}, err
		}
	}
	osMatched := false
	for _, srcOS := range src.ObjectStorages {
		// Destination must be object storage (S3→S3) or filesystem (objectstorage→
		// filesystem cross-storage). DBMS destinations are invalid.
		var osDstType string
		switch dstType {
		case kindObjectStorage:
			osDstType = commonmodel.StorageTypeObjectStorage
		case kindSSH:
			// objectstorage→filesystem applies the source filter on the S3 download
			// step (generic matcher), so all glob/size rules are supported.
			osDstType = commonmodel.StorageTypeFilesystem
		default:
			return targetmodel.TargetDataMigrationModel{}, validationErr(
				"source contains object storage data but destination type is %q; object storage source requires object storage or SSH destination", dstType)
		}

		bucketKeys := make([]string, 0, len(srcOS.Folders))
		for _, entry := range srcOS.Folders {
			bucketKeys = append(bucketKeys, entry.Key)
		}
		srcPath, dstPath, ok := selectMigrationPath(srcOS.Path, bucketKeys, osMapping)
		if !ok {
			continue
		}
		dstPath = resolveObjectStorageDstPath(req.DstConnection, osMapping, dstPath)
		osMatched = true

		result.ObjectStorages = append(result.ObjectStorages, targetmodel.MigrationObjectStorageModel{
			SrcConnection: srcOS.Connection,
			DstConnection: req.DstConnection,
			DstType:       osDstType,
			Buckets: []targetmodel.ObjectMigrationInfo{{
				Order:   1,
				SrcPath: srcPath,
				DstPath: dstPath,
				Rules:   osRules,
			}},
		})
	}
	if osMapping != nil && len(src.ObjectStorages) > 0 && !osMatched {
		return targetmodel.TargetDataMigrationModel{}, validationErr(
			"targetMapping.srcName %q matches no bucket in the source object storage model", osMapping.SrcName)
	}

	// ── DBMS ────────────────────────────────────────────────────────────────
	if len(src.Databases) > 0 && dstType != kindDBMS {
		return targetmodel.TargetDataMigrationModel{}, validationErr(
			"source contains DBMS data but destination type is %q; DBMS→DBMS required", dstType)
	}

	// A source model already pairs one connection with the databases read through
	// it, which is the shape MigrationDBModel wants, so no regrouping is needed.
	for _, srcDB := range src.Databases {
		dbType, err := validateDBMSEngines(srcDB.Connection, req.DstConnection)
		if err != nil {
			return targetmodel.TargetDataMigrationModel{}, err
		}

		available := make([]string, 0, len(srcDB.Databases))
		for _, info := range srcDB.Databases {
			available = append(available, info.Database)
		}

		items, err := buildDBMigrationInfos(available, dbType, req.DBMSFilter)
		if err != nil {
			return targetmodel.TargetDataMigrationModel{}, err
		}
		if len(items) == 0 {
			return targetmodel.TargetDataMigrationModel{}, validationErr(
				"no database selected for migration; dbmsFilter.databases names none of the source databases")
		}

		for _, it := range items {
			if err := validateDBMSVersion(srcDB.Connection, req.DstConnection, it.SrcName, dbType); err != nil {
				return targetmodel.TargetDataMigrationModel{}, err
			}
			dstLoc, err := migration.ResolveDBMSLocation(req.DstConnection, it.DstName, dbType)
			if err != nil {
				return targetmodel.TargetDataMigrationModel{}, fmt.Errorf("resolve target DB location: %w", err)
			}
			if err := validateDBMSTargetReachable(req.DstConnection, dstLoc); err != nil {
				return targetmodel.TargetDataMigrationModel{}, err
			}
		}

		result.Databases = append(result.Databases, targetmodel.MigrationDBModel{
			SrcConnection: srcDB.Connection,
			DstConnection: req.DstConnection,
			DBType:        commonmodel.DBMSType(dbType),
			Databases:     items,
		})
	}

	return targetmodel.TargetDataMigrationModel{
		TargetDataMigrationModel: result,
	}, nil
}
