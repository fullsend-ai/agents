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

When risk assessment is enabled (`REVIEW_RISK_ASSESSMENT_ENABLED`), the
post-script applies a `risk/*` label reflecting the composite risk score:

| Label | Score | Meaning |
|-------|-------|---------|
| `risk/low` | 1 | Minimal risk — small, well-scoped change |
| `risk/moderate` | 2 | Some complexity or breadth |
| `risk/elevated` | 3 | Touches sensitive areas or has notable blast radius |
| `risk/high` | 4 | Security-sensitive, large, or cross-cutting change |
| `risk/critical` | 5 | Highest risk — auth, RBAC, or critical infrastructure |

Risk labels are informational — they do not gate the review outcome.

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
| `REVIEW_RISK_ASSESSMENT_ENABLED` | Enables the risk assessment (GitHub only). When `true`, the orchestrator dispatches a risk-assessment sub-agent alongside the review dimensions. The sub-agent computes a composite 1–5 risk score from metadata signals, git history, and linked issue context. The post-script applies a `risk/*` label and posts a sticky risk comment. Set in `forge.github.env` in the harness — not in the top-level `env:` block, since the risk assessment scripts depend on the GitHub API and produce fabricated scores on other forges. | `true` (GitHub) | `"true"`, `"false"` |
| `REVIEW_GIT_FETCH_DEPTH` | Controls clone deepening for git history analysis (risk assessment Tier 2). When set to `"0"`, the pre-script unshallows the target repo clone so the risk-assessment sub-agent can access full commit history. When unset and `REVIEW_RISK_ASSESSMENT_ENABLED` is `true`, defaults to `"0"` automatically — the Tier 2 sub-agent requires full git history. Set explicitly to any other value (e.g., `"1"`) to disable deepening even with risk assessment enabled. Set in `env.runner` in harness YAML (consumed by the pre-script on the runner). | _(auto: `"0"` when risk assessment enabled, no deepening otherwise)_ | `"0"` to fully unshallow |
| `TIMEOUT_SECONDS` | Mirror of the harness `timeout_minutes`, in seconds, read by the `pr-review` skill to skip the challenger pass and write a result before the deadline (see [Time budget](#time-budget)). Set in `env.sandbox`; change it together with `timeout_minutes`. | `2700` | Seconds, equal to `timeout_minutes × 60` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Fleet-wide base pin for the `sonnet` alias on the Claude Code runtime, exported by [`env/gcp-vertex.env`](../env/gcp-vertex.env) (mounted by every harness). Claude Code resolves the alias itself — for the main model, the Agent tool's `model:` argument and sub-agent frontmatter — and a pinned alias is used as written with no startup fallback. Override it when your Vertex project does not serve the pinned id. With `opus` unpinned, a run that reaches the CLI with no `--model` defaults to this id; every harness here sets `model:`. | `claude-sonnet-4-6` | A Claude model id your Vertex project serves, set via `env.sandbox` in a `base:` overlay |

Override any variable by extending the harness file via a `base` reference and setting `env.runner` / `env.sandbox` in your custom harness YAML. `base` composition merges `env.runner`/`env.sandbox` per-key — child values override, everything else inherits from the base (ADR 0045, ADR 0055). Per ADR 0080 and ADR 0081, this harness-level override is the correct path; the CI workflow `env:` block is reserved for infrastructure plumbing, not agent behavior knobs like these.

When severity filtering removes all findings from a negative review verdict, the
verdict is downgraded to a comment (applying the `requires-manual-review` label).
The severity threshold is absolute — it applies to all findings regardless of
the `actionable` flag, respecting the user's configured threshold throughout.

### GitLab host validation

`gitlab-review-ops.lib.sh` validates `GITLAB_HOST` against `CI_SERVER_HOST`,
a GitLab CI predefined variable set automatically by the runner. Validation
fails closed when `CI_SERVER_HOST` is not set.

## How the agent works

The review agent follows the same pre-script / sandbox / post-script pipeline as the other agents.

1. **Pre-script** validates inputs and fetches PR metadata.
2. **Sandbox** — the agent runs the `pr-review` orchestrator skill. The orchestrator runs a security-triage pre-pass for large PRs, then dispatches the specialized dimension sub-agents in parallel (plus the risk-assessment sub-agent when enabled), each covering a distinct review dimension (correctness, security, intent & coherence, style & conventions, docs currency, and optionally cross-repo contracts). Sub-agents run concurrently and return structured findings. The orchestrator collects, deduplicates, and synthesizes findings across dimensions, runs PR-level checks (scope authorization, protected paths), and produces a structured JSON review result. The agent cannot push files, edit code, or push — it is strictly read-only.
3. **Validation loop** — the output is checked against a schema. The review harness runs a single iteration (see [Time budget](#time-budget)).
4. **Post-script** posts the review on the PR.

If a prior review exists (e.g., re-review after fixes), it is injected into the sandbox so the agent can assess whether previous findings were addressed.

## Time budget

The runner gives the sandbox `timeout_minutes` (45 in
[`harness/review.yaml`](../harness/review.yaml)) and kills it at the
deadline — no wrap-up, no partial result. The harness mirrors the same
value into the sandbox as `TIMEOUT_SECONDS` so the orchestrator can
budget its own tail.

### Where the time goes

A review is six phases, and only one of them scales with the PR:

| Phase | What happens | Typical |
|---|---|---|
| context | PR metadata, diff and PR-head files written to `/sandbox/workspace/` (a manifest marks each file `ok`, `too-large`, `binary`, `failed` or `unsafe`) | 1–2 min |
| dispatch | prompts composed; risk assessment + dimension sub-agents in one message | 3 min |
| dimensions | sub-agents review in parallel; `correctness` is the long pole | 4–13 min (grows with the diff) |
| synthesis | merge, de-duplicate | ~1 min |
| challenger | one sub-agent re-checks every finding | 2.5–6 min |
| assembly | `agent-result.json`, schema check | ~1 min |

A 51-line PR and a 5 700-line PR both spend 13–18 minutes on the fixed
part (every row above except the size-dependent share of `dimensions`), which is why the former 20-minute budget killed small PRs as
readily as large ones. A local run of this harness on a 29-file,
2 475-line PR (`fullsend run review --fullsend-dir <agents checkout>
--target-repo <clone at main> --env-file <env> --forge github
--no-post-script`) looks like this — on the old budget it would have
been killed at 20m0s with the challenger running:

```
  0m30s  AGENT_START recorded — TIMEOUT_SECONDS=2700, REMAINING=2580s
  1m26s  pr-head: 29 of 29 files in 3s
  2m–5m  prompts composed; 5 dimension sub-agents + risk assessment dispatched in one message
  7m00s  time check: Elapsed: 394s, Remaining: 2186s
  7m48s  risk-assessment done (1.0 min)
  8m24s  docs-currency done · 8m30s intent-coherence · 8m54s security · 9m12s style-conventions
 18m18s  correctness done (13.1 min — the long pole on this PR)
 19m00s  time check: Elapsed: 1130s, Remaining: 1450s → challenger dispatched
 23m54s  challenger done (3.7 min)
 25m00s  agent-result.json written, fullsend-check-output passed
 25m30s  ✓ Agent exited with code 0 (1532.8s) · ✓ Validation passed
```

### What happens at the deadline

Two checkpoints in the `pr-review` skill keep the run from ending with
nothing:

- With under 600 s left before the challenger pass, the challenger is
  skipped and a `low` finding says so (`time budget: <n>s
  remaining`). The review is still posted.
- With under 240 s left while dimension sub-agents are still running,
  the orchestrator writes a `failure` result with `reason: time-budget`.
  The post-script posts that as the review notice:

  ```
  ## Review

  **Reason:** time-budget

  This PR was NOT reviewed. Do not count this as an approval.
  ```

If the sandbox is killed anyway, the workflow log ends with

```
  ⏳ Agent running (45m0s elapsed, 0s remaining)
  ! Agent exited with code -1
  ✗ Validation failed: FAIL: output/agent-result.json not found
  ! Skipping post-script: validation did not pass
Error: validation failed after 1 iteration(s)
```

and nothing is posted on the PR. The `dispatch / Review` check goes red;
it is not a required check. Re-triggering (`/fs-review`) re-runs from
scratch — do that only after the cause is understood (see below).

### Changing the budget

Override both keys together in a `base:` overlay — the skill's
checkpoints read `TIMEOUT_SECONDS`, the runner reads `timeout_minutes`:

```yaml
base: harness/review.yaml
timeout_minutes: 60
env:
  sandbox:
    TIMEOUT_SECONDS: "3600"
```

`validation_loop.max_iterations` is 1 on purpose: the runner cannot yet
tell a timeout from a schema failure
([fullsend-ai/fullsend#7042](https://github.com/fullsend-ai/fullsend/issues/7042)),
so a second iteration replays a killed review from scratch with no
memory of the first. Restore 2 with `feedback_mode: append` once that
lands.

### Troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| `validation failed after 1 iteration(s)` right after `Agent running (45m0s elapsed, 0s remaining)` | the deadline; usually a huge diff or a stalled sub-agent | check the transcript for which phase was running; raise the budget via the overlay above |
| review posted with a `low` finding `time budget: …` | challenger skipped to make the deadline | none — findings were still produced by the dimension sub-agents |
| failure notice `Reason: time-budget` | dimensions were still running at the deadline | the PR is larger than the budget; raise it or split the PR |
| `The model claude-sonnet-… is not available` in the transcript, sub-agents re-dispatched | `ANTHROPIC_DEFAULT_SONNET_MODEL` not served by your Vertex project | see the variable table above |

## Custom network policy

If this agent needs to reach hosts beyond the defaults, see the
[custom network policy guide](network-policy.md).

## Runtime support

Supported runtimes: **claude** (stable default), **pi** (experimental). On pi, review runs in single-context mode — the parallel sub-agent orchestration is replaced by a single-pass review.

Effort: `high` (explicit in the harness; override per run with `fullsend run --effort` or `FULLSEND_EFFORT`, values `low`–`max`).

## Source

[`harness/review.yaml`](../harness/review.yaml)
