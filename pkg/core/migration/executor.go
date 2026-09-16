package migration

import (
	"context"
	"errors"
	"fmt"
	"github.com/cloud-barista/cm-centipede/transx-ex"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/rs/zerolog/log"

	targetmodel "github.com/cloud-barista/cm-centipede/dmdl/target-model"
	"github.com/cloud-barista/cm-centipede/pkg/api/rest/model"
	"github.com/cloud-barista/cm-centipede/pkg/dao"
)

// Executor manages the lifecycle of asynchronous migration runs.
type Executor struct {
	mu      sync.Mutex
	cancels map[string]context.CancelFunc
}

// DefaultExecutor is the package-level singleton used by API handlers.
var DefaultExecutor = &Executor{
	cancels: make(map[string]context.CancelFunc),
}

// Execute loads the migration from DB, runs all plan items in sequence, and
// updates Migration status and progress after each item completes.
// Must be launched as a goroutine: go DefaultExecutor.Execute(id)
func (e *Executor) Execute(migrationID string) {
	ctx, cancel := context.WithCancel(context.Background())
	e.mu.Lock()
	e.cancels[migrationID] = cancel
	e.mu.Unlock()
	defer func() {
		cancel()
		e.mu.Lock()
		delete(e.cancels, migrationID)
		e.mu.Unlock()
	}()

	m, err := dao.GetMigration(migrationID)
	if err != nil {
		log.Error().Str("migrationID", migrationID).Err(err).Msg("execute: load migration failed")
		return
	}

	now := time.Now()
	m.Status = "running"
	m.StartedAt = &now
	m.TotalItems = countPlanItems(m.Plan)
	if err := dao.UpdateMigrationStatus(m); err != nil {
		log.Error().Str("migrationID", migrationID).Err(err).Msg("execute: set status=running failed")
		return
	}
	log.Info().Str("migrationID", migrationID).Int64("totalItems", m.TotalItems).Msg("migration execution started")

	prop := m.Plan.TargetDataMigrationModel
	var hasFailure bool

	for i := range prop.FileSystems {
		if ctx.Err() != nil {
			break
		}
		fs := prop.FileSystems[i]
		progressCh := make(chan ProgressEvent, 32)
		go func() {
			defer close(progressCh)
			_ = MigrateFileSystem(ctx, fs, progressCh)
		}()
		if e.drainProgress(m, migrationID, progressCh) {
			hasFailure = true
		}
	}

	for i := range prop.ObjectStorages {
		if ctx.Err() != nil {
			break
		}
		oss := prop.ObjectStorages[i]
		progressCh := make(chan ProgressEvent, 32)
		go func() {
			defer close(progressCh)
			_ = MigrateObjectStorage(ctx, oss, progressCh)
		}()
		if e.drainProgress(m, migrationID, progressCh) {
			hasFailure = true
		}
	}

	for i := range prop.Databases {
		if ctx.Err() != nil {
			break
		}
		dbEntry := prop.Databases[i]
		progressCh := make(chan ProgressEvent, 4)
		go func() {
			defer close(progressCh)
			_ = MigrateDBMS(ctx, dbEntry, m.DBMSOnFailure, progressCh)
		}()
		if e.drainProgress(m, migrationID, progressCh) {
			hasFailure = true
		}
	}

	completedAt := time.Now()
	m.CompletedAt = &completedAt
	switch {
	case ctx.Err() != nil:
		m.Status = "cancelled"
	case hasFailure:
		m.Status = "failed"
	default:
		m.Status = "completed"
	}
	if err := dao.UpdateMigrationStatus(m); err != nil {
		log.Error().Str("migrationID", migrationID).Err(err).Msg("execute: set final status failed")
	}
	log.Info().Str("migrationID", migrationID).Str("status", m.Status).Msg("migration execution finished")
}

// drainProgress consumes all ProgressEvents from progressCh, writes a MigrationLog
// per event, updates the in-memory migration counters, and saves progress to DB.
// Returns true if any event carried status "failed".
func (e *Executor) drainProgress(m *model.Migration, migrationID string, progressCh <-chan ProgressEvent) (hadFailure bool) {
	for ev := range progressCh {
		m.ProcessedItems++
		m.TransferredBytes += ev.SizeBytes
		if ev.Status == "failed" {
			m.FailedItems++
			hadFailure = true
		}

		var errMsg string
		if ev.Err != nil {
			errMsg = ev.Err.Error()
		}
		objKind, objName := failedObject(ev.Err)
		entry := &model.MigrationLog{
			MigrationID:      migrationID,
			ItemPath:         ev.ItemPath,
			Status:           ev.Status,
			ErrorMsg:         errMsg,
			FailedObjectKind: objKind,
			FailedObjectName: objName,
			SizeBytes:        ev.SizeBytes,
			DurationMs:       ev.DurationMs,
		}
		if err := dao.CreateMigrationLog(entry); err != nil {
			log.Error().Str("migrationID", migrationID).Str("itemPath", ev.ItemPath).Err(err).Msg("execute: create log failed")
		}
		if err := dao.UpdateMigrationStatus(m); err != nil {
			log.Error().Str("migrationID", migrationID).Err(err).Msg("execute: update progress failed")
		}
	}
	return
}

// countPlanItems returns the total migration item count in the plan.
// Each folder, bucket and database counts as one item.
func countPlanItems(plan targetmodel.TargetDataMigrationModel) int64 {
	var total int64
	prop := plan.TargetDataMigrationModel
	for _, fs := range prop.FileSystems {
		total += int64(len(fs.Folders))
	}
	for _, oss := range prop.ObjectStorages {
		total += int64(len(oss.Buckets))
	}
	// A DBMS model holds a connection pair and every database migrated under it,
	// so the item count is the databases, not the models.
	for _, db := range prop.Databases {
		total += int64(len(db.Databases))
	}
	return total
}

// Cancel signals the running migration to stop. The Execute goroutine sets
// Migration.Status = "cancelled" after the current item completes.
// Returns an error if the migration is not currently running.
func (e *Executor) Cancel(migrationID string) error {
	e.mu.Lock()
	cancel, ok := e.cancels[migrationID]
	e.mu.Unlock()
	if !ok {
		return fmt.Errorf("migration %s is not running", migrationID)
	}
	cancel()
	return nil
}

// Retry creates a new Migration that re-runs items from the original migration
// according to retryMode, then launches retryRun as a goroutine.
//
// retryMode "" or "partial": re-run only failed items; DBMS targets are DROP-ped first.
// retryMode "full": re-run all plan items; DBMS targets are DROP-ped first.
//
// Returns an error if the original migration is not in "failed" or "cancelled" status,
// or if retryMode is not one of the accepted values.
func (e *Executor) Retry(migrationID, retryMode string) (*model.Migration, error) {
	if retryMode == "" {
		retryMode = "partial"
	}
	if retryMode != "partial" && retryMode != "full" {
		return nil, fmt.Errorf("invalid retryMode %q: must be \"partial\" or \"full\"", retryMode)
	}

	orig, err := dao.GetMigration(migrationID)
	if err != nil {
		return nil, fmt.Errorf("load migration %s: %w", migrationID, err)
	}
	if orig.Status != "failed" && orig.Status != "cancelled" {
		return nil, fmt.Errorf("migration %s has status %q: must be failed or cancelled to retry", migrationID, orig.Status)
	}

	var failedPaths map[string]bool
	if retryMode == "partial" {
		logs, err := dao.ListAllMigrationLog(migrationID, "failed")
		if err != nil {
			return nil, fmt.Errorf("list failed logs: %w", err)
		}
		failedPaths = make(map[string]bool, len(logs))
		for _, l := range logs {
			failedPaths[l.ItemPath] = true
		}
	}

	newID := uuid.New().String()
	newMig := &model.Migration{
		ID:          newID,
		Name:        fmt.Sprintf("%s (retry-%s)", orig.Name, newID[:8]),
		Description: orig.Description,
		Plan:        orig.Plan,
		// Carried over: a retry of a migration asked to keep its failures must not
		// quietly start cleaning them up. retryMode governs what is cleared *before*
		// the retry runs; this governs what happens if the retry fails too.
		DBMSOnFailure: orig.DBMSOnFailure,
		Status:        "pending",
	}
	if err := dao.CreateMigration(newMig); err != nil {
		return nil, fmt.Errorf("create retry migration: %w", err)
	}

	go e.retryRun(newMig.ID, retryMode, failedPaths)

	return newMig, nil
}

// retryRun is the goroutine launched by Retry. It re-executes plan items according
// to retryMode, performing a best-effort DROP of DBMS targets before each DBMS item.
// failedPaths is non-nil only for partial mode (contains ItemPaths that failed in the
// original migration).
func (e *Executor) retryRun(migrationID, retryMode string, failedPaths map[string]bool) {
	ctx, cancel := context.WithCancel(context.Background())
	e.mu.Lock()
	e.cancels[migrationID] = cancel
	e.mu.Unlock()
	defer func() {
		cancel()
		e.mu.Lock()
		delete(e.cancels, migrationID)
		e.mu.Unlock()
	}()

	m, err := dao.GetMigration(migrationID)
	if err != nil {
		log.Error().Str("migrationID", migrationID).Err(err).Msg("retryRun: load migration failed")
		return
	}

	now := time.Now()
	m.Status = "running"
	m.StartedAt = &now
	if retryMode == "full" {
		m.TotalItems = countPlanItems(m.Plan)
	}
	if err := dao.UpdateMigrationStatus(m); err != nil {
		log.Error().Str("migrationID", migrationID).Err(err).Msg("retryRun: set status=running failed")
		return
	}
	log.Info().Str("migrationID", migrationID).Str("retryMode", retryMode).Msg("retry execution started")

	prop := m.Plan.TargetDataMigrationModel
	var hasFailure bool

	// ── File Systems ──────────────────────────────────────────────────────────
	for i := range prop.FileSystems {
		if ctx.Err() != nil {
			break
		}
		fs := prop.FileSystems[i]

		if retryMode == "partial" {
			var filtered []targetmodel.FSMigrationInfo
			for _, folder := range fs.Folders {
				if failedPaths[folder.SrcPath] {
					filtered = append(filtered, folder)
				}
			}
			if len(filtered) == 0 {
				continue
			}
			fs.Folders = filtered
			m.TotalItems += int64(len(filtered))
		}

		progressCh := make(chan ProgressEvent, 32)
		go func() {
			defer close(progressCh)
			_ = MigrateFileSystem(ctx, fs, progressCh)
		}()
		if e.drainProgress(m, migrationID, progressCh) {
			hasFailure = true
		}
	}

	// ── Object Storages ───────────────────────────────────────────────────────
	for i := range prop.ObjectStorages {
		if ctx.Err() != nil {
			break
		}
		oss := prop.ObjectStorages[i]

		if retryMode == "partial" {
			var filtered []targetmodel.ObjectMigrationInfo
			for _, bucket := range oss.Buckets {
				if failedPaths[bucket.SrcPath] {
					filtered = append(filtered, bucket)
				}
			}
			if len(filtered) == 0 {
				continue
			}
			oss.Buckets = filtered
			m.TotalItems += int64(len(filtered))
		}

		progressCh := make(chan ProgressEvent, 32)
		go func() {
			defer close(progressCh)
			_ = MigrateObjectStorage(ctx, oss, progressCh)
		}()
		if e.drainProgress(m, migrationID, progressCh) {
			hasFailure = true
		}
	}

	// ── DBMS ──────────────────────────────────────────────────────────────────
	// One model holds a connection pair and every database migrated under it, so
	// the retry set is chosen per database item and the model is narrowed to it.
	for i := range prop.Databases {
		if ctx.Err() != nil {
			break
		}
		dbEntry := prop.Databases[i]
		dbType := string(dbEntry.DBType)

		var selected []targetmodel.DBMigrationInfo
		rollbackOf := map[string]rollbackOutcome{}

		for _, d := range dbEntry.Databases {
			itemPath := fmt.Sprintf("%s/%s", dbType, d.SrcName)
			if retryMode == "partial" && !failedPaths[itemPath] {
				continue
			}

			dstName := d.DstName
			if dstName == "" {
				dstName = d.SrcName
			}
			dstLoc, err := ResolveDBMSLocation(dbEntry.DstConnection, dstName, dbType)
			if err != nil {
				log.Error().Str("migrationID", migrationID).Str("itemPath", itemPath).Err(err).
					Msg("retryRun: resolve DBMS dst failed; skipping item")
				hasFailure = true
				continue
			}
			// The rollback below has to reach exactly the schemas the migration
			// wrote to, and no others: without this it would enumerate every
			// schema in the target database and drop objects it never created.
			srcSchemas, dstSchemas := splitPgSchemas(d.PgSchemas)
			dstLoc.PgSchema = dstSchemas
			if len(dstLoc.PgSchema) == 0 {
				dstLoc.PgSchema = srcSchemas
			}

			if retryMode == "partial" {
				m.TotalItems++
			}

			// A target database left over from the previous attempt still holds
			// what that attempt wrote, and a migration refuses a non-empty
			// target — so empty it first. A database the previous attempt
			// dropped is simply absent, and the migration creates it again.
			out := rollbackOutcome{status: "success"}
			exists, err := TargetDatabaseExists(dbEntry.DstConnection, dstLoc)
			switch {
			case err != nil:
				out.status = "failed"
				out.errMsg = err.Error()
			case exists:
				if dropErr := transxex.RollbackDropDBMS(dstLoc); dropErr != nil {
					out.status = "failed"
					out.errMsg = dropErr.Error()
					log.Warn().
						Str("migrationID", migrationID).
						Str("itemPath", itemPath).
						Err(dropErr).
						Msg("retryRun: DBMS rollback drop failed; item will be skipped")
				}
			default:
				// Nothing to empty; the migration re-creates the database.
				out.status = "skipped"
			}

			if out.status == "failed" {
				m.ProcessedItems++
				m.FailedItems++
				hasFailure = true
				if err := dao.CreateMigrationLog(&model.MigrationLog{
					MigrationID:      migrationID,
					ItemPath:         itemPath,
					Status:           "skipped",
					RollbackStatus:   "failed",
					RollbackErrorMsg: out.errMsg,
				}); err != nil {
					log.Error().Str("migrationID", migrationID).Str("itemPath", itemPath).Err(err).Msg("retryRun: create rollback-failed log failed")
				}
				if err := dao.UpdateMigrationStatus(m); err != nil {
					log.Error().Str("migrationID", migrationID).Err(err).Msg("retryRun: update progress failed")
				}
				continue
			}

			rollbackOf[itemPath] = out
			selected = append(selected, d)
		}

		if len(selected) == 0 {
			continue
		}
		dbEntry.Databases = selected

		progressCh := make(chan ProgressEvent, 8)
		go func() {
			defer close(progressCh)
			_ = MigrateDBMS(ctx, dbEntry, m.DBMSOnFailure, progressCh)
		}()
		if e.drainProgressWithRollback(m, migrationID, progressCh, rollbackOf) {
			hasFailure = true
		}
	}

	completedAt := time.Now()
	m.CompletedAt = &completedAt
	switch {
	case ctx.Err() != nil:
		m.Status = "cancelled"
	case hasFailure:
		m.Status = "failed"
	default:
		m.Status = "completed"
	}
	if err := dao.UpdateMigrationStatus(m); err != nil {
		log.Error().Str("migrationID", migrationID).Err(err).Msg("retryRun: set final status failed")
	}
	log.Info().Str("migrationID", migrationID).Str("status", m.Status).Msg("retry execution finished")
}

// rollbackOutcome records what the pre-retry cleanup did to one database item.
type rollbackOutcome struct {
	status string // "success" | "failed" | "skipped"
	errMsg string
}

// rollbackStatusFor reports how the cleanup of a centipede-created database
// ended, inferred from the item's own outcome: a successful item was never
// cleaned up, and a failed or cancelled one had its database dropped.
//
// keep is the migration's dbmsOnFailure=keep setting. Under it a failed item is
// left standing on purpose, so the honest answer is "skipped" — reporting
// "success" would describe a drop that deliberately did not happen.
func rollbackStatusFor(ev ProgressEvent, keep bool) string {
	if ev.Status == "success" {
		return ""
	}
	if keep && ev.Status == "failed" {
		return "skipped"
	}
	return "success"
}

// failedObject pulls the object transx-ex was working on out of a failed item's
// error, so a MigrationLog can name it in its own fields instead of only inside
// the message.
//
// The kind and the name are reported separately, but the name keeps its
// enclosing database, schema or bucket when transx-ex knew one: a bare "orders"
// is ambiguous across the several databases one migration can touch.
//
// A failure with no single object behind it — a refused connection, a dump
// command that failed whole — yields two empty strings, which is the honest
// answer rather than a guess at the last object seen.
func failedObject(err error) (kind, name string) {
	var oe *transxex.ObjectError
	if err == nil || !errors.As(err, &oe) {
		return "", ""
	}
	name = oe.Name
	if name != "" && oe.Owner != "" {
		name = oe.Owner + "." + name
	}
	return oe.Kind, name
}

// drainProgressWithRollback is like drainProgress but additionally stamps
// RollbackStatus and RollbackErrorMsg on every created MigrationLog.
// Used for DBMS retry items where a DROP was attempted before migration.
func (e *Executor) drainProgressWithRollback(m *model.Migration, migrationID string, progressCh <-chan ProgressEvent, rollbackOf map[string]rollbackOutcome) (hadFailure bool) {
	for ev := range progressCh {
		m.ProcessedItems++
		m.TransferredBytes += ev.SizeBytes
		if ev.Status == "failed" {
			m.FailedItems++
			hadFailure = true
		}

		var errMsg string
		if ev.Err != nil {
			errMsg = ev.Err.Error()
		}
		// A database centipede created is dropped whole on failure, so the
		// event's own outcome supersedes what the pre-retry cleanup did.
		rb := rollbackOf[ev.ItemPath]
		if ev.TargetCreated {
			rb = rollbackOutcome{status: rollbackStatusFor(ev, m.DBMSOnFailure == model.DBMSOnFailureKeep)}
		}
		objKind, objName := failedObject(ev.Err)
		entry := &model.MigrationLog{
			MigrationID:      migrationID,
			ItemPath:         ev.ItemPath,
			Status:           ev.Status,
			ErrorMsg:         errMsg,
			FailedObjectKind: objKind,
			FailedObjectName: objName,
			SizeBytes:        ev.SizeBytes,
			DurationMs:       ev.DurationMs,
			TargetCreated:    ev.TargetCreated,
			RollbackStatus:   rb.status,
			RollbackErrorMsg: rb.errMsg,
		}
		if err := dao.CreateMigrationLog(entry); err != nil {
			log.Error().Str("migrationID", migrationID).Str("itemPath", ev.ItemPath).Err(err).Msg("retryRun: create log failed")
		}
		if err := dao.UpdateMigrationStatus(m); err != nil {
			log.Error().Str("migrationID", migrationID).Err(err).Msg("retryRun: update progress failed")
		}
	}
	return
}
