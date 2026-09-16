package filter

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
)

func init() {
	Register("glob", newGlobMatcher)
}

// globMatcher matches an item's path against a glob pattern.
type globMatcher struct {
	Pattern string `json:"pattern"`
}

func newGlobMatcher(raw json.RawMessage) (Matcher, error) {
	var c struct {
		Pattern string `json:"pattern"`
	}
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, err
	}
	if c.Pattern == "" {
		return nil, fmt.Errorf("glob: pattern is required")
	}
	return &globMatcher{Pattern: c.Pattern}, nil
}

func (g *globMatcher) Type() string { return "glob" }

func (g *globMatcher) Match(item Item) bool {
	return globMatch(g.Pattern, item.Path)
}

// RsyncArgs maps the glob rule to an ordered rsync --include/--exclude flag.
func (g *globMatcher) RsyncArgs(action string) ([]string, error) {
	switch action {
	case ActionInclude:
		return []string{"--include=" + g.Pattern}, nil
	case ActionExclude:
		return []string{"--exclude=" + g.Pattern}, nil
	default:
		return nil, fmt.Errorf("glob: unknown action %q", action)
	}
}

// globMatch matches a path against a glob pattern. It handles the globstar
// prefix "**/" by matching the trailing pattern against the file's base name,
// enabling patterns like "**/*.txt" to match files at any depth.
func globMatch(pattern, path string) bool {
	const globstarPrefix = "**/"
	if strings.HasPrefix(pattern, globstarPrefix) {
		suffix := pattern[len(globstarPrefix):]
		matched, _ := filepath.Match(suffix, filepath.Base(path))
		return matched
	}
	// No globstar: match against the base name for simple patterns like "*.txt",
	// or against the full path for explicit sub-path patterns.
	if matched, _ := filepath.Match(pattern, filepath.Base(path)); matched {
		return matched
	}
	matched, _ := filepath.Match(pattern, path)
	return matched
}
