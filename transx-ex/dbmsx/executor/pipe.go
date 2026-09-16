package executor

import (
	"context"
	"io"
	"log/slog"
	"sync"

	drvpkg "github.com/cloud-barista/cm-centipede/transx-ex/dbmsx/driver"
)

// =============================================================================
// Compile-time Interface Assertion
// =============================================================================

var _ Executor = (*PipeExecutor)(nil)

// =============================================================================
// PipeExecutor
// =============================================================================

// PipeExecutor streams a dump directly from a source SSH host to a restore on
// a destination SSH host using an in-process io.Pipe — no local staging file is
// written.  Both commands must accept/produce a byte stream on stdin/stdout
// (e.g. mysqldump ... | mysql ..., mongodump --archive | mongorestore --archive).
//
// The two goroutines run concurrently:
//   - restore goroutine reads the pipe reader as the restore command's stdin
//   - dump goroutine writes the pipe writer as the dump command's stdout
//
// If dump fails, the pipe writer is closed with the dump error so the restore
// side unblocks promptly.  If restore fails, the pipe reader is closed so the
// dump side stops writing.  dumpErr is checked before restoreErr when both
// goroutines fail.
type PipeExecutor struct {
	dumpCmd    string
	restoreCmd string
	srcSSH     *drvpkg.SSHConfig
	dstSSH     *drvpkg.SSHConfig
}

// NewPipeExecutor constructs a PipeExecutor from pre-built CLI commands and the
// SSH credentials for each host.  The commands are typically produced by
// DBDriver.BuildDumpCmd and DBDriver.BuildRestoreCmd.
func NewPipeExecutor(dumpCmd string, srcSSH *drvpkg.SSHConfig, restoreCmd string, dstSSH *drvpkg.SSHConfig) *PipeExecutor {
	return &PipeExecutor{
		dumpCmd:    dumpCmd,
		restoreCmd: restoreCmd,
		srcSSH:     srcSSH,
		dstSSH:     dstSSH,
	}
}

// Execute runs the dump and restore commands concurrently, piping the dump
// output directly into the restore's stdin.
//
// source and destination are accepted for Executor interface compatibility but
// are not used; all routing is governed by the SSH credentials and commands
// stored in the PipeExecutor.
//
// On failure it returns one of:
//   - *MigrationError{Stage: StageDump}    when the dump command fails
//   - *MigrationError{Stage: StageRestore} when the restore command fails
//
// If both fail (e.g. one caused the other via pipe closure), the dump error
// is returned because it is the root cause.
func (e *PipeExecutor) Execute(ctx context.Context, _, _ drvpkg.DBMSLocation) error {
	logger.Info("pipe execute started",
		slog.String("dumpCmd", e.dumpCmd),
		slog.String("restoreCmd", e.restoreCmd),
	)
	pr, pw := io.Pipe()

	var (
		wg         sync.WaitGroup
		dumpErr    error
		restoreErr error
	)

	// Cancellation watcher. Neither SSH command takes a context, so a cancel is
	// delivered by tearing down the pipe: both sides then fail their next read
	// or write and unwind. The watcher exits with Execute so it cannot outlive
	// the transfer.
	watchDone := make(chan struct{})
	defer close(watchDone)
	go func() {
		select {
		case <-ctx.Done():
			pr.CloseWithError(ctx.Err())
			pw.CloseWithError(ctx.Err())
		case <-watchDone:
		}
	}()

	// Goroutine 1 — restore: reads from the pipe reader as the command's stdin.
	wg.Add(1)
	go func() {
		defer wg.Done()
		restoreErr = drvpkg.ExecuteViaSSH(e.dstSSH, e.restoreCmd, pr, nil)
		// Close the reader so the dump side unblocks if it is still writing.
		pr.CloseWithError(restoreErr)
	}()

	// Goroutine 2 — dump: writes its stdout into the pipe writer.
	wg.Add(1)
	go func() {
		defer wg.Done()
		dumpErr = drvpkg.ExecuteViaSSH(e.srcSSH, e.dumpCmd, nil, pw)
		// Close the writer to signal EOF (or error) to the restore side.
		pw.CloseWithError(dumpErr)
	}()

	wg.Wait()

	if dumpErr != nil {
		logger.Error("pipe dump failed", slog.String("err", dumpErr.Error()))
		return &MigrationError{Stage: StageDump, Err: dumpErr}
	}
	if restoreErr != nil {
		logger.Error("pipe restore failed", slog.String("err", restoreErr.Error()))
		return &MigrationError{Stage: StageRestore, Err: restoreErr}
	}
	logger.Info("pipe execute completed")
	return nil
}
