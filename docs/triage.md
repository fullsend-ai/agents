# Triage Agent

<img src="icons/triage.png" alt="Triage agent icon" width="80">

Inspects a GitHub issue, assesses information sufficiency, asks clarifying questions when needed, and produces a triage decision that determines whether the issue is ready for implementation.

## How it helps

- New issues get a response within minutes instead of waiting for a human to notice them.
- Issues missing critical information get a clarification request immediately, shortening the feedback loop with the reporter.
- Well-specified issues are labeled and ready for the [code agent](code.md) without human intervention.

## Triggers

The triage agent runs automatically when:

- A new issue is opened
- An existing issue is edited
- Someone comments on an issue labeled `needs-info` (to re-evaluate after the reporter provides clarification)

It can also be triggered manually with the `/fs-triage` command.

## Commands

| Command | Where | Effect |
|---------|-------|--------|
| `/fs-triage` | Issue comment | Runs triage on the issue |

The `/fs-triage` command does not accept arguments — it re-evaluates the issue
using current content, comments, and any prior triage analysis.

## Control labels

These labels are managed by the triage agent based on its assessment of the issue.

| Label | Meaning |
|-------|---------|
| `needs-info` | The issue lacks sufficient information. The agent posted clarifying questions. |
| `ready-to-code` | The issue is fully specified and low-risk (bug, documentation, performance). Bug and documentation categories also receive their eponymous labels (`bug`, `documentation`) automatically. Triggers the [code agent](code.md). |
| `triaged` | The issue is fully specified but is a feature or other category that requires human prioritization before coding. |
| `duplicate` | The issue duplicates an existing one. The agent identified the original and the issue is closed automatically. |
| `blocked` | The issue depends on another issue or external condition. The agent identified the blocker. |
| `feature` | The issue is a feature request. Applied alongside `triaged` so humans can prioritize before coding begins. |
| `question` | The issue is a question rather than a bug or feature request. |
| `bug` | The issue is a confirmed bug. Applied alongside `ready-to-code` to categorize the issue. |
| `documentation` | The issue concerns documentation improvements or additions. Applied alongside `ready-to-code` to categorize the issue. |
| `not-planned` | The issue is out of scope, invalid, or spam. The issue is closed with reason "not planned". |
| `pr-open` | An open PR already addresses this issue. Applied either by the triage agent's `in-progress` action — used when a PR *fixes* the issue, as opposed to `prerequisites`/`blocked` when a PR must merely land first — or by the code agent's pre-check when it finds a human PR before dispatching. No automation clears this label when the linked PR is closed without merging: nothing re-triages on PR close, so the issue keeps `pr-open` — and the in-progress comment stays on the issue — until triage runs again, via an issue edit or a manual `/fs-triage`. |

The `issue-labels` skill may also apply contextual labels (e.g., `area/api`,
`kind/bug`) but these are informational — they do not control agent behavior.

## Configuration

See [Customizing with AGENTS.md](https://fullsend.sh/docs/guides/user/customizing-with-agents-md) and
[Customizing with Skills](https://fullsend.sh/docs/guides/user/customizing-with-skills).

### Skill: `issue-labels`

The triage agent includes a built-in `issue-labels` skill that discovers your
repo's labels and applies them opportunistically during triage. You can replace
it with your own version to encode your team's labeling knowledge directly in
the skill, keeping it out of `AGENTS.md` (where it would bloat context for
every agent).

To overload the built-in skill, create your own `issue-labels` skill in
`.agents/skills/issue-labels/SKILL.md` and symlink `.claude/skills` to
`.agents/skills` so it's discoverable by both fullsend and local agent tooling.
You can also overload it at the org level in your `.fullsend` config repo at
`customized/skills/issue-labels/SKILL.md`. At runtime, your version replaces
the upstream default — no other configuration needed.

Here's an example that encodes domain-specific labeling rules:

```markdown
---
name: issue-labels
description: >-
  Apply contextual labels to triaged issues using team labeling conventions.
---

# Issue Labels

Apply labels to the issue being triaged. Use the conventions below — do not
invent labels or apply labels not listed here.

## Control labels (never recommend these)

These are managed by the triage pipeline. Never include them in `label_actions`:
`needs-info`, `ready-to-code`, `duplicate`, `feature`, `blocked`, `triaged`, `question`, `bug`, `documentation`, `not-planned`, `pr-open`.

## Area labels

- `area/api` — REST or gRPC surface in `pkg/api/`.
- `area/operator` — Kubernetes controller-runtime code in `internal/controller/`.
  Apply this even if the issue doesn't say "operator" — if it mentions
  reconciliation, finalizers, or CRDs, it belongs here.
- `area/ci` — GitHub Actions workflows, Tekton pipelines, build scripts.

## Kind labels

- `kind/bug` — confirmed defect in existing behavior.
- `kind/flaky-test` — use this instead of `kind/bug` for intermittent test
  failures. These route to a different team.
- `kind/feature` — new capability request.

## Priority labels

- `priority/critical` — production outages or data loss only. Do not apply
  based on user frustration alone.

## Special labels

- `needs/design` — the issue describes a desired outcome but the approach is
  unclear. When applying this label, do NOT also label `ready-to-code`.

## Output

Include recommendations in `label_actions`:

    "label_actions": {
      "reason": "Single sentence explaining the label choices.",
      "actions": [
        { "action": "add", "label": "area/api" }
      ]
    }
```

This gives the triage agent the subtlety it needs to distinguish between
`kind/bug` and `kind/flaky-test`, or to know that `area/operator` applies to
controller-runtime code, without adding label documentation to `AGENTS.md`
where every agent would pay the context cost.

### Variables

None.

## How the agent works

The triage agent runs in a read-only sandbox. It fetches the issue content — title, body, labels, comments — and reads repository context (architecture docs, existing issues, PRs) to understand the landscape. It then decides whether the issue has enough information to act on, or whether clarification is needed.

The agent's only output is a structured JSON triage result consumed by the post-script, which applies labels and posts a summary comment.

## Source

[`harness/triage.yaml`](../harness/triage.yaml)
