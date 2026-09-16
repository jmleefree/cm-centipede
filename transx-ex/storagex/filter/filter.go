// Package filter provides an extensible, ordered filter pipeline for transx-ex.
//
// A pipeline is a list of Rules evaluated top-to-bottom; the first Rule whose
// Matcher matches an Item decides the outcome (include keeps it, exclude drops
// it). When no Rule matches, the item is included (default keep).
//
// Each Rule carries a Matcher — a pluggable predicate keyed by a "type" string.
// Built-in matchers (glob, size) register themselves; new matcher types can be
// added with Register, so filters can be extended without touching this file.
package filter

import "time"

// Action constants for a filter Rule.
const (
	ActionInclude = "include"
	ActionExclude = "exclude"
)

// Item is the input a Matcher evaluates: the metadata of one file, directory,
// or object storage prefix.
type Item struct {
	Path    string    // absolute path or object key/prefix
	Name    string    // base name (last path segment)
	Size    int64     // size in bytes (0 for prefixes)
	ModTime time.Time // modification time (zero when unknown)
	IsDir   bool      // whether the item is a directory/prefix
}

// Matcher is a single filter predicate. Type returns the registry key used to
// (de)serialise the matcher.
type Matcher interface {
	Match(item Item) bool
	Type() string
}

// RsyncTranslator is implemented by matchers that can be expressed as native
// rsync CLI arguments. Matchers that do not implement it cannot be used with
// rsync-based transfers (the executor returns an error).
type RsyncTranslator interface {
	// RsyncArgs returns the rsync flags for this matcher under the given action,
	// or an error when the matcher cannot be expressed natively.
	RsyncArgs(action string) ([]string, error)
}

// Option is the filter configuration attached to a DataLocation.
//
// Rules is the ordered pipeline. Include/Exclude are the simple form: they
// apply only when Rules is empty, and are normalised into equivalent glob rules
// by EffectiveRules. MaxDepth limits the scan depth for inspect (structural,
// independent of the rules).
type Option struct {
	Rules    []Rule   `json:"rules,omitempty"`
	Include  []string `json:"include,omitempty"` // simple form — used only when Rules is empty
	Exclude  []string `json:"exclude,omitempty"` // simple form — used only when Rules is empty
	MaxDepth int      `json:"maxDepth"`          // maximum scan depth; 0 = unlimited
}

// Match evaluates the pipeline against item. The first matching rule wins;
// when no rule matches the item is included. A nil Option matches everything.
func (o *Option) Match(item Item) bool {
	if o == nil {
		return true
	}
	for _, r := range o.EffectiveRules() {
		if r.Matcher != nil && r.Matcher.Match(item) {
			return r.Action == ActionInclude
		}
	}
	return true
}

// EffectiveRules returns Rules when set, otherwise the simple Include/Exclude
// normalised into equivalent glob rules: excludes first (exclude wins), then —
// if any include exists — the includes followed by a catch-all exclude, which
// makes the include list a whitelist.
func (o *Option) EffectiveRules() []Rule {
	if o == nil {
		return nil
	}
	if len(o.Rules) > 0 {
		return o.Rules
	}
	var rules []Rule
	for _, e := range o.Exclude {
		rules = append(rules, Rule{Action: ActionExclude, Matcher: &globMatcher{Pattern: e}})
	}
	if len(o.Include) > 0 {
		for _, i := range o.Include {
			rules = append(rules, Rule{Action: ActionInclude, Matcher: &globMatcher{Pattern: i}})
		}
		rules = append(rules, Rule{Action: ActionExclude, Matcher: &globMatcher{Pattern: "*"}})
	}
	return rules
}
