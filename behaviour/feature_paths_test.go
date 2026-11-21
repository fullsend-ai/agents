package behaviour_test

import (
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// featurePaths is every feature under root, or the space-separated godog
// paths in features (BEHAVIOUR_FEATURES, relative to root, e.g.
// "features/fix.feature" or "features/triage.feature:3"), so CI can run the
// suite in shards.
func featurePaths(root, features string) []string {
	paths := strings.Fields(features)
	if len(paths) == 0 {
		return []string{filepath.Join(root, "features")}
	}
	for i, path := range paths {
		paths[i] = filepath.Join(root, path)
	}
	return paths
}

func TestFeaturePaths(t *testing.T) {
	root := filepath.Join("/src", "behaviour")
	tests := []struct {
		name     string
		features string
		want     []string
	}{
		{"unset", "", []string{filepath.Join(root, "features")}},
		{"blank", "  \t ", []string{filepath.Join(root, "features")}},
		{"file", "features/fix.feature", []string{filepath.Join(root, "features/fix.feature")}},
		{"line", "features/triage.feature:3", []string{filepath.Join(root, "features/triage.feature:3")}},
		{"directory", "features/review", []string{filepath.Join(root, "features/review")}},
		{
			"several",
			" features/fix.feature  features/code\n",
			[]string{filepath.Join(root, "features/fix.feature"), filepath.Join(root, "features/code")},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := featurePaths(root, tt.features); !slices.Equal(got, tt.want) {
				t.Errorf("featurePaths(%q, %q) = %q, want %q", root, tt.features, got, tt.want)
			}
		})
	}
}
