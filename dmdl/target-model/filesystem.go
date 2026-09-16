package targetmodel

import commonmodel "github.com/cloud-barista/cm-centipede/dmdl/common-model"

// FSMigrationInfo represents a single directory migration task unit.
// Rules mirror the transx-ex filter pipeline applied to this folder.
type FSMigrationInfo struct {
	Order   int                          `json:"order"`
	SrcPath string                       `json:"srcPath"  validate:"required"`
	DstPath string                       `json:"dstPath"  validate:"required"`
	Rules   []commonmodel.PathFilterRule `json:"rules,omitempty"`
}

// MigrationFileSystemModel holds a filesystem-source migration: SSH→SSH by default,
// or filesystem→objectstorage cross-storage when DstType is objectstorage.
// The source is always a filesystem (SSH); DstType names the destination storage.
type MigrationFileSystemModel struct {
	SrcConnection commonmodel.ConnectionRef `json:"srcConnection" validate:"required"`
	DstConnection commonmodel.ConnectionRef `json:"dstConnection" validate:"required"`
	// DstType is the destination storage type: empty/"filesystem" = SSH→SSH,
	// "objectstorage" = filesystem→objectstorage cross-storage.
	DstType string `json:"dstType,omitempty" validate:"omitempty,oneof=filesystem objectstorage"`
	// Strategy is the transx transfer strategy (auto/direct/relay). It only affects
	// SSH→SSH transfers; cross-storage always relays. Set by the plan layer.
	Strategy string            `json:"strategy,omitempty" validate:"omitempty,oneof=auto direct relay"`
	Folders  []FSMigrationInfo `json:"folders,omitempty"`
	Errors   []string          `json:"errors,omitempty"`
}
