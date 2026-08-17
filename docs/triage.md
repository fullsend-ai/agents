# Triage Agent

![Triage agent icon](icons/triage.png)

Inspects an issue, assesses information sufficiency, asks clarifying questions when needed, and produces a triage decision that determines whether the issue is ready for implementation.

## Setup

No additional setup is required beyond the standard fullsend configuration.

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
| `ready-to-code` | The issue is fully specified and low-risk (bug, documentation, performance). Bug and documentation categories also receive their eponymous labels (`bug`, `documentation`) automatically. Triggers the [code agent](code.md). This behavior is configurable via [Variables](#variables). Exception: when `requires_workflow_changes` is set in the triage result, `triaged` is applied instead because the code agent cannot modify workflow files. |
| `triaged` | The issue is fully specified but is a feature or other category that requires human prioritization before coding. |
| `duplicate` | The issue duplicates an existing one. The agent identified the original and the issue is closed automatically. |
| `blocked` | The issue depends on another issue or external condition. The agent identified the blocker. |
| `feature` | The issue is a feature request. Applied alongside `triaged` so humans can prioritize before coding begins. |
| `question` | The issue is a question rather than a bug or feature request. |
| `bug` | The issue is a confirmed bug. Applied alongside `ready-to-code` to categorize the issue. |
| `documentation` | The issue concerns documentation improvements or additions. Applied alongside `ready-to-code` to categorize the issue. |
| `not-planned` | The issue is out of scope, invalid, or spam. The issue is closed with reason "not planned". |
| `pr-open` | An open PR or merge request already addresses this issue. Applied either by the triage agent's `in-progress` action — used when a PR/MR *fixes* the issue, as opposed to `prerequisites`/`blocked` when a PR/MR must merely land first — or by the code agent's pre-check when it finds a human PR before dispatching. No automation clears this label when the linked PR/MR is closed without merging: nothing re-triages on PR/MR close, so the issue keeps `pr-open` — and the in-progress comment stays on the issue — until triage runs again, via an issue edit or a manual `/fs-triage`. |

The `split` action decomposes an issue that bundles multiple independent concerns into separate sub-issues. The agent creates one sub-issue per independent item (in the source repo by default, or in a cross-repo target if allowed by `create_issues.allow_targets` in config.yaml), posts a comment listing the new sub-issues, cleans up stale labels (`blocked`, `needs-info`, `ready-to-code`, `pr-open`), and closes the original issue with reason "completed". Each sub-issue is then triaged independently.

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

The upstream skill has per-forge variants (`skills/issue-labels/github/SKILL.md`
and `skills/issue-labels/gitlab/SKILL.md`), registered under
`forge.<platform>.skills` in the harness. To overload the built-in skill,
create your own skill in `.agents/skills/issue-labels/github/SKILL.md` and
symlink `.claude/skills` to `.agents/skills` so it's discoverable by both
fullsend and local agent tooling. At the org level, override via `base:`
composition (ADR 0045) — inherit the upstream harness and replace the
forge-specific skill entry under `forge.<platform>.skills` with your own path
whose basename matches the built-in (`github` or `gitlab`), so `mergeSkills`
dedupes by basename (fullsend-ai/fullsend #5409) and yours wins.
The older `customized/skills/issue-labels/SKILL.md` overlay in the org
`.fullsend` config repo (and the per-repo `.fullsend/customized/skills/...`
equivalent) is deprecated by ADR 0064.

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

| Variable | Description | Default | Valid values |
|----------|-------------|---------|--------------|
| `TRIAGE_AUTO_CODE` | Controls whether triage auto-applies `ready-to-code`. `on` — auto-promote categories listed in `TRIAGE_AUTO_CODE_CATEGORIES`. `off` — never auto-promote; always apply `triaged`. | `on` | `on`, `off` |
| `TRIAGE_AUTO_CODE_CATEGORIES` | Comma-separated list of categories to auto-promote when `TRIAGE_AUTO_CODE=on`. | `bug,documentation,performance` | `bug`, `documentation`, `performance` |

To override these defaults per repo or org, create a custom harness for the
triage agent the same way the [code agent](code.md#how-to-configure) does —
a `.fullsend/triage.yaml` with a `base:` pointing at
[`harness/triage.yaml`](../harness/triage.yaml) and your own `env.runner`
values, referenced from `.fullsend/config.yaml`.

### Issue filing allowlist

Cross-repo issue creation for prerequisites is governed by
`create_issues.allow_targets` in `config.yaml`. Prerequisite issues
targeting repos outside the allowlist are skipped with a warning and
surfaced in the summary comment so they can be filed manually.

The source repo (where the triaged issue lives) is always implicitly
allowed.

## Multi-forge support

The triage agent supports GitHub, GitLab, and Jira (Cloud only). The forge is
selected automatically at runtime via the `FULLSEND_TRACKER` environment
variable, which the harness sets based on the detected CI platform (`github`,
`gitlab`, or `jira`). Scripts also accept `FULLSEND_FORGE` as a
backward-compatible fallback when `FULLSEND_TRACKER` is not set.

### Jira setup

Jira triage requires the following env vars, mirroring the shape of the
GitHub/GitLab auth vars:

| Variable | Description |
|----------|-------------|
| `JIRA_ISSUE_URL` | The `https://<site>.atlassian.net/browse/<KEY>-<n>` URL of the issue to triage. |
| `JIRA_USER_EMAIL` | Email address of the Jira Cloud account used for Basic auth. |
| `JIRA_TOKEN` | API token for that account. |
| `JIRA_BASE_URL` | Base URL of the Jira Cloud site (e.g. `https://<site>.atlassian.net`). |

Closing an issue (`duplicate`, `not-planned`, `split` actions) performs a
Jira workflow transition rather than a status field write, since Jira has no
universal "closed" state. The transition name for each action is configured
independently:

| Variable | Used for |
|----------|----------|
| `JIRA_DUPLICATE_TRANSITION` | The `duplicate` action. |
| `JIRA_NOT_PLANNED_TRANSITION` | The `not-planned` action. |
| `JIRA_SPLIT_TRANSITION` | Closing the original issue after a `split` action. |

If the relevant variable is unset when that action fires, the post-script
fails loudly rather than silently skipping the close — set all three to the
same transition name if your Jira workflow doesn't distinguish between them.

Cross-project issue creation for Jira prerequisites is gated by a
`create_issues.allow_targets.jira_projects` list of Jira project keys in
`config.yaml`, alongside the existing `orgs`/`repos` keys used for
GitHub/GitLab. The issue's own project is always implicitly allowed.

Jira Server/Data Center (self-hosted) is out of scope — only Jira Cloud hosts
(`*.atlassian.net`) are supported.

### Migration notes for custom harness overrides

If you use `base:` composition to override `harness/triage.yaml`:

- **`ISSUE_URL` replaces `GITHUB_ISSUE_URL` inside scripts**: The sandbox and
  runner env var consumed by pre/post scripts is now `ISSUE_URL`
  (forge-neutral). `GITHUB_ISSUE_URL` (and its `GITLAB_ISSUE_URL` /
  `JIRA_ISSUE_URL` equivalents) remain the workflow-level inputs per forge;
  the harness maps them to `ISSUE_URL` via `env.runner` / `env.sandbox`.
  Custom pre/post scripts that reference `GITHUB_ISSUE_URL` directly should
  switch to `ISSUE_URL`.
- **`FULLSEND_TRACKER` is required**: Pre- and post-scripts require this env var
  to select the correct forge operations (falls back to `FULLSEND_FORGE` if
  unset). It is set automatically by the forge sections in the harness; if your
  override removes the forge sections, set it explicitly in `env.runner` and
  `env.sandbox`.
- **`policy`, `skills`, and `host_files` live in forge sections**: This
  harness defines policy, skills, and the forge-specific env file
  (`env/github/triage.env` / `env/gitlab/triage.env` /
  `env/jira/triage.env`) under `forge.<platform>` rather than at the top
  level. `pre_script` and `post_script` are set at both levels (identical
  values — the forge-level entries are redundant but kept explicit for
  clarity). Top-level keys are still supported by `ResolveForge` — a
  downstream harness using `base:` composition can set top-level `policy:`,
  `skills:`, or `host_files:` and they will work: policy (scalar) is
  overridden by the forge-level value, skills (list) are concatenated with
  forge-level skills and deduped by basename, host_files (list) are
  concatenated with last-writer-wins dedup by `dest`. `providers` and
  `openshell` follow the same merge rules and are also forge-overridable
  (fullsend-ai/fullsend#5970).
- **Schema accepts all forge URL/identifier shapes unconditionally**: The
  result schema validates PR/issue URLs, `duplicate_of`, and repo identifiers
  against GitHub, GitLab, and Jira patterns regardless of the active forge.
  This is intentional — the schema is forge-neutral. Cross-forge issue
  creation (`prerequisites.create`) is enforced at runtime (the forge API
  rejects foreign project paths, and `create_issues.allow_targets` gates it
  further), but comment URLs (`pull_requests[].url`,
  `prerequisites.existing[].url`) are interpolated verbatim and are
  schema-constrained only. The prompt includes examples of the relevant URL
  shape to guide the agent toward the correct format.
- **GitLab and Jira functional eval coverage is deferred**: The eval cases
  under `eval/triage/cases/` currently cover GitHub only. GitLab and Jira
  behavior is covered by unit-level bash tests in
  `scripts/post-triage-test.sh` and `scripts/pre-triage-test.sh` (mocked
  curl/`fullsend` calls, forge dispatch, label operations). End-to-end
  GitLab/Jira eval cases require a matching test fixture environment and
  will be added as follow-up work.

## How the agent works

The triage agent runs in a read-only sandbox. It fetches the issue content — title, body, labels, comments — and reads repository context (architecture docs, existing issues, PRs) to understand the landscape. It then decides whether the issue has enough information to act on, or whether clarification is needed.

The agent's only output is a structured JSON triage result consumed by the post-script, which applies labels and posts a summary comment.

## Custom network policy

If this agent needs to reach hosts beyond the defaults, see the
[custom network policy guide](network-policy.md).

## Source

[`harness/triage.yaml`](../harness/triage.yaml)
