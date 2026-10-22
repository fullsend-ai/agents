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
// the fullsend checkout replace that the behaviour workflow sets up. Keep its
// cel-go version equal to fullsend's go.mod: bump it in the same change that
// moves the fullsend pin. renovate.json disables updates for this go.mod so
// the two cannot drift apart.
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
	// An ancestor go.work or an exported GOFLAGS (-mod=vendor, -modfile)
	// would resolve a different module, or none.
	cmd.Env = append(os.Environ(), "GOWORK=off", "GOFLAGS=-mod=mod")
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

func sub(t *testing.T, m map[string]any, key string) map[string]any {
	t.Helper()
	v, ok := m[key].(map[string]any)
	if !ok {
		t.Fatalf("fixture field %q is %T, not an object", key, m[key])
	}
	return v
}

// triggerCase evaluates a harness trigger against a fixture, optionally
// edited first.
type triggerCase struct {
	name    string
	fixture string
	edit    func(t *testing.T, ev map[string]any)
	want    bool
}

func runTriggerCases(t *testing.T, harnessFile string, cases []triggerCase) {
	t.Helper()
	prg := compileTrigger(t, loadTrigger(t, filepath.Join("..", harnessFile)))
	dir := fixturesDir(t)
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ev := loadFixture(t, dir, tc.fixture)
			if tc.edit != nil {
				tc.edit(t, ev)
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

func TestReviewTrigger(t *testing.T) {
	runTriggerCases(t, "review.yaml", []triggerCase{
		{name: "PR opened", fixture: "pr-opened.json", want: true},
		{name: "fork PR opened", fixture: "pr-opened-fork.json", want: true},
		{name: "PR synchronized", fixture: "pr-synchronized.json", want: true},
		{name: "MR opened", fixture: "gitlab-mr-opened.json", want: true},
		{
			name:    "PR marked ready",
			fixture: "pr-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "transition")["kind"] = "marked_ready"
			},
			want: true,
		},
		{
			name:    "ready-for-review label added to a PR",
			fixture: "pr-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				ev["transition"] = map[string]any{
					"kind":  "label_changed",
					"label": map[string]any{"name": "ready-for-review", "action": "added"},
				}
			},
			want: true,
		},
		{
			name:    "ready-for-review label added to a PR by a bot",
			fixture: "pr-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				ev["transition"] = map[string]any{
					"kind":  "label_changed",
					"label": map[string]any{"name": "ready-for-review", "action": "added"},
				}
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: true,
		},
		{
			name:    "/fs-review comment on a PR",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-review"
			},
			want: true,
		},
		{
			name:    "/fs-review comment on a PR whose lookup failed",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-review"
				delete(sub(t, ev, "state"), "change_proposal")
			},
			want: true,
		},
		{
			name:    "/fs-review comment on an MR",
			fixture: "gitlab-mr-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
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
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-review"
				delete(sub(t, ev, "entity"), "linked_change_proposal")
				delete(sub(t, ev, "state"), "change_proposal")
			},
			want: false,
		},
		{
			name:    "/fs-review comment by a bot",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-review"
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: false,
		},
		{
			name:    "comment without a command",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				delete(sub(t, sub(t, ev, "transition"), "comment"), "command")
			},
			want: false,
		},
		{
			name:    "/fs-review comment edited on a PR",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "transition")["kind"] = "comment_edited"
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-review"
			},
			want: false,
		},
		{
			name:    "/fs-review comment on a Jira issue",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-review"
			},
			want: false,
		},
		{name: "/fs-fix comment on a PR", fixture: "fs-fix-comment.json", want: false},
		{name: "/fs-vouch comment on a discussion", fixture: "discussion-fs-vouch-comment.json", want: false},
		{
			name:    "other label added to a PR",
			fixture: "pr-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
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
			edit: func(t *testing.T, ev map[string]any) {
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
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "label")["name"] = "ready-for-review"
			},
			want: false,
		},
		{name: "ready-to-code label added to an issue", fixture: "ready-to-code-labeled.json", want: false},
		{
			name:    "PR reopened",
			fixture: "pr-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "transition")["kind"] = "reopened"
			},
			want: false,
		},
		{name: "PR closed", fixture: "pr-closed.json", want: false},
		{name: "MR merged", fixture: "gitlab-mr-merged.json", want: false},
		{name: "review requested changes", fixture: "review-changes-requested.json", want: false},
		{name: "issue opened", fixture: "issue-opened.json", want: false},
	})
}

func TestRetroTrigger(t *testing.T) {
	runTriggerCases(t, "retro.yaml", []triggerCase{
		{name: "PR closed", fixture: "pr-closed.json", want: true},
		{
			name:    "PR merged",
			fixture: "pr-closed.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "transition")["kind"] = "merged"
			},
			want: true,
		},
		{
			name:    "PR closed by a bot",
			fixture: "pr-closed.json",
			edit: func(t *testing.T, ev map[string]any) {
				actor := sub(t, ev, "actor")
				actor["kind"] = "bot"
				actor["role"] = "none"
			},
			want: true,
		},
		{
			name:    "PR closed by its read-only author",
			fixture: "pr-closed.json",
			edit: func(t *testing.T, ev map[string]any) {
				actor := sub(t, ev, "actor")
				actor["role"] = "read"
				actor["is_entity_author"] = true
			},
			want: true,
		},
		{name: "MR merged", fixture: "gitlab-mr-merged.json", want: true},
		{
			name:    "/fs-retro comment on a PR",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-retro"
			},
			want: true,
		},
		{
			name:    "/fs-retro comment on an issue",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-retro"
				delete(sub(t, ev, "entity"), "linked_change_proposal")
				delete(sub(t, ev, "state"), "change_proposal")
			},
			want: true,
		},
		{
			name:    "/fs-retro comment on an MR",
			fixture: "gitlab-mr-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				ev["transition"] = map[string]any{
					"kind":    "comment_added",
					"comment": map[string]any{"command": "/fs-retro", "body": "/fs-retro"},
				}
			},
			want: true,
		},
		{
			name:    "/fs-retro comment by a bot",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-retro"
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: false,
		},
		{
			name:    "/fs-retro comment edited on a PR",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "transition")["kind"] = "comment_edited"
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-retro"
			},
			want: false,
		},
		{
			name:    "/fs-retro comment on a Jira issue",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-retro"
			},
			want: false,
		},
		{
			name:    "/fs-retro comment on a discussion",
			fixture: "discussion-fs-vouch-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "comment")["command"] = "/fs-retro"
			},
			want: false,
		},
		{
			name:    "comment without a command",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				delete(sub(t, sub(t, ev, "transition"), "comment"), "command")
			},
			want: false,
		},
		{name: "/fs-fix comment on a PR", fixture: "fs-fix-comment.json", want: false},
		{
			name:    "issue closed",
			fixture: "issue-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "transition")["kind"] = "closed"
			},
			want: false,
		},
		{
			name:    "PR reopened",
			fixture: "pr-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "transition")["kind"] = "reopened"
			},
			want: false,
		},
		{name: "PR opened", fixture: "pr-opened.json", want: false},
		{name: "PR synchronized", fixture: "pr-synchronized.json", want: false},
		{name: "review requested changes", fixture: "review-changes-requested.json", want: false},
		{name: "ready-to-code label added to an issue", fixture: "ready-to-code-labeled.json", want: false},
		{name: "issue opened", fixture: "issue-opened.json", want: false},
	})
}

func setCommand(t *testing.T, ev map[string]any, command string) {
	t.Helper()
	sub(t, sub(t, ev, "transition"), "comment")["command"] = command
}

func setLabel(ev map[string]any, name, action string) {
	ev["transition"] = map[string]any{
		"kind":  "label_changed",
		"label": map[string]any{"name": name, "action": action},
	}
}

// toMRNote turns a GitHub PR comment fixture into the GitLab MR-note shape:
// a change_proposal entity without linked_change_proposal.
func toMRNote(t *testing.T, ev map[string]any) {
	t.Helper()
	entity := sub(t, ev, "entity")
	entity["kind"] = "change_proposal"
	delete(entity, "linked_change_proposal")
	sub(t, ev, "source")["system"] = "gitlab"
}

func TestTriageTrigger(t *testing.T) {
	runTriggerCases(t, "triage.yaml", []triggerCase{
		{name: "issue opened", fixture: "issue-opened.json", want: true},
		{
			name:    "issue edited",
			fixture: "issue-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "transition")["kind"] = "edited"
			},
			want: true,
		},
		{
			name:    "issue opened by a bot",
			fixture: "issue-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: false,
		},
		{
			name:    "issue edited by a bot",
			fixture: "issue-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "transition")["kind"] = "edited"
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: false,
		},
		{
			name:    "issue reopened",
			fixture: "issue-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "transition")["kind"] = "reopened"
			},
			want: false,
		},
		{
			name:    "issue opened with source.system jira",
			fixture: "issue-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "source")["system"] = "jira"
				sub(t, ev, "entity")["key"] = "PROJ-1"
			},
			want: true,
		},
		{
			name:    "ready-for-triage label added to an issue by a bot",
			fixture: "ready-to-code-labeled.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, sub(t, ev, "transition"), "label")["name"] = "ready-for-triage"
			},
			want: true,
		},
		{
			name:    "ready-for-triage label added to an issue by a human",
			fixture: "issue-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				setLabel(ev, "ready-for-triage", "added")
			},
			want: true,
		},
		{
			name:    "ready-for-triage label removed from an issue",
			fixture: "issue-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				setLabel(ev, "ready-for-triage", "removed")
			},
			want: false,
		},
		{
			name:    "ready-for-triage label added to a PR",
			fixture: "pr-opened.json",
			edit: func(t *testing.T, ev map[string]any) {
				setLabel(ev, "ready-for-triage", "added")
			},
			want: false,
		},
		{name: "ready-to-code label added to an issue", fixture: "ready-to-code-labeled.json", want: false},
		{name: "/fs-triage comment on a Jira issue", fixture: "jira-fs-triage-comment.json", want: true},
		{
			name:    "/fs-triage comment on a PR",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-triage")
			},
			want: true,
		},
		{
			name:    "/fs-triage comment on an issue",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-triage")
				delete(sub(t, ev, "entity"), "linked_change_proposal")
				delete(sub(t, ev, "state"), "change_proposal")
			},
			want: true,
		},
		{
			name:    "/fs-triage comment by a bot",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: false,
		},
		{
			name:    "/fs-triage comment on an MR",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-triage")
				toMRNote(t, ev)
			},
			want: true,
		},
		{
			name:    "/fs-triage comment edited",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-triage")
				sub(t, ev, "transition")["kind"] = "comment_edited"
			},
			want: false,
		},
		{
			name:    "/fs-triage comment on a discussion",
			fixture: "discussion-fs-vouch-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-triage")
			},
			want: false,
		},
		{
			name:    "comment without a command",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				delete(sub(t, sub(t, ev, "transition"), "comment"), "command")
			},
			want: false,
		},
		{name: "/fs-fix comment on a PR", fixture: "fs-fix-comment.json", want: false},
		{name: "PR opened", fixture: "pr-opened.json", want: false},
		{name: "MR opened", fixture: "gitlab-mr-opened.json", want: false},
		{name: "PR closed", fixture: "pr-closed.json", want: false},
		{name: "review requested changes", fixture: "review-changes-requested.json", want: false},
	})
}

func TestPrioritizeTrigger(t *testing.T) {
	runTriggerCases(t, "prioritize.yaml", []triggerCase{
		{
			name:    "/fs-prioritize comment on an issue",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-prioritize")
				delete(sub(t, ev, "entity"), "linked_change_proposal")
				delete(sub(t, ev, "state"), "change_proposal")
			},
			want: true,
		},
		{
			name:    "/fs-prioritize comment on a PR",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-prioritize")
			},
			want: true,
		},
		{
			name:    "/fs-prioritize comment on a Jira issue",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-prioritize")
			},
			want: true,
		},
		{
			name:    "/fs-prioritize comment on an MR",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-prioritize")
				toMRNote(t, ev)
			},
			want: true,
		},
		{
			name:    "/fs-prioritize comment by a bot",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-prioritize")
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: false,
		},
		{
			name:    "/fs-prioritize comment edited",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-prioritize")
				sub(t, ev, "transition")["kind"] = "comment_edited"
			},
			want: false,
		},
		{
			name:    "/fs-prioritize comment on a discussion",
			fixture: "discussion-fs-vouch-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-prioritize")
			},
			want: false,
		},
		{name: "/fs-triage comment on a Jira issue", fixture: "jira-fs-triage-comment.json", want: false},
		{name: "issue opened", fixture: "issue-opened.json", want: false},
		{name: "ready-to-code label added to an issue", fixture: "ready-to-code-labeled.json", want: false},
		{name: "PR opened", fixture: "pr-opened.json", want: false},
	})
}

// Dispatch skips an agent whose trigger errors (for example on a missing
// key), so every trigger must evaluate cleanly on every fixture shape.
func TestTriggersEvaluateOnEveryFixture(t *testing.T) {
	dir := fixturesDir(t)
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil || len(files) == 0 {
		t.Fatalf("listing fixtures in %s: %v", dir, err)
	}
	harnessFiles, err := filepath.Glob(filepath.Join("..", "*.yaml"))
	if err != nil {
		t.Fatalf("listing harness files: %v", err)
	}
	tested := 0
	for _, harnessFile := range harnessFiles {
		if !hasTrigger(t, harnessFile) {
			continue
		}
		tested++
		prg := compileTrigger(t, loadTrigger(t, harnessFile))
		for _, f := range files {
			t.Run(filepath.Base(harnessFile)+"/"+filepath.Base(f), func(t *testing.T) {
				ev := loadFixture(t, dir, filepath.Base(f))
				if _, _, err := prg.Eval(map[string]any{"event": ev}); err != nil {
					t.Errorf("evaluating trigger: %v", err)
				}
			})
		}
	}
	if tested == 0 {
		t.Fatal("no harness file in harness/ declares a trigger")
	}
}

func hasTrigger(t *testing.T, harnessFile string) bool {
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
	return strings.TrimSpace(h.Trigger) != ""
}
