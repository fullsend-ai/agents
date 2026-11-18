package triggertest

import "testing"

// DRAFT: trigger cases for the cve agent (harness/cve.yaml) and for the
// fullsend-cve routing in harness/code.yaml and harness/triage.yaml.

// asJiraTicket sets the Jira issue type and labels of a Jira fixture.
func asJiraTicket(t *testing.T, ev map[string]any, issueType string, labels ...string) {
	t.Helper()
	state := sub(t, ev, "state")
	state["labels"] = toAny(labels)
	if issueType != "" {
		state["issue_type"] = map[string]any{"id": "1", "name": issueType, "is_subtask": false}
	}
}

func toAny(values []string) []any {
	out := make([]any, len(values))
	for i, v := range values {
		out[i] = v
	}
	return out
}

func TestCveTrigger(t *testing.T) {
	cveCommand := func(issueType string) func(*testing.T, map[string]any) {
		return func(t *testing.T, ev map[string]any) {
			setCommand(t, ev, "/fs-cve-triage")
			asJiraTicket(t, ev, issueType, "fullsend-cve", "cve-public")
		}
	}
	runTriggerCases(t, "cve.yaml", []triggerCase{
		{name: "/fs-cve-triage on a Jira Task", fixture: "jira-fs-triage-comment.json", edit: cveCommand("Task"), want: true},
		{name: "/fs-cve-triage on a Jira Bug", fixture: "jira-fs-triage-comment.json", edit: cveCommand("Bug"), want: true},
		{name: "/fs-cve-triage on a Jira Vulnerability", fixture: "jira-fs-triage-comment.json", edit: cveCommand("Vulnerability"), want: true},
		{name: "/fs-cve-triage on a Jira Epic", fixture: "jira-fs-triage-comment.json", edit: cveCommand("Epic"), want: false},
		{name: "/fs-cve-triage on an event with no issue type", fixture: "jira-fs-triage-comment.json", edit: cveCommand(""), want: false},
		{
			name:    "/fs-cve-triage from a bot",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				cveCommand("Task")(t, ev)
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: false,
		},
		{
			name:    "/fs-cve-triage from a person without write access",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				cveCommand("Task")(t, ev)
				sub(t, ev, "actor")["role"] = "read"
			},
			want: false,
		},
		{
			name:    "/fs-triage on a CVE ticket",
			fixture: "jira-fs-triage-comment.json",
			edit:    func(t *testing.T, ev map[string]any) { asJiraTicket(t, ev, "Task", "fullsend-cve") },
			want:    false,
		},
		{
			name:    "fullsend-cve label added to a Jira Task",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asJiraTicket(t, ev, "Task", "fullsend-cve", "cve-public")
				setLabel(ev, "fullsend-cve", "added")
			},
			want: true,
		},
		{
			name:    "fullsend-cve label removed",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asJiraTicket(t, ev, "Task", "cve-public")
				setLabel(ev, "fullsend-cve", "removed")
			},
			want: false,
		},
		{
			name:    "another label added to a CVE ticket",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asJiraTicket(t, ev, "Task", "fullsend-cve", "cve-public")
				setLabel(ev, "cve-public", "added")
			},
			want: false,
		},
		{
			name:    "fullsend-cve label added to a Jira Epic",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asJiraTicket(t, ev, "Epic", "fullsend-cve")
				setLabel(ev, "fullsend-cve", "added")
			},
			want: false,
		},
		{
			name:    "CVE ticket opened by a bot, as the alert step does",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asJiraTicket(t, ev, "Task", "fullsend-cve", "cve-public")
				ev["transition"] = map[string]any{"kind": "opened"}
				actor := sub(t, ev, "actor")
				actor["kind"], actor["role"] = "bot", "none"
			},
			want: true,
		},
		{
			name:    "CVE ticket opened by a person with write access",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asJiraTicket(t, ev, "Task", "fullsend-cve", "cve-public")
				ev["transition"] = map[string]any{"kind": "opened"}
			},
			want: true,
		},
		{
			name:    "CVE ticket opened by a person without write access",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asJiraTicket(t, ev, "Task", "fullsend-cve", "cve-public")
				ev["transition"] = map[string]any{"kind": "opened"}
				sub(t, ev, "actor")["role"] = "read"
			},
			want: false,
		},
		{
			name:    "any other ticket opened by a bot",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asJiraTicket(t, ev, "Task", "bug")
				ev["transition"] = map[string]any{"kind": "opened"}
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: false,
		},
		{
			name:    "CVE ticket edited by a bot",
			fixture: "jira-fs-triage-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asJiraTicket(t, ev, "Task", "fullsend-cve", "cve-public")
				ev["transition"] = map[string]any{"kind": "edited"}
				sub(t, ev, "actor")["kind"] = "bot"
			},
			want: false,
		},
		{
			name:    "/fs-cve-triage on a GitHub issue",
			fixture: "fs-fix-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asIssueComment(t, ev)
				setCommand(t, ev, "/fs-cve-triage")
			},
			want: false,
		},
	})
}

func TestCodeTriggerCveTickets(t *testing.T) {
	runTriggerCases(t, "code.yaml", []triggerCase{
		{
			name:    "/fs-code from a person on a CVE ticket",
			fixture: "jira-fs-code-assignee-comment.json",
			edit:    func(t *testing.T, ev map[string]any) { asJiraTicket(t, ev, "Task", "fullsend-cve", "cve-public") },
			want:    true,
		},
		{
			name:    "ready-to-code label on a CVE ticket",
			fixture: "jira-fs-code-assignee-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asJiraTicket(t, ev, "Task", "fullsend-cve", "cve-public")
				setLabel(ev, "ready-to-code", "added")
			},
			want: false,
		},
		{
			name:    "ready-to-code label on any other Jira ticket",
			fixture: "jira-fs-code-assignee-comment.json",
			edit: func(t *testing.T, ev map[string]any) {
				asJiraTicket(t, ev, "Task", "bug")
				setLabel(ev, "ready-to-code", "added")
			},
			want: true,
		},
	})
}

func TestTriageTriggerSkipsCveTickets(t *testing.T) {
	runTriggerCases(t, "triage.yaml", []triggerCase{
		{
			name:    "/fs-triage on a CVE ticket",
			fixture: "jira-fs-triage-comment.json",
			edit:    func(t *testing.T, ev map[string]any) { asJiraTicket(t, ev, "Task", "fullsend-cve") },
			want:    false,
		},
		{
			name:    "/fs-triage on any other Jira ticket",
			fixture: "jira-fs-triage-comment.json",
			edit:    func(t *testing.T, ev map[string]any) { asJiraTicket(t, ev, "Task", "bug") },
			want:    true,
		},
	})
}
