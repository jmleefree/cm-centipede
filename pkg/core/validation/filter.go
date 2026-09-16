package validation

import (
	"path"

	commonmodel "github.com/cloud-barista/cm-centipede/dmdl/common-model"
	"github.com/cloud-barista/cm-centipede/pkg/core/migration"
	"github.com/cloud-barista/cm-centipede/transx-ex"
)

// filter.go teaches validation what the migration was told to leave behind.
//
// Both ends are re-read in full, so a file the filter dropped is absent from the
// destination by design. Compared without the filter it reads as "file missing
// in destination" — the same false positive compareSchemaObjects already avoids
// on the DBMS side, one per excluded file.
//
// The rules need no plumbing: the plan stores them per folder and per bucket
// (FSMigrationInfo.Rules / OSMigrationInfo.Rules) and they arrive here inside the
// migration model. What was missing is that they were never read.
//
// ── The pipeline decides, not a copy of it ──────────────────────────────────
// Every verdict below is transx-ex's own filter.Option.Match, reached through the
// same migration.ToTransxFilter the transfer uses. Reimplementing glob or size
// semantics here would work until one of them changed.
//
// ── Where a mirror still has to be built: rsync ─────────────────────────────
// Object storage is exact — executor-s3.go calls Match per object, so asking the
// same question of the same pipeline gives the same answer by construction.
//
// A filesystem transfer is rsync, driven by translated --include/--exclude flags
// (executor-rsync.go rsyncFilterArgs), and rsync judges paths its own way. Two
// differences matter, and excludesFile reproduces both:
//
//	1. rsync matches every path COMPONENT, not just the file. An --exclude that
//	   hits a directory prunes the whole subtree, so nothing under it is ever
//	   sent. Evaluating the file path alone would call those files missing.
//	2. --max-size/--min-size are file gates and never prune a directory. So a
//	   size rule takes no part in the component walk; a rule set that excluded
//	   "< 1KB" would otherwise drop every directory (an item with Size 0) and
//	   report the entire tree as deliberately skipped.
//
// One case needs no walk at all: when the pipeline whitelists, rsyncFilterArgs
// emits --include=*/ so rsync descends into every directory to reach the included
// files. dirs is left nil then, which is the same thing said in Go.
type migrationFilter struct {
	// files judges a file or object against the whole pipeline.
	files *transxex.PathFilterOption
	// dirs judges one ancestor directory of a file. Glob rules only, and nil
	// when the pipeline whitelists or holds no glob rule at all.
	dirs *transxex.PathFilterOption
	// sized records that a size rule is present, so a caller that would have to
	// pay for file sizes only pays when they change an outcome.
	sized bool
}

// newMigrationFilter builds the verdict helper for one folder's or bucket's
// rules. A nil filter (no rules) excludes nothing, so callers need no nil check
// beyond what the methods already do.
func newMigrationFilter(rules []commonmodel.PathFilterRule) (*migrationFilter, error) {
	if len(rules) == 0 {
		return nil, nil
	}
	files, err := migration.ToTransxFilter(rules)
	if err != nil {
		return nil, err
	}

	f := &migrationFilter{files: files}

	// One pass over every rule, then decide — an early return on the first
	// include would leave a size rule below it unseen, and sized drives whether
	// the caller pays for file sizes at all.
	var globs []commonmodel.PathFilterRule
	whitelists := false
	for _, r := range rules {
		if r.Action == commonmodel.FilterActionInclude {
			whitelists = true
		}
		switch r.Type {
		case commonmodel.PathRuleSize:
			f.sized = true
		case commonmodel.PathRuleGlob:
			globs = append(globs, r)
		}
	}

	// A whitelisting pipeline is given --include=*/, so rsync descends into every
	// directory and prunes none. Only the file's own verdict counts.
	if whitelists || len(globs) == 0 {
		return f, nil
	}
	if f.dirs, err = migration.ToTransxFilter(globs); err != nil {
		return nil, err
	}
	return f, nil
}

// needsSize reports whether a size rule is in play. Without one the caller can
// skip collecting file sizes, which on the filesystem side is a second command
// on a remote host.
func (f *migrationFilter) needsSize() bool {
	return f != nil && f.sized
}

// excludesObject reports whether the filter dropped this object.
//
// The item is built exactly as executor-s3.go builds it — full key in Path, base
// name in Name — so a key is judged here the way it was judged when the transfer
// decided whether to copy it. relKey is not what the executor sees and would
// change the verdict of any pattern anchored to a full path.
func (f *migrationFilter) excludesObject(key string, size int64) bool {
	if f == nil || f.files == nil {
		return false
	}
	return !f.files.Match(transxex.PathFilterItem{
		Path: key,
		Name: path.Base(key),
		Size: size,
	})
}

// excludesFile reports whether the filter kept this file out of the transfer.
// relPath is relative to the migrated folder, which is the path rsync matches
// its patterns against.
func (f *migrationFilter) excludesFile(relPath string, size int64) bool {
	if f == nil || f.files == nil {
		return false
	}
	if !f.files.Match(transxex.PathFilterItem{
		Path: relPath,
		Name: path.Base(relPath),
		Size: size,
	}) {
		return true
	}
	if f.dirs == nil {
		return false
	}
	// Walk the ancestors: one pruned directory takes everything beneath it.
	for dir := path.Dir(relPath); dir != "." && dir != "/" && dir != ""; dir = path.Dir(dir) {
		if !f.dirs.Match(transxex.PathFilterItem{
			Path:  dir,
			Name:  path.Base(dir),
			IsDir: true,
		}) {
			return true
		}
	}
	return false
}
