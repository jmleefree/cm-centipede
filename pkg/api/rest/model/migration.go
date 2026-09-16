package model

import (
	"time"

	targetmodel "github.com/cloud-barista/cm-centipede/dmdl/target-model"
)

// ── Migration GORM models ────────────────────────────────────────────────────

// Migration represents a migration execution unit persisted to SQLite.
//
// Status values: "pending" | "running" | "completed" | "failed" | "cancelled"
// ValidationStatus values: "passed" | "failed" | "not_run" | "running"
type Migration struct {
	ID          string                               `gorm:"primaryKey"                                         json:"id"`
	Name        string                               `gorm:"index:,column:name,unique;type:text collate nocase" json:"name"        validate:"required"`
	Description string                               `gorm:"column:description"                                 json:"description"`
	Plan        targetmodel.TargetDataMigrationModel `gorm:"column:plan;serializer:json"                        json:"plan"        validate:"required"`

	// DBMSOnFailure is carried on the record rather than only on the request
	// because execution is asynchronous and a retry re-reads the row: the policy
	// has to outlive the call that set it. Empty means DBMSOnFailureCleanup.
	DBMSOnFailure string `gorm:"column:dbms_on_failure" json:"dbmsOnFailure,omitempty"`

	Status        string `gorm:"column:status"         json:"status"`
	StatusMessage string `gorm:"column:status_message" json:"statusMessage,omitempty"`

	TotalItems       int64 `gorm:"column:total_items"       json:"totalItems"`
	ProcessedItems   int64 `gorm:"column:processed_items"   json:"processedItems"`
	FailedItems      int64 `gorm:"column:failed_items"      json:"failedItems"`
	TotalBytes       int64 `gorm:"column:total_bytes"       json:"totalBytes"`
	TransferredBytes int64 `gorm:"column:transferred_bytes" json:"transferredBytes"`

	ValidationStatus  string                 `gorm:"column:validation_status"              json:"validationStatus,omitempty"`
	ValidationMessage string                 `gorm:"column:validation_message"             json:"validationMessage,omitempty"`
	ValidationDetails []ValidationDetailItem `gorm:"column:validation_details;serializer:json" json:"validationDetails,omitempty"`

	StartedAt   *time.Time `gorm:"column:started_at"   json:"startedAt,omitempty"`
	CompletedAt *time.Time `gorm:"column:completed_at" json:"completedAt,omitempty"`
	CreatedAt   time.Time  `gorm:"column:created_at"   json:"createdAt"`
	UpdatedAt   time.Time  `gorm:"column:updated_at"   json:"updatedAt"`
}

// MigrationLog records the result of a single item migration within a migration.
//
// Status values: "success" | "failed" | "skipped"
// RollbackStatus values: "success" | "failed" | "skipped" | "" (non-DBMS, or no rollback performed)
type MigrationLog struct {
	ID          uint   `gorm:"primaryKey;autoIncrement"  json:"id"`
	MigrationID string `gorm:"column:migration_id;index" json:"migrationId"`
	// ItemPath: absolute file path (SSH) | object key (ObjectStorage) | table/collection name (DBMS)
	ItemPath   string `gorm:"column:item_path"          json:"itemPath"`
	Status     string `gorm:"column:status"             json:"status"`
	ErrorMsg   string `gorm:"column:error_msg"          json:"errorMsg,omitempty"`
	SizeBytes  int64  `gorm:"column:size_bytes"         json:"sizeBytes,omitempty"`
	DurationMs int64  `gorm:"column:duration_ms"        json:"durationMs"`

	// FailedObjectKind and FailedObjectName name the object transx-ex was
	// working on when the item failed — a table, view, routine, file or object —
	// so the failure can be located without reading ErrorMsg. FailedObjectName
	// carries the enclosing database, schema or bucket when transx-ex knew it
	// ("centipede_test.v_customer_stats").
	//
	// Both stay empty when the failure was not tied to a single object: a
	// connection refused, a dump command that failed as a whole.
	FailedObjectKind string `gorm:"column:failed_object_kind" json:"failedObjectKind,omitempty"`
	FailedObjectName string `gorm:"column:failed_object_name" json:"failedObjectName,omitempty"`

	// TargetCreated records that this item's target database did not exist before
	// the migration and does because of it, which is what decides whether a failure
	// dropped the database or emptied it. DBMS items only.
	//
	// It is not a record of who ran a DDL statement. On MongoDB nobody does: a
	// database begins to exist when the restore writes its first collection, and
	// the flag is true there all the same, because dropping is still what undoing
	// the item means.
	TargetCreated bool `gorm:"column:target_created" json:"targetCreated,omitempty"`

	// RollbackStatus reports the cleanup that followed a failure. What it refers
	// to depends on TargetCreated: emptying a database that already existed
	// (false), or dropping one centipede created (true).
	RollbackStatus   string `gorm:"column:rollback_status"    json:"rollbackStatus,omitempty"`
	RollbackErrorMsg string `gorm:"column:rollback_error_msg" json:"rollbackErrorMsg,omitempty"`

	CreatedAt time.Time `gorm:"column:created_at" json:"createdAt"`
}

// ── API request/response models ──────────────────────────────────────────────

// DBMSOnFailure values for CreateMigrationReq.DBMSOnFailure and
// Migration.DBMSOnFailure. Empty is read as DBMSOnFailureCleanup.
const (
	// DBMSOnFailureCleanup undoes a failed database item: one centipede created
	// is dropped whole, one that already existed is emptied by transx-ex.
	DBMSOnFailureCleanup = "cleanup"

	// DBMSOnFailureKeep leaves a failed database exactly as the failure left it,
	// so the partial result can be inspected. Nothing is dropped and nothing is
	// emptied.
	DBMSOnFailureKeep = "keep"
)

// CreateMigrationReq is the request body for POST /centipede/migration.
type CreateMigrationReq struct {
	Name        string                               `json:"name"        validate:"required"`
	Description string                               `json:"description"`
	Plan        targetmodel.TargetDataMigrationModel `json:"plan"        validate:"required"`

	// DBMSOnFailure decides what happens to a DBMS target when one of its
	// database items fails. It is named for the DBMS domain because only that
	// domain has an undo step: a filesystem or object storage transfer leaves
	// whatever it had already written, with or without this field.
	//
	// "cleanup" (the default) undoes the failed item. "keep" leaves it in place
	// for inspection — useful when the failure is in the data rather than in the
	// connection, since cleanup destroys the evidence.
	//
	// Cancellation is not a failure and always cleans up, whatever this says.
	DBMSOnFailure string `json:"dbmsOnFailure,omitempty" validate:"omitempty,oneof=cleanup keep"`
}

// RetryReq is the optional request body for POST /centipede/migration/{id}/retry.
//
// RetryMode: "partial" (default) — re-run only failed items after rollback
//
//	"full"    — drop entire target DB, then re-run all items
type RetryReq struct {
	RetryMode string `json:"retryMode,omitempty"`
}

// RetryResponse is returned when a retry migration is created successfully.
type RetryResponse struct {
	OriginalMigrationID string    `json:"originalMigrationId"`
	NewMigration        Migration `json:"newMigration"`
}

// ── Validation response models ───────────────────────────────────────────────

// ValidationDetailItem describes the verification result for a single item.
type ValidationDetailItem struct {
	// ItemPath: file path | object key | DBMS target
	// ("{database}/{table}", "{database}/{table}.{column}", "{database}/{kind}:{name}").
	ItemPath string `json:"itemPath"`
	// Status: "passed" | "failed" | "warning". A warning is reported but does not
	// fail the validation — a character-set difference can be a managed service
	// imposing its own default.
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
}

// ValidationResultResponse is returned by GET /centipede/migration/{id}/validation.
type ValidationResultResponse struct {
	ValidationStatus  string                 `json:"validationStatus"` // "passed" | "failed" | "not_run" | "running"
	ValidationMessage string                 `json:"validationMessage,omitempty"`
	Details           []ValidationDetailItem `json:"details,omitempty"` // list of failed items
}
