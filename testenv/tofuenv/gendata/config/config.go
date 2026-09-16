// Package config loads the static gendata configuration (config.json) and the
// dynamic infrastructure inputs (OpenTofu outputs, OpenBao credentials, .env).
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// LayoutConfig controls the destination folder tree shared by bucket and filesystem targets.
type LayoutConfig struct {
	FolderDepth   int `json:"folderDepth"`
	FolderBreadth int `json:"folderBreadth"`
}

// ObjectStorageConfig tunes S3 upload behavior (cb-spider S3Manager style).
type ObjectStorageConfig struct {
	BasePrefix       string `json:"basePrefix"`
	Concurrency      int    `json:"concurrency"`
	EndpointOverride string `json:"endpointOverride"`
	BucketLookup     string `json:"bucketLookup"`
}

// FilesystemConfig tunes VM SFTP transfer behavior.
type FilesystemConfig struct {
	BasePath    string `json:"basePath"`
	Concurrency int    `json:"concurrency"`
}

// DummyConfig sets per-format dummy data size in MB (0 = skip).
type DummyConfig struct {
	SizeSQL  int `json:"sizeSQL"`
	SizeCSV  int `json:"sizeCSV"`
	SizeJSON int `json:"sizeJSON"`
	SizeXML  int `json:"sizeXML"`
	SizeTXT  int `json:"sizeTXT"`
	SizePNG  int `json:"sizePNG"`
	SizeGIF  int `json:"sizeGIF"`
	SizeZIP  int `json:"sizeZIP"`
}

// dummyFields maps a format name to its field, so the formats can be addressed
// by name (GENDATA_DUMMY_SIZES=csv=100) without a switch in three places.
func (d *DummyConfig) dummyFields() map[string]*int {
	return map[string]*int{
		"sql": &d.SizeSQL, "csv": &d.SizeCSV, "json": &d.SizeJSON, "xml": &d.SizeXML,
		"txt": &d.SizeTXT, "png": &d.SizePNG, "gif": &d.SizeGIF, "zip": &d.SizeZIP,
	}
}

// DummyFormats lists the format names, in the order they appear in config.json.
func DummyFormats() []string {
	return []string{"csv", "txt", "sql", "json", "xml", "png", "gif", "zip"}
}

// Set assigns one format's size, reporting whether the name is a known format.
func (d *DummyConfig) Set(format string, mb int) bool {
	p, ok := d.dummyFields()[format]
	if !ok {
		return false
	}
	*p = mb
	return true
}

// SetAll assigns every format the same size.
func (d *DummyConfig) SetAll(mb int) {
	for _, p := range d.dummyFields() {
		*p = mb
	}
}

// TotalMB is the size of one generation pass across all formats. The bucket and
// filesystem targets share that pass, so it is also what the VM has to hold.
func (d DummyConfig) TotalMB() int {
	total := 0
	for _, p := range (&d).dummyFields() {
		total += *p
	}
	return total
}

// String renders the per-format sizes for the run log, skipping the formats that
// are switched off. A single total would hide a lopsided GENDATA_DUMMY_SIZES.
func (d DummyConfig) String() string {
	fields := (&d).dummyFields()
	var parts []string
	for _, name := range DummyFormats() {
		if mb := *fields[name]; mb > 0 {
			parts = append(parts, fmt.Sprintf("%s=%d", name, mb))
		}
	}
	if len(parts) == 0 {
		return "all formats off"
	}
	return strings.Join(parts, " ")
}

// DatabaseConfig controls the bulk data phase that follows the shop_db fixture
// load. SizeMB 0 - the default - means fixture only, which is what gendata did
// before this phase existed.
//
// Only SizeMB is expected to change between runs, and .env carries it
// (GENDATA_DB_SIZE_MB). The rest is tuning that a given deployment sets once, if
// ever, which is why it stays here rather than becoming four more .env keys.
type DatabaseConfig struct {
	SizeMB    int `json:"sizeMB"`
	BatchSize int `json:"batchSize"`
	// IDOffset is the primary key the bulk rows start at. It sits far above the
	// fixture's own ids so the two never collide, and so "is this row fixture or
	// bulk" stays answerable from the id alone - which is what lets the bulk rows
	// be deleted again without touching the fixture.
	IDOffset int `json:"idOffset"`
	// Seed makes a run reproducible: the same seed puts logically identical rows
	// into every engine, so a migration can be checked by comparing engines.
	Seed int64 `json:"seed"`
	// Weights splits SizeMB across the tables, by share of bytes. The keys are
	// table names, validated by internal/database, which owns the table list.
	Weights map[string]int `json:"weights"`
}

// Config is the parsed config.json.
type Config struct {
	Layout        LayoutConfig        `json:"layout"`
	ObjectStorage ObjectStorageConfig `json:"objectStorage"`
	Filesystem    FilesystemConfig    `json:"filesystem"`
	Dummy         DummyConfig         `json:"dummy"`
	Database      DatabaseConfig      `json:"database"`
}

// Load reads and validates config.json, applying defaults for missing fields.
func Load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("parse config %s: %w", path, err)
	}
	c.applyDefaults()
	return &c, nil
}

func (c *Config) applyDefaults() {
	if c.ObjectStorage.BasePrefix == "" {
		c.ObjectStorage.BasePrefix = "gendata/"
	}
	if !strings.HasSuffix(c.ObjectStorage.BasePrefix, "/") {
		c.ObjectStorage.BasePrefix += "/"
	}
	if c.ObjectStorage.Concurrency < 1 {
		c.ObjectStorage.Concurrency = 10
	}
	if c.ObjectStorage.BucketLookup == "" {
		c.ObjectStorage.BucketLookup = "auto"
	}
	if c.Filesystem.BasePath == "" {
		c.Filesystem.BasePath = "/home/ubuntu/testdata"
	}
	if c.Filesystem.Concurrency < 1 {
		c.Filesystem.Concurrency = 10
	}
	if c.Layout.FolderBreadth < 1 {
		c.Layout.FolderBreadth = 1
	}
	if c.Layout.FolderDepth < 0 {
		c.Layout.FolderDepth = 0
	}
	if c.Database.BatchSize < 1 {
		c.Database.BatchSize = 1000
	}
	if c.Database.IDOffset < 1 {
		c.Database.IDOffset = 1_000_000
	}
	if c.Database.Seed == 0 {
		c.Database.Seed = 42
	}
	// Weights deliberately keep no default here: internal/database owns the table
	// list, and filling in a copy of it would give the two a chance to disagree.
}
