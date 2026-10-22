// Tests for the CEL trigger expressions in the harness/ files.
//
// The CEL environment and evaluation mirror fullsend's
// internal/harness/trigger.go (one root variable, event, of dyn type, and a
// bool result), which cannot be imported from outside fullsend. Events are
// the NormalizedEvent v1 example fixtures from the fullsend version pinned in
// the repository root go.mod; cases the fixtures do not cover are derived
// from one with a small edit.
//
// This is its own module because the root module cannot be tidied without
// the fullsend checkout replace that the behaviour workflow sets up.
package triggertest

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"go.yaml.in/yaml/v3"
)

func loadTrigger(t *testing.T, harnessFile string) string {
	t.Helper()
	data, err := os.ReadFile(harnessFile)
	if err != nil {
		t.Fatalf("reading %s: %v", harnessFile, err)
	}
	var h struct {
		Trigger string `yaml:"trigger"`
	}
	if err := yaml.Unmarshal(data, &h); err != nil {
		t.Fatalf("parsing %s: %v", harnessFile, err)
	}
	if strings.TrimSpace(h.Trigger) == "" {
		t.Fatalf("%s has no trigger", harnessFile)
	}
	return h.Trigger
}

func compileTrigger(t *testing.T, expr string) cel.Program {
	t.Helper()
	env, err := cel.NewEnv(cel.Variable("event", cel.DynType))
	if err != nil {
		t.Fatalf("creating CEL env: %v", err)
	}
	ast, issues := env.Compile(expr)
	if issues != nil && issues.Err() != nil {
		t.Fatalf("compiling trigger: %v", issues.Err())
	}
	if !ast.OutputType().IsExactType(types.BoolType) {
		t.Fatalf("trigger must evaluate to bool, got %v", ast.OutputType())
	}
	prg, err := env.Program(ast)
	if err != nil {
		t.Fatalf("building CEL program: %v", err)
	}
	return prg
}

func fixturesDir(t *testing.T) string {
	t.Helper()
	// Resolve the fullsend version the repository root go.mod pins.
	cmd := exec.Command("go", "mod", "download", "-json", "github.com/fullsend-ai/fullsend")
	cmd.Dir = filepath.Join("..", "..")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("downloading the pinned fullsend module: %v", err)
	}
	var mod struct{ Dir string }
	if err := json.Unmarshal(out, &mod); err != nil || mod.Dir == "" {
		t.Fatalf("locating the pinned fullsend module in %q: %v", out, err)
	}
	return filepath.Join(mod.Dir, "docs", "normative", "normalized-event", "v1", "examples")
}

func loadFixture(t *testing.T, dir, name string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatalf("reading fixture %s: %v", name, err)
	}
	var ev map[string]any
	if err := json.Unmarshal(data, &ev); err != nil {
		t.Fatalf("parsing fixture %s: %v", name, err)
	}
	return ev
}

func sub(m map[string]any, key string) map[string]any {
	return m[key].(map[string]any)
}

func TestReviewTrigger(t *testing.T) {
	prg := compileTrigger(t, loadTrigger(t, filepath.Join("..", "review.yaml")))
	dir := fixturesDir(t)

	cases := []struct {
		name    string
		fixture string
		edit    func(ev map[string]any)
		want    bool
	}{
		{name: "PR opened", fixture: "pr-opened.json", want: true},
		{name: "fork PR opened", fixture: "pr-opened-fork.json", want: true},
		{name: "PR synchronized", fixture: "pr-synchronized.json", want: true},
		{name: "MR opened", fixture: "gitlab-mr-opened.json", want: true},
		{
			name:    "PR marked ready",
			fixture: "pr-opened.json",
			edit: func(ev map[string]any) {
				sub(ev, "transition")["kind"] = "marked_ready"
			},
			want: true,
		},
		{
			name:    "ready-for-review label added to a PR",
			fixture: "pr-opened.json",
			edit: func(ev map[string]any) {
				ev["transition"] = map[string]any{
					"kind":  "label_changed",
					"label": map[string]any{"name": "ready-for-review", "action": "added"},
				}
			},
			want: true,
		},
		{
			name:    "/fs-review comment on a PR",
			fixture: "fs-fix-comment.json",
			edit: func(ev map[string]any) {
				sub(sub(ev, "transition"), "comment")["command"] = "/fs-review"
			},
			want: true,
		},
		{
			name:    "/fs-review comment on a PR whose lookup failed",
			fixture: "fs-fix-comment.json",
			edit: func(ev map[string]any) {
				sub(sub(ev, "transition"), "comment")["command"] = "/fs-review"
				delete(sub(ev, "state"), "change_proposal")
			},
			want: true,
		},
		{
			name:    "/fs-review comment on an MR",
			fixture: "gitlab-mr-opened.json",
			edit: func(ev map[string]any) {
				ev["transition"] = map[string]any{
					"kind":    "comment_added",
					"comment": map[string]any{"command": "/fs-review", "body": "/fs-review"},
				}
			},
			want: true,
		},
		{
			name:    "/fs-review comment on an issue",
			fixture: "fs-fix-comment.json",
			edit: func(ev map[string]any) {
				sub(sub(ev, "transition"), "comment")["command"] = "/fs-review"
				delete(sub(ev, "entity"), "linked_change_proposal")
				delete(sub(ev, "state"), "change_proposal")
			},
			want: false,
		},
		{
			name:    "/fs-review comment by a bot",
			fixture: "fs-fix-comment.json",
			edit: func(ev map[string]any) {
				sub(sub(ev, "transition"), "comment")["command"] = "/fs-review"
				sub(ev, "actor")["kind"] = "bot"
			},
			want: false,
		},
		{
			name:    "comment without a command",
			fixture: "fs-fix-comment.json",
			edit: func(ev map[string]any) {
				delete(sub(sub(ev, "transition"), "comment"), "command")
			},
			want: false,
		},
		{name: "/fs-fix comment on a PR", fixture: "fs-fix-comment.json", want: false},
		{name: "/fs-vouch comment on a discussion", fixture: "discussion-fs-vouch-comment.json", want: false},
		{
			name:    "other label added to a PR",
			fixture: "pr-opened.json",
			edit: func(ev map[string]any) {
				ev["transition"] = map[string]any{
					"kind":  "label_changed",
					"label": map[string]any{"name": "kind/bug", "action": "added"},
				}
			},
			want: false,
		},
		{
			name:    "ready-for-review label removed from a PR",
			fixture: "pr-opened.json",
			edit: func(ev map[string]any) {
				ev["transition"] = map[string]any{
					"kind":  "label_changed",
					"label": map[string]any{"name": "ready-for-review", "action": "removed"},
				}
			},
			want: false,
		},
		{
			name:    "ready-for-review label added to an issue",
			fixture: "ready-to-code-labeled.json",
			edit: func(ev map[string]any) {
				sub(sub(ev, "transition"), "label")["name"] = "ready-for-review"
			},
			want: false,
		},
		{name: "ready-to-code label added to an issue", fixture: "ready-to-code-labeled.json", want: false},
		{name: "PR closed", fixture: "pr-closed.json", want: false},
		{name: "MR merged", fixture: "gitlab-mr-merged.json", want: false},
		{name: "review requested changes", fixture: "review-changes-requested.json", want: false},
		{name: "issue opened", fixture: "issue-opened.json", want: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ev := loadFixture(t, dir, tc.fixture)
			if tc.edit != nil {
				tc.edit(ev)
			}
			out, _, err := prg.Eval(map[string]any{"event": ev})
			if err != nil {
				t.Fatalf("evaluating trigger: %v", err)
			}
			got, ok := out.Value().(bool)
			if !ok {
				t.Fatalf("trigger result is %T, not bool", out.Value())
			}
			if got != tc.want {
				t.Errorf("trigger = %v, want %v", got, tc.want)
			}
		})
	}
}
