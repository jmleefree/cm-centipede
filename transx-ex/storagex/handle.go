package storagex

import (
	"context"
	"time"

	"github.com/cloud-barista/cm-centipede/transx-ex/core"
)

// MigrationStatus represents the lifecycle state of a migration.
// It is core.Status, shared with the DBMS domain.
type MigrationStatus = core.Status

const (
	StatusPending   = core.StatusPending
	StatusRunning   = core.StatusRunning
	StatusDone      = core.StatusDone
	StatusFailed    = core.StatusFailed
	StatusCancelled = core.StatusCancelled
)

// MigrationProgress holds real-time progress information for an ongoing migration.
type MigrationProgress struct {
	Status           MigrationStatus `json:"status"`
	StartedAt        time.Time       `json:"startedAt"`
	ElapsedSec       float64         `json:"elapsedSec"`
	BytesTransferred int64           `json:"bytesTransferred"`
	FilesTransferred int             `json:"filesTransferred"`
	CurrentFile      string          `json:"currentFile"`
	ErrMessage       string          `json:"errMessage,omitempty"`
}

// The accessors below satisfy core.Progress, which is how core.Handle keeps
// the fields common to every domain up to date.

func (p *MigrationProgress) GetStatus() core.Status     { return p.Status }
func (p *MigrationProgress) SetStatus(s core.Status)    { p.Status = s }
func (p *MigrationProgress) SetStartedAt(t time.Time)   { p.StartedAt = t }
func (p *MigrationProgress) SetElapsed(seconds float64) { p.ElapsedSec = seconds }
func (p *MigrationProgress) SetError(msg string)        { p.ErrMessage = msg }

// MigrationHandle provides async control over a running migration.
// Obtain one via TransferAsync or MigrateDataAsync; poll with Status()/Progress(); block with Wait().
//
// The embedded core.Handle supplies the lifecycle — Status, Progress, Wait,
// Cancel — shared with the DBMS domain.
type MigrationHandle struct {
	*core.Handle[MigrationProgress, *MigrationProgress]
}

// newMigrationHandle constructs a handle in StatusPending state.
func newMigrationHandle(ctx context.Context, cancel context.CancelFunc) *MigrationHandle {
	return &MigrationHandle{core.NewHandle[MigrationProgress, *MigrationProgress](ctx, cancel)}
}

// run executes the full migration described by dmm.
// It is launched as a goroutine by TransferAsync/MigrateDataAsync, which calls
// Finish when it returns.
func (h *MigrationHandle) run(dmm DataMigrationModel) error {
	h.SetStatus(StatusRunning)

	pipeline, err := Plan(dmm)
	if err != nil {
		h.Fail(err)
		return err
	}

	if err := pipeline.Execute(h.Context()); err != nil {
		if ctxErr := h.Context().Err(); ctxErr != nil {
			h.SetStatus(StatusCancelled)
			h.SetErr(ctxErr)
			return ctxErr
		}
		h.Fail(err)
		return err
	}

	h.SetStatus(StatusDone)
	return nil
}
