# Review Agent

![Review agent icon](icons/review.png)

Code review specialist that evaluates pull requests for correctness, security, intent alignment, style, and documentation currency.

## How it helps

- Every PR gets a thorough review within minutes, regardless of team availability.
- Reviews cover security, correctness, intent & coherence, style, and docs currency — dimensions humans sometimes skip under time pressure.

## Triggers

The review agent runs automatically when:

- A PR is opened
- New commits are pushed to a PR (synchronized)
- A PR is moved out of draft

In per-repo installs, it also triggers when the `ready-for-review` label is applied to a PR.

All automatic triggers require the actor to have write-level repository permission (admin, maintain, or write).

It can also be triggered manually with the `/fs-review` command.

## Commands

| Command | Where | Effect |
|---------|-------|--------|
| `/fs-review` | PR comment | Triggers a review on the PR (per-repo installs only; standalone issues are ignored) |

Requires write-level repository permission (admin, maintain, or write).

The `/fs-review` command does not accept arguments.

## Control labels

These labels reflect the review outcome and are updated after each review.

| Label | Meaning |
|-------|---------|
| `ready-for-review` | Workflow state marker on the PR. Applied by the [code agent](code.md) after pushing. In per-repo installs, triggers review when applied to a PR. |
| `ready-for-merge` | The review agent approved the PR. No blocking findings. |
| `requires-manual-review` | The review agent found issues that require human judgment — it could not confidently approve or reject. |
| `rejected` | The review agent rejected the PR and the PR was closed. |

When the review agent requests changes (without rejecting), no outcome label is
applied — the `pull_request_review` event triggers the [fix agent](fix.md) directly.

Stale outcome labels from prior review runs are removed before the new one is
applied.

The `issue-labels` skill may also apply contextual labels (e.g., `area/api`,
`priority/high`) but these are informational — they do not control agent
behavior.

## Configuration

### Skill: `issue-labels`

The review agent includes the `issue-labels` skill to discover your repo's
labels and apply them to PRs during review. This is the same skill used by the
[triage agent](triage.md) — overloading it affects both agents.

To overload the built-in skill, create your own `issue-labels` skill in
`.agents/skills/issue-labels/SKILL.md` and symlink `.claude/skills` to
`.agents/skills` so it's discoverable by both fullsend and local agent tooling.
You can also overload it at the org level in your `.fullsend` config repo at
`customized/skills/issue-labels/SKILL.md`. At runtime, your version replaces
the upstream default — no other configuration needed.

See [Customizing with AGENTS.md](https://fullsend.sh/docs/guides/user/customizing-with-agents-md) and
[Customizing with Skills](https://fullsend.sh/docs/guides/user/customizing-with-skills).

### Variables

| Variable | Description | Default | Valid values |
|----------|-------------|---------|--------------|
| `REVIEW_FINDING_SEVERITY_THRESHOLD` | Minimum severity for findings to include in the review. Findings below this level are omitted. | `low` | `info`, `low`, `medium`, `high`, `critical` |

Set this in the CI workflow `env:` block.

When filtering removes all findings from a negative review verdict, the verdict
is downgraded to a comment (applying the `requires-manual-review` label).

## How the agent works

The review agent follows the same pre-script / sandbox / post-script pipeline as the other agents.

1. **Pre-script** validates inputs and fetches PR metadata.
2. **Sandbox** — the agent runs the `pr-review` orchestrator skill. The orchestrator triages the change, then dispatches specialized sub-agents in parallel — each covering a distinct review dimension (correctness, security, intent & coherence, style & conventions, docs currency, and optionally cross-repo contracts). Sub-agents run concurrently and return structured findings. The orchestrator collects, deduplicates, and synthesizes findings across dimensions, runs PR-level checks (scope authorization, protected paths), and produces a structured JSON review result. The agent cannot push files, edit code, or push — it is strictly read-only.
3. **Validation loop** — the output is checked against a schema, with up to 2 retry iterations if the output is malformed.
4. **Post-script** posts the review on the PR.

If a prior review exists (e.g., re-review after fixes), it is injected into the sandbox so the agent can assess whether previous findings were addressed.

## Source

[`harness/review.yaml`](../harness/review.yaml)
