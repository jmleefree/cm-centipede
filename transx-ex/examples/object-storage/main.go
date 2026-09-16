package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/cloud-barista/cm-centipede/transx-ex"
)

func main() {
	var configFile string
	var verbose bool
	var backupOnly bool
	var transferOnly bool
	var restoreOnly bool

	// Setting up command-line flags
	flag.StringVar(&configFile, "config", "config-minio-upload.json", "Migration configuration JSON file path")
	flag.BoolVar(&verbose, "verbose", false, "Enable verbose logging")
	flag.BoolVar(&backupOnly, "backup", false, "Run only the backup step")
	flag.BoolVar(&transferOnly, "transfer", false, "Run only the transfer step")
	flag.BoolVar(&restoreOnly, "restore", false, "Run only the restore step")
	flag.Parse()

	if verbose {
		fmt.Println("🚀 Starting Object Storage Migration")
		fmt.Printf("📁 Configuration file: %s\n", configFile)
	}

	startTime := time.Now()

	// Load migration configuration
	task, err := loadMigrationConfig(configFile)
	if err != nil {
		log.Fatalf("❌ Error loading migration configuration: %v", err)
	}

	// Execute migration steps
	if err := executeMigrationSteps(task, backupOnly, transferOnly, restoreOnly, verbose); err != nil {
		log.Fatalf("❌ Migration failed: %v", err)
	}

	totalDuration := time.Since(startTime)
	if verbose {
		fmt.Printf("✅ Migration completed successfully in %s\n", totalDuration)
	}
}

func loadMigrationConfig(configFile string) (transxex.StorageMigrationModel, error) {
	var task transxex.StorageMigrationModel

	file, err := os.Open(configFile)
	if err != nil {
		return task, fmt.Errorf("failed to open config file: %w", err)
	}
	defer file.Close()

	decoder := json.NewDecoder(file)
	if err := decoder.Decode(&task); err != nil {
		return task, fmt.Errorf("failed to decode JSON: %w", err)
	}

	return task, nil
}

func executeMigrationSteps(task transxex.StorageMigrationModel, backupOnly, transferOnly, restoreOnly, verbose bool) error {
	if verbose {
		fmt.Println("📋 Executing migration steps...")
	}

	// Determine which steps to run
	runBackup := !transferOnly && !restoreOnly
	runTransfer := !backupOnly && !restoreOnly
	runRestore := !backupOnly && !transferOnly

	if backupOnly {
		runBackup = true
		runTransfer = false
		runRestore = false
	}
	if transferOnly {
		runBackup = false
		runTransfer = true
		runRestore = false
	}
	if restoreOnly {
		runBackup = false
		runTransfer = false
		runRestore = true
	}

	// Execute individual steps based on user selection
	if runBackup {
		// Only run backup if PreCmd is defined
		if strings.TrimSpace(task.Source.PreCmd) != "" {
			if verbose {
				fmt.Println("📦 Starting backup step...")
			}
			if err := transxex.RunStoragePreCommand(task.Source); err != nil {
				return fmt.Errorf("backup failed: %w", err)
			}
			if verbose {
				fmt.Println("✅ Backup completed successfully")
			}
		} else if verbose {
			fmt.Println("⏭️ Skipping backup step (no pre-command defined)")
		}
	}

	if runTransfer {
		if verbose {
			fmt.Println("🔄 Starting transfer step...")
		}
		if err := transxex.TransferStorage(task); err != nil {
			return fmt.Errorf("transfer failed: %w", err)
		}
		if verbose {
			fmt.Println("✅ Transfer completed successfully")
		}
	}

	if runRestore {
		// Only run restore if PostCmd is defined
		if strings.TrimSpace(task.Destination.PostCmd) != "" {
			if verbose {
				fmt.Println("🔧 Starting restore step...")
			}
			if err := transxex.RunStoragePostCommand(task.Destination); err != nil {
				return fmt.Errorf("restore failed: %w", err)
			}
			if verbose {
				fmt.Println("✅ Restore completed successfully")
			}
		} else if verbose {
			fmt.Println("⏭️ Skipping restore step (no post-command defined)")
		}
	}

	return nil
}
