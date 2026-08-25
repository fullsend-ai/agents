# Review Agent

![Review agent icon](icons/review.png)

Code review specialist that evaluates pull requests and merge requests for correctness, security, intent alignment, style, and documentation currency.

## Setup

No additional setup is required beyond the standard fullsend configuration.

## How it helps

- Every PR gets a thorough review within minutes, regardless of team availability.
- Reviews cover security, correctness, intent & coherence, style, and docs currency — dimensions humans sometimes skip under time pressure.

## Triggers

The review agent runs automatically when:

- A PR/MR is opened
- New commits are pushed to a PR/MR (synchronized)
- A PR/MR is moved out of draft

In per-repo installs, it also triggers when the `ready-for-review` label is applied to a PR/MR.

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
| `rejected` | The review agent rejected the PR and closed it. |

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

The upstream skill has per-forge variants (`skills/issue-labels/github/SKILL.md`,
`skills/issue-labels/gitlab/SKILL.md`, and `skills/issue-labels/jira/SKILL.md`),
registered under `forge.<platform>.skills` in the harness. To overload the
built-in skill, create your own skill in
`.agents/skills/issue-labels/github/SKILL.md` and symlink `.claude/skills` to
`.agents/skills` so it's discoverable by both fullsend and local agent tooling.
At the org level, override via `base:` composition (ADR 0045) — inherit the
upstream harness and replace the forge-specific skill entry under
`forge.<platform>.skills` with your own path whose basename matches the built-in
(`github`, `gitlab`, or `jira`), so `mergeSkills` dedupes by basename
(fullsend-ai/fullsend #5409) and yours wins.
The older `customized/skills/issue-labels/SKILL.md` overlay in the org
`.fullsend` config repo is deprecated by ADR 0064.

See [Customizing with AGENTS.md](https://fullsend.sh/docs/guides/user/customizing-with-agents-md) and
[Customizing with Skills](https://fullsend.sh/docs/guides/user/customizing-with-skills).

### Variables

| Variable | Description | Default | Valid values |
|----------|-------------|---------|--------------|
| `FULLSEND_FORGE` | Forge platform. Set automatically by the harness `forge.<platform>.env` section. | (set by harness) | `"github"`, `"gitlab"` |
| `REVIEW_FINDING_SEVERITY_THRESHOLD` | Minimum severity for findings to include in the review. Findings below this level are filtered out at two independent stages (agent output and post-review processing) as defense-in-depth. Default is set in `harness/review.yaml` (`env.runner` and `env.sandbox`). | `low` | `info`, `low`, `medium`, `high`, `critical` |
| `REVIEW_SKIP_AUTHORS` | Comma-separated list of forge usernames to skip review for. When a PR/MR is opened by a user in this list, the review dispatch exits early without running the agent. Set in `env.runner` in your harness YAML (consumed by the pre-script on the runner). | _(empty — all PRs/MRs are reviewed)_ | Comma-separated logins, e.g. `app/renovate,app/dependabot` |
| `REVIEW_PROTECTED_PATHS` | Comma-separated list of path prefixes the review agent treats as protected. PRs that modify files under these paths cannot be approved by the agent — only a human can grant approval. Default is set in `harness/review.yaml` (`env.runner` and `env.sandbox`); an unset value is a misconfiguration (fail-closed). Set to an empty string to deliberately disable protected-path enforcement entirely. When set to a value that parses to no valid paths (e.g. stray or consecutive commas), the script aborts (fail-closed) as a likely misconfiguration. | See [`harness/review.yaml`](../harness/review.yaml) | Comma-separated path prefixes (e.g. `.github/,deploy/,manifests/`) |

Override either variable by extending the harness file via a `base` reference and setting `env.runner` / `env.sandbox` in your custom harness YAML. `base` composition merges `env.runner`/`env.sandbox` per-key — child values override, everything else inherits from the base (ADR 0045, ADR 0055). Per ADR 0080 and ADR 0081, this harness-level override is the correct path; the CI workflow `env:` block is reserved for infrastructure plumbing, not agent behavior knobs like these.

When severity filtering removes all findings from a negative review verdict, the
verdict is downgraded to a comment (applying the `requires-manual-review` label).

### GitLab host validation

`gitlab-review-ops.lib.sh` validates `GITLAB_HOST` against `CI_SERVER_HOST`,
a GitLab CI predefined variable set automatically by the runner. Validation
fails closed when `CI_SERVER_HOST` is not set.

## How the agent works

The review agent follows the same pre-script / sandbox / post-script pipeline as the other agents.

1. **Pre-script** validates inputs and fetches PR metadata.
2. **Sandbox** — the agent runs the `pr-review` orchestrator skill. The orchestrator triages the change, then dispatches specialized sub-agents in parallel — each covering a distinct review dimension (correctness, security, intent & coherence, style & conventions, docs currency, and optionally cross-repo contracts). Sub-agents run concurrently and return structured findings. The orchestrator collects, deduplicates, and synthesizes findings across dimensions, runs PR-level checks (scope authorization, protected paths), and produces a structured JSON review result. A dedicated `challenger` sub-agent adversarially re-checks the merged findings against the source before they are posted, removing false positives and recalibrating severities. The posted review is capped at 10 findings — `critical` and `high` findings are never dropped, and any finding held back is disclosed as a summary line rather than silently omitted. The agent cannot push files, edit code, or push — it is strictly read-only.
3. **Validation loop** — the output is checked against a schema, with up to 2 retry iterations if the output is malformed.
4. **Post-script** posts the review on the PR.

If a prior review exists (e.g., re-review after fixes), it is injected into the sandbox so the agent can assess whether previous findings were addressed.

## Custom network policy

If this agent needs to reach hosts beyond the defaults, see the
[custom network policy guide](network-policy.md).

## Runtime support

Supported runtimes: **claude** (stable default), **pi** (experimental). On pi, review runs in single-context mode — the parallel sub-agent orchestration is replaced by a single-pass review.

Effort: `high` (explicit in the harness; override per run with `fullsend run --effort` or `FULLSEND_EFFORT`, values `low`–`max`).

## Source

[`harness/review.yaml`](../harness/review.yaml)
