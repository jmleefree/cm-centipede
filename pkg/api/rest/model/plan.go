package model

import (
	commonmodel "github.com/cloud-barista/cm-centipede/dmdl/common-model"
	sourcemodel "github.com/cloud-barista/cm-centipede/dmdl/source-model"
)

// ── Plan request model ───────────────────────────────────────────────────────

// TargetPlanReq is the request body for POST /centipede/plans/target.
type TargetPlanReq struct {
	Source        sourcemodel.SourceDataMigrationModel `json:"source"                       validate:"required"`
	DstConnection commonmodel.ConnectionRef            `json:"dstConnection"                validate:"required"`
	// FileSystemStrategy is the transfer strategy applied to filesystem (SSH→SSH)
	// tasks. Empty is normalised to "relay" (safer default: avoids agent-forward
	// setup requirements). It has no effect on object-storage or DBMS tasks, where
	// relay is always used / not applicable.
	FileSystemStrategy  string                           `json:"fileSystemStrategy,omitempty" validate:"omitempty,oneof=auto direct relay"`
	FileSystemFilter    *commonmodel.FileSystemFilter    `json:"fileSystemFilter,omitempty"`
	ObjectStorageFilter *commonmodel.ObjectStorageFilter `json:"objectStorageFilter,omitempty"`
	DBMSFilter          *commonmodel.DBMSFilter          `json:"dbmsFilter,omitempty"`
}
