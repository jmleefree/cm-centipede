package migration

// ProgressEvent is emitted on the progressCh channel after each migration item
// (directory, bucket, or DB table/collection) is processed.
//
// Status values: "success" | "failed" | "cancelled"
type ProgressEvent struct {
	ItemPath   string
	Status     string
	SizeBytes  int64
	DurationMs int64
	// TargetCreated reports that this item's target database did not exist before
	// the migration and does because of it, which is what decides whether a
	// failure dropped the database or emptied it. DBMS items only. See
	// model.MigrationLog.TargetCreated for why MongoDB sets it without anyone
	// running a create statement.
	TargetCreated bool
	Err           error
}
