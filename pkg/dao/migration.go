package dao

import (
	"errors"
	"fmt"

	commonmodel "github.com/cloud-barista/cm-centipede/dmdl/common-model"
	targetmodel "github.com/cloud-barista/cm-centipede/dmdl/target-model"
	"github.com/cloud-barista/cm-centipede/pkg/api/rest/model"
	"github.com/cloud-barista/cm-centipede/pkg/connsec"
	"github.com/cloud-barista/cm-centipede/pkg/db"
	"gorm.io/gorm"
)

// ErrMigrationRunning is returned when an operation is blocked because the
// migration is currently in the "running" state (e.g. delete while running).
var ErrMigrationRunning = errors.New("migration is running")

// ─── plan encryption helpers ─────────────────────────────────────────────────

// applyRef runs fn over a single ConnectionRef in-place.
func applyRef(ref *commonmodel.ConnectionRef, fn func(commonmodel.ConnectionRef) (commonmodel.ConnectionRef, error)) error {
	out, err := fn(*ref)
	if err != nil {
		return err
	}
	*ref = out
	return nil
}

// transformPlan applies fn to every source and destination ConnectionRef across
// all migration units (filesystem/objectStorage/db) in-place. Sensitive inline
// credentials and db-reference passwords are (en|de)crypted; identifier-only refs
// pass through unchanged (see connsec).
func transformPlan(plan *targetmodel.TargetDataMigrationModel, fn func(commonmodel.ConnectionRef) (commonmodel.ConnectionRef, error)) error {
	p := &plan.TargetDataMigrationModel
	for i := range p.FileSystems {
		if err := applyRef(&p.FileSystems[i].SrcConnection, fn); err != nil {
			return fmt.Errorf("fileSystems[%d] src: %w", i, err)
		}
		if err := applyRef(&p.FileSystems[i].DstConnection, fn); err != nil {
			return fmt.Errorf("fileSystems[%d] dst: %w", i, err)
		}
	}
	for i := range p.ObjectStorages {
		if err := applyRef(&p.ObjectStorages[i].SrcConnection, fn); err != nil {
			return fmt.Errorf("objectStorages[%d] src: %w", i, err)
		}
		if err := applyRef(&p.ObjectStorages[i].DstConnection, fn); err != nil {
			return fmt.Errorf("objectStorages[%d] dst: %w", i, err)
		}
	}
	for i := range p.Databases {
		if err := applyRef(&p.Databases[i].SrcConnection, fn); err != nil {
			return fmt.Errorf("dbs[%d] src: %w", i, err)
		}
		if err := applyRef(&p.Databases[i].DstConnection, fn); err != nil {
			return fmt.Errorf("dbs[%d] dst: %w", i, err)
		}
	}
	return nil
}

// encryptPlan AES-encrypts all inline credentials / db-ref passwords in a plan
// in-place. The plan must contain plaintext credentials (as returned by the
// business logic layer).
func encryptPlan(plan *targetmodel.TargetDataMigrationModel) error {
	return transformPlan(plan, connsec.EncryptRef)
}

// decryptPlan AES-decrypts all inline credentials / db-ref passwords in a plan
// in-place.
func decryptPlan(plan *targetmodel.TargetDataMigrationModel) error {
	return transformPlan(plan, connsec.DecryptRef)
}

// ─── Migration ───────────────────────────────────────────────────────────────

// CreateMigration persists a new Migration.
// Inline connection credentials and the beetleDb password in the plan are
// AES-encrypted before writing.
func CreateMigration(m *model.Migration) error {
	if err := encryptPlan(&m.Plan); err != nil {
		return fmt.Errorf("encrypt plan: %w", err)
	}
	return db.DB.Create(m).Error
}

// GetMigration returns the Migration with the given ID.
// Inline connection credentials and the beetleDb password are AES-decrypted
// before returning.
func GetMigration(id string) (*model.Migration, error) {
	var m model.Migration
	if err := db.DB.First(&m, "id = ?", id).Error; err != nil {
		return nil, err
	}
	if err := decryptPlan(&m.Plan); err != nil {
		return nil, fmt.Errorf("decrypt plan: %w", err)
	}
	return &m, nil
}

// ListMigration returns a paginated list of migrations, optionally filtered by status.
// Inline connection credentials and the beetleDb password are AES-decrypted in
// each returned Migration.
func ListMigration(status string, page, pageSize int) ([]model.Migration, int64, error) {
	q := db.DB.Model(&model.Migration{})
	if status != "" {
		q = q.Where("status = ?", status)
	}

	var total int64
	if err := q.Count(&total).Error; err != nil {
		return nil, 0, err
	}

	var items []model.Migration
	offset := (page - 1) * pageSize
	if err := q.Order("created_at DESC").Offset(offset).Limit(pageSize).Find(&items).Error; err != nil {
		return nil, 0, err
	}

	for i := range items {
		if err := decryptPlan(&items[i].Plan); err != nil {
			return nil, 0, fmt.Errorf("decrypt plan[%d]: %w", i, err)
		}
	}
	return items, total, nil
}

// ListAllMigration returns all migrations ordered by created_at DESC,
// optionally filtered by status. Inline connection credentials and the beetleDb
// password are AES-decrypted.
func ListAllMigration(status string) ([]model.Migration, error) {
	q := db.DB.Model(&model.Migration{})
	if status != "" {
		q = q.Where("status = ?", status)
	}

	var items []model.Migration
	if err := q.Order("created_at DESC").Find(&items).Error; err != nil {
		return nil, err
	}

	for i := range items {
		if err := decryptPlan(&items[i].Plan); err != nil {
			return nil, fmt.Errorf("decrypt plan[%d]: %w", i, err)
		}
	}
	return items, nil
}

// UpdateMigrationStatus updates only the status and progress fields, leaving the
// plan column untouched. Use this during execution to avoid re-encrypting the plan
// on every progress tick.
func UpdateMigrationStatus(m *model.Migration) error {
	return db.DB.Model(&model.Migration{}).Where("id = ?", m.ID).Updates(map[string]interface{}{
		"status":            m.Status,
		"status_message":    m.StatusMessage,
		"total_items":       m.TotalItems,
		"processed_items":   m.ProcessedItems,
		"failed_items":      m.FailedItems,
		"total_bytes":       m.TotalBytes,
		"transferred_bytes": m.TransferredBytes,
		"started_at":        m.StartedAt,
		"completed_at":      m.CompletedAt,
	}).Error
}

// UpdateMigrationValidation updates only the validation fields (status, message, details),
// leaving plan, status, and progress columns untouched.
// Use this after a validation run completes to persist results without re-encrypting the plan.
func UpdateMigrationValidation(m *model.Migration) error {
	return db.DB.Model(&model.Migration{}).Where("id = ?", m.ID).
		Select("validation_status", "validation_message", "validation_details").
		Updates(m).Error
}

// UpdateMigration saves all fields of m.
// Inline connection credentials and the beetleDb password in the plan are
// AES-encrypted before writing.
// Callers must pass decrypted credentials (as returned by GetMigration).
func UpdateMigration(m *model.Migration) error {
	if err := encryptPlan(&m.Plan); err != nil {
		return fmt.Errorf("encrypt plan: %w", err)
	}
	return db.DB.Save(m).Error
}

// DeleteMigration deletes the Migration with the given ID.
// Returns ErrMigrationRunning when status is "running".
// Returns gorm.ErrRecordNotFound when no row matches.
func DeleteMigration(id string) error {
	var m model.Migration
	if err := db.DB.Select("id", "status").First(&m, "id = ?", id).Error; err != nil {
		return err
	}
	if m.Status == "running" {
		return ErrMigrationRunning
	}
	result := db.DB.Delete(&model.Migration{}, "id = ?", id)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return gorm.ErrRecordNotFound
	}
	return nil
}

// ─── MigrationLog ────────────────────────────────────────────────────────────

// CreateMigrationLog persists a single MigrationLog entry.
func CreateMigrationLog(entry *model.MigrationLog) error {
	return db.DB.Create(entry).Error
}

// ListAllMigrationLog returns every log for migrationID without pagination,
// optionally filtered by status ("success" | "failed" | "skipped").
func ListAllMigrationLog(migrationID, status string) ([]model.MigrationLog, error) {
	q := db.DB.Model(&model.MigrationLog{}).Where("migration_id = ?", migrationID)
	if status != "" {
		q = q.Where("status = ?", status)
	}
	var items []model.MigrationLog
	if err := q.Order("created_at ASC").Find(&items).Error; err != nil {
		return nil, err
	}
	return items, nil
}

// ListMigrationLog returns a paginated list of logs for migrationID,
// optionally filtered by status ("success" | "failed" | "skipped").
func ListMigrationLog(migrationID, status string, page, pageSize int) ([]model.MigrationLog, int64, error) {
	q := db.DB.Model(&model.MigrationLog{}).Where("migration_id = ?", migrationID)
	if status != "" {
		q = q.Where("status = ?", status)
	}

	var total int64
	if err := q.Count(&total).Error; err != nil {
		return nil, 0, err
	}

	var items []model.MigrationLog
	offset := (page - 1) * pageSize
	if err := q.Order("created_at ASC").Offset(offset).Limit(pageSize).Find(&items).Error; err != nil {
		return nil, 0, err
	}
	return items, total, nil
}
