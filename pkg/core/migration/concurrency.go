package migration

import (
	"github.com/cloud-barista/cm-centipede/pkg/config"
	"github.com/cloud-barista/cm-centipede/transx-ex"
)

// ResolveConcurrency returns the concurrency a migration runs with: the one its
// request named, else the server's configured default. Zero means neither was
// set, and transx-ex then runs at its own default (transxex.DefaultConcurrency).
//
// It is resolved at execution rather than stored at creation, like the staging
// root (ResolveStagingDir), so a retry of a migration that named none follows
// the configuration in effect when the retry runs.
func ResolveConcurrency(requested int) int {
	if requested > 0 {
		return requested
	}
	return config.Conf.Migration.Concurrency
}

// CheckConcurrency checks a concurrency a request or the configuration names:
// 0 for the default, or 1 to transxex.MaxConcurrency. The error names the
// field itself ("concurrency 33 is out of range ...").
func CheckConcurrency(n int) error {
	return transxex.ValidateConcurrency(n)
}

// concurrencyReport is what an item ran at, as transx-ex reported it: zero
// when it did not report.
type concurrencyReport struct {
	n    int
	note string
}
