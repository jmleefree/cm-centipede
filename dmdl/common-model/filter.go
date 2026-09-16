package commonmodel

// filter.go defines centipede's own mirror of the transx-ex and dbmsx filter
// pipelines. The model package stays free of any library dependency; the core
// layer converts these mirror types into the concrete transx / dbmsx filter
// options at the call site (see core/migration).
//
// Both pipelines are ordered rule lists keyed by a "type" discriminator, so the
// mirror types are flat structs carrying every field the underlying matchers
// use. Unused fields stay zero/omitted per rule type.

// ── transx-ex filter (shared by file system and object storage) ─────────────

// Path filter actions and rule type discriminators. They name the same strings
// the transx-ex filter registry decodes, so a caller that has to branch on a
// rule — validation asking which rules can prune a directory, for one — does it
// without a literal that drifts.
const (
	FilterActionInclude = "include"
	FilterActionExclude = "exclude"

	PathRuleGlob = "glob"
	PathRuleSize = "size"
)

// PathFilterRule mirrors one transx filter.Rule. It is an ordered include/exclude
// entry evaluated top-to-bottom; the first matching rule decides the outcome and
// an item matched by no rule is kept.
//
// Type "glob": Pattern is a glob against the path/base name ("*.log", "**/*.txt").
// Type "size": Op is one of > >= < <= == and Value is a byte threshold.
type PathFilterRule struct {
	Action  string `json:"action"`            // include | exclude
	Type    string `json:"type"`              // glob | size
	Pattern string `json:"pattern,omitempty"` // type=glob
	Op      string `json:"op,omitempty"`      // type=size (> >= < <= ==)
	Value   int64  `json:"value,omitempty"`   // type=size (bytes)
}

// ── dbmsx filter (exclude-only) ──────────────────────────────────────────────

// dbmsx filter rule type discriminators.
const (
	DBMSRuleTableColumn   = "table_column"   // exclude a whole table or specific columns
	DBMSRuleRowExclude    = "row_exclude"    // exclude rows for which WHERE is TRUE
	DBMSRuleObjectExclude = "object_exclude" // exclude a schema object
)

// DBMSFilterRule mirrors one dbmsx filter.FilterRule. The dbmsx pipeline is
// exclude-only: the source database is migrated in full except for what the
// rules remove.
//
// Type "table_column":   exclude table Table entirely (Columns empty) or only
//
//	the named Columns within it (the table itself is kept).
//
// Type "row_exclude":    drop rows of Table for which the SQL predicate Match is
//
//	TRUE (relational engines only; requires direct access).
//
// Type "object_exclude": drop the schema object of Kind named Name. Table is an
//
//	optional qualifier meaningful only for Kind "index".
type DBMSFilterRule struct {
	Type    string   `json:"type"`
	Table   string   `json:"table,omitempty"`
	Columns []string `json:"columns,omitempty"` // type=table_column (empty => whole table)
	Match   string   `json:"match,omitempty"`   // type=row_exclude
	Kind    string   `json:"kind,omitempty"`    // type=object_exclude (view|index|function|...)
	Name    string   `json:"name,omitempty"`    // type=object_exclude
}

// ── Per-resource filters (shared by the plan request and the plan output) ────

// PgSchemaMapping maps one PostgreSQL schema from source to target.
//
// transx-ex takes DBMSLocation.PgSchema as a []string on each side and matches
// them by position. Taking name pairs here instead means a caller cannot
// silently migrate into the wrong schema by listing them out of order; the
// adapter splits the pairs into the two positional slices.
//
// When DstName is empty the source name is used as-is on the target.
type PgSchemaMapping struct {
	SrcName string `json:"srcName" validate:"required"`
	DstName string `json:"dstName,omitempty"`
}

// TargetMapping selects a single item from the source model to migrate and
// names its destination. All three domains share this type, so the fields are
// domain-neutral "names"; what a name points at differs per domain:
//
//	filesystem    → folder path      ("/data/logs")
//	objectstorage → bucket/prefix    ("bucket-a/images/")
//	dbms          → database name    ("shop")
//
// SrcName must match an entry in the source model exactly. When DstName is
// empty the source name is used as-is on the target.
type TargetMapping struct {
	SrcName string `json:"srcName" validate:"required"`
	DstName string `json:"dstName,omitempty"`

	// PgSchemas selects and renames PostgreSQL schemas within this database.
	// Empty migrates every schema under its own name; a non-empty list migrates
	// only the schemas it names, which makes it a selection as much as a rename.
	// PostgreSQL only: the plan layer rejects it for other engines and for the
	// file system and object storage filters.
	PgSchemas []PgSchemaMapping `json:"pgSchemas,omitempty"`
}

// FileSystemFilter defines file system migration filter conditions.
// Rules mirror the transx-ex filter pipeline; TargetMapping is centipede-specific
// single-folder selection + source→target remapping applied by the plan layer.
// Supplying a filter at all means naming the folder it applies to, so
// TargetMapping is required here; omitting the whole filter migrates the source
// scan root (topmost folder) under its own name.
type FileSystemFilter struct {
	Rules         []PathFilterRule `json:"rules,omitempty"`
	TargetMapping TargetMapping    `json:"targetMapping" validate:"required"` // selects the single folder to migrate
}

// ObjectStorageFilter defines object storage migration filter conditions.
// Same shape as FileSystemFilter, selecting a single bucket/prefix.
type ObjectStorageFilter struct {
	Rules         []PathFilterRule `json:"rules,omitempty"`
	TargetMapping TargetMapping    `json:"targetMapping" validate:"required"` // selects the single bucket to migrate
}

// DBMSFilterEntry carries one database's source→target mapping and the
// exclude rules that apply to it. Rules are attached to that database's
// DBMSLocation alone, so Table carries no database qualifier — on PostgreSQL it
// is schema-qualified ("public.orders"), matching how Inspect reports names.
type DBMSFilterEntry struct {
	TargetMapping TargetMapping    `json:"targetMapping" validate:"required"`
	Rules         []DBMSFilterRule `json:"rules,omitempty"`
}

// DBMSFilter groups exclude rules per database, because one source connection
// can hold several of them and a dbmsx rule set belongs to a single
// DBMSLocation. Unlike the file system and object storage filters, which pick
// one folder or bucket, this one lists as many databases as it needs. Listing
// any database narrows the migration to the ones listed.
type DBMSFilter struct {
	Databases []DBMSFilterEntry `json:"databases,omitempty"`
}
