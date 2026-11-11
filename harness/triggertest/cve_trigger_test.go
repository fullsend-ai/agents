package triggertest

import "testing"

// DRAFT: trigger cases for harness/cve.yaml (the cve assessment agent).
func TestCveTrigger(t *testing.T) {
	runTriggerCases(t, "cve.yaml", []triggerCase{
		{
			name:    "cve label added to an issue",
			fixture: "ready-to-code-labeled.json",
			edit:    func(t *testing.T, ev map[string]any) { setLabel(ev, "cve", "added") },
			want:    true,
		},
		{
			name:    "cve label added by a bot (the Dependabot bridge workflow)",
			fixture: "ready-to-code-labeled.json",
			edit: func(t *testing.T, ev map[string]any) {
				setLabel(ev, "cve", "added")
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: true,
		},
		{
			name:    "cve label removed",
			fixture: "ready-to-code-labeled.json",
			edit:    func(t *testing.T, ev map[string]any) { setLabel(ev, "cve", "removed") },
			want:    false,
		},
		{
			name:    "a verdict label does not re-trigger the agent",
			fixture: "ready-to-code-labeled.json",
			edit:    func(t *testing.T, ev map[string]any) { setLabel(ev, "cve:affected", "added") },
			want:    false,
		},
		{name: "ready-to-code label added to an issue", fixture: "ready-to-code-labeled.json", want: false},
		{
			name:    "/fs-cve comment on an issue from a human",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-cve")
				asIssueComment(t, ev)
			},
			want: true,
		},
		{
			name:    "/fs-cve comment on an issue from a bot",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-cve")
				asIssueComment(t, ev)
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: false,
		},
		{
			name:    "/fs-cve comment on a pull request",
			fixture: "fs-fix-comment.json",
			edit:    func(t *testing.T, ev map[string]any) { setCommand(t, ev, "/fs-cve") },
			want:    false,
		},
		{
			name:    "/fs-cve comment on a Jira issue",
			fixture: "jira-fs-triage-comment.json",
			edit:    func(t *testing.T, ev map[string]any) { setCommand(t, ev, "/fs-cve") },
			want:    true,
		},
		{
			name:    "/fs-code comment on an issue",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-code")
				asIssueComment(t, ev)
			},
			want: false,
		},
	})
}

// DRAFT: a work item labelled `cve` is routed to the cve agent, not triage.
func TestTriageSkipsCveWorkItems(t *testing.T) {
	withLabels := func(labels ...any) func(*testing.T, map[string]any) {
		return func(t *testing.T, ev map[string]any) { sub(t, ev, "state")["labels"] = labels }
	}
	runTriggerCases(t, "triage.yaml", []triggerCase{
		{name: "issue opened with no cve label", fixture: "issue-opened.json", edit: withLabels("bug"), want: true},
		{name: "issue opened with the cve label", fixture: "issue-opened.json", edit: withLabels("cve"), want: false},
		{
			name:    "/fs-triage on a cve work item",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-triage")
				asIssueComment(t, ev)
				sub(t, ev, "state")["labels"] = []any{"cve", "cve:affected"}
			},
			want: false,
		},
	})
}

// DRAFT: the code agent takes a cve work item only after an affected verdict.
func TestCodeRequiresCveVerdict(t *testing.T) {
	withLabels := func(labels ...any) func(*testing.T, map[string]any) {
		return func(t *testing.T, ev map[string]any) { sub(t, ev, "state")["labels"] = labels }
	}
	runTriggerCases(t, "code.yaml", []triggerCase{
		{name: "ready-to-code, not a cve item", fixture: "ready-to-code-labeled.json", edit: withLabels("ready-to-code", "bug"), want: true},
		{name: "ready-to-code on a cve item with no verdict", fixture: "ready-to-code-labeled.json", edit: withLabels("ready-to-code", "cve"), want: false},
		{name: "ready-to-code on a cve item judged not affected", fixture: "ready-to-code-labeled.json", edit: withLabels("ready-to-code", "cve", "cve:not-affected"), want: false},
		{name: "ready-to-code on a cve item judged affected", fixture: "ready-to-code-labeled.json", edit: withLabels("ready-to-code", "cve", "cve:affected"), want: true},
		// A real tracker carries no `cve` label; the verdict label alone marks it as assessed.
		{name: "ready-to-code on an assessed tracker with no cve label, affected", fixture: "ready-to-code-labeled.json", edit: withLabels("ready-to-code", "vulnerability-tracker", "cve:affected"), want: true},
		{name: "ready-to-code on an assessed tracker with no cve label, fixed", fixture: "ready-to-code-labeled.json", edit: withLabels("ready-to-code", "vulnerability-tracker", "cve:fixed"), want: false},
		{
			name:    "/fs-code on a cve item with no verdict",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				setCommand(t, ev, "/fs-code")
				asIssueComment(t, ev)
				sub(t, ev, "state")["labels"] = []any{"cve"}
			},
			want: false,
		},
	})
}
