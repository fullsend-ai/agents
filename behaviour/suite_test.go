//go:build behaviour

package behaviour_test

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/fullsend-ai/fullsend/pkg/behaviourtest"
)

func TestBehaviour(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("finding behaviour suite source path")
	}

	root := filepath.Dir(sourceFile)
	behaviourtest.RunSuite(t, behaviourtest.SuiteOptions{
		FeaturePaths: featurePaths(root, os.Getenv("BEHAVIOUR_FEATURES")),
		FixturesRoot: "behaviour",
	})
}
