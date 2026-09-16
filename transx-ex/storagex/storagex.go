package storagex

import (
	"context"
	"fmt"
	"os/exec"
	"strings"

	"github.com/cloud-barista/cm-centipede/transx-ex/core"
)

// ============================================================================
// Main Entry Points
// ============================================================================

// Transfer runs the data transfer as defined by the given DataMigrationModel.
// It automatically selects the appropriate transfer strategy based on source/destination types.
func Transfer(dmm DataMigrationModel) error {
	if err := Validate(dmm); err != nil {
		return fmt.Errorf("validation failed: %w", err)
	}

	// Plan the transfer pipeline
	pipeline, err := Plan(dmm)
	if err != nil {
		return fmt.Errorf("planning failed: %w", err)
	}

	// Execute the pipeline
	return pipeline.Execute(context.Background())
}

// MigrateData manages the complete data migration workflow:
// 1. If Source.PreCmd is defined, perform pre-processing (e.g., backup)
// 2. Always perform Transfer
// 3. If Destination.PostCmd is defined, perform post-processing (e.g., restore)
func MigrateData(dmm DataMigrationModel) error {
	// Step 1: Pre-processing (optional, e.g., backup)
	if strings.TrimSpace(dmm.Source.PreCmd) != "" {
		if err := executePreCommand(dmm.Source); err != nil {
			return &MigrationError{Stage: StageBackup, Err: err}
		}
	}

	// Step 2: Transfer (core)
	if err := Transfer(dmm); err != nil {
		return &MigrationError{Stage: StageTransfer, Err: err}
	}

	// Step 3: Post-processing (optional, e.g., restore)
	if strings.TrimSpace(dmm.Destination.PostCmd) != "" {
		if err := executePostCommand(dmm.Destination); err != nil {
			return &MigrationError{Stage: StageRestore, Err: err}
		}
	}

	return nil
}

// TransferAsync starts Transfer in a background goroutine and returns a handle
// for monitoring progress and cancellation.
func TransferAsync(dmm DataMigrationModel) *MigrationHandle {
	ctx, cancel := context.WithCancel(context.Background())
	h := newMigrationHandle(ctx, cancel)
	go func() {
		h.run(dmm) //nolint:errcheck — the error is recorded in the handle, returned by Wait()
		h.Finish()
	}()
	return h
}

// MigrateDataAsync starts MigrateData in a background goroutine and returns a
// handle for monitoring progress and cancellation.
func MigrateDataAsync(dmm DataMigrationModel) *MigrationHandle {
	ctx, cancel := context.WithCancel(context.Background())
	h := newMigrationHandle(ctx, cancel)
	go func() {
		h.run(dmm) //nolint:errcheck — the error is recorded in the handle, returned by Wait()
		h.Finish()
	}()
	return h
}

// ============================================================================
// Command Execution
// ============================================================================

// executePreCommand executes the PreCmd defined in the source DataLocation.
func executePreCommand(src DataLocation) error {
	if strings.TrimSpace(src.PreCmd) == "" {
		return fmt.Errorf("pre-command not defined")
	}

	output, err := executeCommand(src.PreCmd, src)
	if err != nil {
		return &OperationError{
			Operation: OperationPreCmd,
			Source:    buildLocationPath(src),
			Command:   src.PreCmd,
			Output:    string(output),
			Err:       err,
		}
	}
	return nil
}

// executePostCommand executes the PostCmd defined in the destination DataLocation.
func executePostCommand(dest DataLocation) error {
	if strings.TrimSpace(dest.PostCmd) == "" {
		return fmt.Errorf("post-command not defined")
	}

	output, err := executeCommand(dest.PostCmd, dest)
	if err != nil {
		return &OperationError{
			Operation:   OperationPostCmd,
			Destination: buildLocationPath(dest),
			Command:     dest.PostCmd,
			Output:      string(output),
			Err:         err,
		}
	}
	return nil
}

// ============================================================================
// Helper Functions
// ============================================================================

// buildLocationPath returns a human-readable path representation for error messages.
func buildLocationPath(loc DataLocation) string {
	switch loc.StorageType {
	case StorageTypeFilesystem:
		if loc.Filesystem != nil && loc.Filesystem.AccessType == AccessTypeSSH && loc.Filesystem.SSH != nil {
			ssh := loc.Filesystem.SSH
			if ssh.Username != "" {
				return fmt.Sprintf("%s@%s:%s", ssh.Username, ssh.Host, loc.Path)
			}
			return fmt.Sprintf("%s:%s", ssh.Host, loc.Path)
		}
		return loc.Path

	case StorageTypeObjectStorage:
		return buildObjectStoragePath(loc)

	default:
		return loc.Path
	}
}

// buildObjectStoragePath returns a readable path for object storage locations.
// Each access type has a prefix for easy identification in error messages.
func buildObjectStoragePath(loc DataLocation) string {
	if loc.ObjectStorage == nil {
		return loc.Path
	}

	switch loc.ObjectStorage.AccessType {
	case AccessTypeMinio:
		// minio: endpoint/bucket/key
		if loc.ObjectStorage.Minio != nil {
			return fmt.Sprintf("minio: %s/%s", loc.ObjectStorage.Minio.Endpoint, loc.Path)
		}
		return fmt.Sprintf("minio: %s", loc.Path)

	case AccessTypeSpider:
		// spider: [connectionName] endpoint/path
		if loc.ObjectStorage.Spider != nil {
			cfg := loc.ObjectStorage.Spider
			return fmt.Sprintf("spider: [%s] %s/%s", cfg.ConnectionName, cfg.Endpoint, loc.Path)
		}
		return fmt.Sprintf("spider: %s", loc.Path)

	case AccessTypeTumblebug:
		// tumblebug: endpoint/ns/{nsId}/os/{osId}/path
		if loc.ObjectStorage.Tumblebug != nil {
			cfg := loc.ObjectStorage.Tumblebug
			return fmt.Sprintf("tumblebug: %s/ns/%s/os/%s/%s", cfg.Endpoint, cfg.NsId, cfg.OsId, loc.Path)
		}
		return fmt.Sprintf("tumblebug: %s", loc.Path)
	}

	return loc.Path
}

// executeCommand executes a command either locally or remotely via SSH.
func executeCommand(command string, loc DataLocation) ([]byte, error) {
	// Object storage doesn't support command execution
	if loc.IsObjectStorage() {
		return nil, fmt.Errorf("command execution not supported for object storage")
	}

	// Filesystem: check if local or SSH
	if loc.Filesystem == nil {
		return nil, fmt.Errorf("filesystem access config required")
	}

	switch loc.Filesystem.AccessType {
	case AccessTypeLocal:
		// Local execution
		cmd := exec.Command("sh", "-c", command)
		return cmd.CombinedOutput()

	case AccessTypeSSH:
		// Remote execution via SSH
		if loc.Filesystem.SSH == nil {
			return nil, fmt.Errorf("SSH config required for remote command execution")
		}
		return executeSSHCommand(command, loc.Filesystem.SSH)

	default:
		return nil, fmt.Errorf("command execution not supported for access type: %s", loc.Filesystem.AccessType)
	}
}

// executeSSHCommand runs a command on a remote server and returns stdout with
// any stderr appended, mirroring exec.Cmd.CombinedOutput. Use withSSHClient
// instead when the output is machine-parsed or when several commands run
// against the same host.
func executeSSHCommand(command string, cfg *SSHConfig) ([]byte, error) {
	return core.CombinedOutput(cfg, command)
}

// sshRunner executes a single command over an already-established SSH
// connection and returns its stdout. Any stderr is folded into the error, so
// diagnostics never contaminate parsed output.
type sshRunner = core.Runner

// withSSHClient dials cfg once and invokes fn with a runner bound to that
// single connection, so a multi-command operation pays the handshake cost only
// once. The connection is closed when fn returns.
func withSSHClient(cfg *SSHConfig, fn func(run sshRunner) error) error {
	return core.WithClient(cfg, fn)
}

// normalizePrivateKey converts literal "\n" escape sequences to real newlines,
// so a key supplied through an environment variable or a JSON string parses.
func normalizePrivateKey(key string) string {
	return core.NormalizePrivateKey(key)
}

// ============================================================================
// Pre/Post Command Execution
// ============================================================================

// RunPreCommand executes src.PreCmd, the hook that prepares data for transfer —
// dumping a database into the directory about to be copied, for instance.
// MigrateData calls it automatically; call it directly only to run that step on
// its own. It returns an error when PreCmd is empty.
func RunPreCommand(src DataLocation) error { return executePreCommand(src) }

// RunPostCommand executes dst.PostCmd, the hook that consumes transferred data
// at the destination. MigrateData calls it automatically; call it directly only
// to run that step on its own. It returns an error when PostCmd is empty.
func RunPostCommand(dst DataLocation) error { return executePostCommand(dst) }
