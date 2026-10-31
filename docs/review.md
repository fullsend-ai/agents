# Review Agent

![Review agent icon](icons/review.png)

Code review specialist that evaluates pull requests and merge requests for correctness, security, intent alignment, style, documentation currency, and user experience.

## Setup

No additional setup is required beyond the standard fullsend configuration.

## How it helps

- Every PR gets a thorough review within minutes, regardless of team availability.
- Reviews cover security, correctness, intent & coherence, style, docs currency, and user experience by default, with cross-repo contract checks when applicable. Any persona, UXD included, can be disabled or added with a skill file override (see [Add, replace or disable a review persona](#add-replace-or-disable-a-review-persona)).

## Triggers

The review agent runs automatically when:

- A PR/MR is opened
- New commits are pushed to a PR/MR (synchronized)
- A PR/MR is moved out of draft

In per-repo installs, it also triggers when the `ready-for-review` label is applied to a PR/MR.

All automatic triggers require the actor to have write-level repository permission (admin, maintain, or write).

It can also be triggered manually with the `/fs-review` command.

The harness also declares a CEL `trigger:` for fullsend's harness dispatch that selects the same events on GitHub (on GitLab, MR opened and `/fs-review` only). Dispatch does not evaluate it for the built-in review agent yet, so the routing above is what runs today.

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
| `requires-manual-review` | The review agent found issues that require human judgment — it could not confidently approve or reject. Also applied when the risk verdict gate downgrades an approval. |
| `rejected` | The review agent rejected the PR and closed it. |

Each review run on an open PR removes `ready-for-merge` before the review
starts, including runs skipped by `REVIEW_SKIP_AUTHORS`. The label comes back
only when that run approves the current head.

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

Risk score gates the review outcome when risk assessment is enabled:
- **Score ≥ threshold** (default threshold `4` = high/critical) — the review verdict is downgraded from `approve`
  to `comment`, withholding bot approval for this review cycle (a prior bot
  approval remains unless the repository dismisses stale reviews on new pushes).
- **Score missing or degraded** — same downgrade; the review completes as `comment`
  without a complete risk assessment (fail-closed).
- **Threshold is configurable** via `REVIEW_RISK_VERDICT_THRESHOLD` (default `"4"`).
  Invalid thresholds (anything other than an integer 1–6) fail the post-script with an error,
  and no review is posted. Set `6` to disable the gate entirely (informational scoring only).
  Unrecognized `REVIEW_RISK_ASSESSMENT_ENABLED` values also fail closed the same way.
- **Downgraded reviews** receive the `requires-manual-review` outcome label
  (not `ready-for-merge`), blocking auto-merge.

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

### Add, replace or disable a review persona

The review agent runs one sub-agent per review area, called a persona. You can turn a persona off, swap in your own version, or add a new one, without copying the review skill.

#### Before you start

You need a fullsend release that applies skill file overrides from a `base:` overlay.

You work in two files:

- `.fullsend/config.yaml` registers your overlay. You change it once.
- `.fullsend/review.yaml` is the overlay. You make every persona change here.

First, register the overlay in `.fullsend/config.yaml`. The overlay has no effect until you do.

```yaml
# .fullsend/config.yaml (add to your existing file)
agents:
  - name: review
    source: review.yaml
allowed_remote_resources:
  - https://raw.githubusercontent.com/fullsend-ai/agents/
```

- `source` is relative to `.fullsend/`.
- The `allowed_remote_resources` entry must cover the `base:` URL in your overlay.

Then write the overlay. It starts from the stock review harness with `base:` and then lists your changes under `skills:`. Each example below is a complete overlay you can copy.

To get the `<SHA>` and `<sha256sum>` values, follow [Custom sandbox image — How to configure](code.md#how-to-configure) and use `harness/review.yaml` in place of `harness/code.yaml`. See also [AGENTS.md §7](../AGENTS.md#7-skill-resolution).

Each line under `skills/pr-review:` maps a persona path in the skill to a file in your repository. The path on the left is relative to the skill. The path on the right is relative to `.fullsend/`.

#### Disable a persona

Map the persona's path to `null`. This example turns off the user-experience persona:

```yaml
# .fullsend/review.yaml
base: https://raw.githubusercontent.com/fullsend-ai/agents/<SHA>/harness/review.yaml#sha256=<sha256sum>
skills:
  - skills/pr-review:
      sub-agents/user-experience.md: null
```

If you set `REVIEW_UX_ENABLED: "false"` before, delete it and use this override instead. The variable is no longer read. To turn off the UX reviewer, remove `sub-agents/user-experience.md` with a skills override, as shown above.

#### Add a persona

Map a new path under `sub-agents/` to your persona file:

```yaml
# .fullsend/review.yaml
base: https://raw.githubusercontent.com/fullsend-ai/agents/<SHA>/harness/review.yaml#sha256=<sha256sum>
skills:
  - skills/pr-review:
      sub-agents/rbac-review.md: personas/rbac-review.md
```

Then create the persona file at `.fullsend/personas/rbac-review.md`:

```markdown
---
name: rbac-review
description: Reviews Kubernetes RBAC manifests for over-broad grants.
role: dimension
when: >-
  The diff adds or changes a Kubernetes RBAC manifest (Role, ClusterRole,
  RoleBinding or ClusterRoleBinding), or YAML with `rules:` holding `verbs:`.
categories:
  - rbac-violation
  - privilege-escalation
failure_severity: medium
---

# RBAC review

You review only Kubernetes RBAC manifests in the diff. Each changed Role or ClusterRole rule must grant only the resources and verbs the change needs.

Raise a finding when a rule:

- uses `*` in `verbs`, `resources` or `apiGroups`;
- grants `escalate`, `bind` or `impersonate`;
- grants write verbs on `secrets`, `roles`, `clusterroles`, `rolebindings` or `clusterrolebindings`;
- binds a ClusterRole cluster-wide where a namespaced RoleBinding would do.

Use category `privilege-escalation` for escalate/bind/impersonate or for writes to RBAC objects, and `rbac-violation` for the other cases. Point at the file and line of the rule. Say which narrower grant fixes it.
```

#### Replace a persona

Map an existing persona path to your own file. This example swaps in your own security persona:

```yaml
# .fullsend/review.yaml
base: https://raw.githubusercontent.com/fullsend-ai/agents/<SHA>/harness/review.yaml#sha256=<sha256sum>
skills:
  - skills/pr-review:
      sub-agents/security.md: personas/security.md
```

Keep `name: security` in your file, so the name still matches `sub-agents/security.md`.

#### Rules

- `name` must equal the persona's file name under `sub-agents/`, without `.md`. The agent skips a file whose name does not match.
- `role: dimension` makes the persona selectable. A persona without it never runs as a review area.
- `when` is what the agent matches against the diff. Write the kinds of change that should trigger the persona.
- `always: true` runs the persona on every review, whatever the diff. Use it instead of `when` for checks you always want.
- `categories` must come from the closed `category` list in [`schemas/review-result.schema.json`](../schemas/review-result.schema.json). Values outside the list are ignored for that persona. A finding whose category is outside the list fails schema validation, so the review fails.
- `failure_severity` sets the severity of the `sub-agent-failure` finding the agent records when the persona fails to return findings. It decides how much a failed persona run counts in the verdict.
- A dimension persona's `failure_severity` is used only when it is `medium`, `high` or `critical`. Any other value records the failure at `info`, so a failed run of that persona does not hold back the verdict.
- If your runtime cannot register a persona (for example, its model is not served), the agent still runs it as a generic sub-agent with the persona's prompt, on the agent's default model. Your persona still reviews the diff, but not on the model it asked for.
- If another persona reports the same issue on the same line, the findings are merged and keep the higher-severity persona's `dimension`. This way one problem shows up as one finding.
- Keep `correctness` staged. Without it, the review fails with reason `missing-context`, because correctness is the one area every review needs.
- Do not disable `risk-assessment` this way. Without it, every verdict becomes a comment, so bot approvals stop. To turn the risk assessment off, set `REVIEW_RISK_ASSESSMENT_ENABLED` (see [Variables](#variables)).
- Findings from a persona that was not staged are removed after the run, except high and critical findings, which are always kept. This stops a stray persona from adding noise, but never hides a serious problem.
- Disabling a persona mid-PR does not clear its open high findings; re-enable it for one review round to let it verify the fix, or push the fix before disabling.

The runner fixes the persona list for each run from your trusted base configuration. The PR under review cannot change it.

#### What you will see

The output below comes from a real run on a test pull request that added a ClusterRole. The run used the `rbac-review` persona above.

When the runner applies your overlay, the job log shows this line. It means your override lines were applied to the stock skill. The long cache path is shortened to `…` here.

```text
harness: skill ".fullsend/skills/pr-review" has no SKILL.md; applying its file overrides to base skill "…/pr-review"
```

The runner then writes a persona manifest and puts its path in `FULLSEND_PERSONAS_FILE`. The real file lists every staged persona. This excerpt shows only yours:

```json
{
  "version": 1,
  "personas": [
    {
      "name": "rbac-review",
      "skill": "pr-review",
      "path": "sub-agents/rbac-review.md",
      "origin": "added",
      "sha256": "28cfe8274887cf6af8260579578d2c6e68b458f3cc782ed8552985c49abe7e49",
      "description": "Reviews Kubernetes RBAC manifests for over-broad grants.",
      "role": "dimension",
      "when": "The diff adds or changes a Kubernetes RBAC manifest (Role, ClusterRole, RoleBinding or ClusterRoleBinding), or YAML with `rules:` holding `verbs:`.",
      "categories": ["rbac-violation", "privilege-escalation"],
      "failure_severity": "medium"
    }
  ],
  "removed": []
}
```

`origin` tells you where a persona came from. It is `upstream` for a stock persona, `override` for one you replaced, and `added` for one you added.

After a run with the [Disable a persona](#disable-a-persona) example, `removed` lists the persona you turned off:

```json
"removed": [{"skill": "pr-review", "path": "sub-agents/user-experience.md"}]
```

Each finding in the review result names the persona that produced it in `dimension`. This finding is from the final review result of the run:

```json
{
  "severity": "critical",
  "category": "rbac-violation",
  "file": "deploy/rbac.yaml",
  "line": 8,
  "dimension": "rbac-review",
  "actionable": true,
  "description": "The rule on `configmaps` and `secrets` uses the wildcard verb `*` and is granted cluster-wide. ...",
  "remediation": "Replace the ClusterRole/ClusterRoleBinding with a Role/RoleBinding in the `reports` namespace. ..."
}
```

See [Rules](#rules) for how `dimension` is set when two personas report the same issue.

After the disable example run, the job log showed this warning. It appears only when a finding came from a persona you removed. The log uses the word dimension for a persona. High and critical findings are never dropped.

```text
::warning::Dropped 1 finding(s) from dimensions the runner did not stage: user-experience (1)
```

#### If it goes wrong

| You see | Cause | Fix |
|---|---|---|
| `::warning::Persona manifest is not a valid version 1 manifest; no findings dropped by dimension` | The manifest the runner wrote lists no personas, is not valid JSON, is not version 1, or has a `personas[]` entry with no `name`. | If it lists no personas, nothing is wrong: the agent reads the skill's own persona files instead. Otherwise, check your fullsend version. Until it is fixed, no findings are removed. |
| `::warning::Dropped <n> finding(s) from dimensions the runner did not stage: <persona> (<n>)` | The review produced findings for a persona you did not stage. | Nothing, if you disabled that persona on purpose. Otherwise, check that the persona's override line is in `.fullsend/review.yaml`. |
| `::warning::REVIEW_UX_ENABLED is no longer read; to turn off the UX reviewer, remove sub-agents/user-experience.md with a skills override (see docs/review.md)` | Your harness still sets `REVIEW_UX_ENABLED`. | Delete the variable. To turn off the UX reviewer, use the override in [Disable a persona](#disable-a-persona). |
| A line starting with `::error::Review result reported action=failure (reason: missing-context)` | The `correctness` persona is not staged. | Remove the override that disables or removes `sub-agents/correctness.md`. |
| Your custom persona never runs, and no finding carries its `dimension`. | `name` does not match the file name, `role: dimension` is missing, or `when` does not match the diff. | Fix `name` and `role`. Make `when` describe the change in the PR, or set `always: true`. |
| Your overrides have no effect, and the log has no `applying its file overrides` line. | `.fullsend/config.yaml` does not register `review.yaml`, or the skill key under `skills:` is not `skills/pr-review`. | Add the `agents:` entry from [Before you start](#before-you-start). Use the skill key exactly as shown. |
| `FAIL: schema validation error:` naming your category, with `at:` ending in `category` | Your persona used a category outside the closed list. | Use only categories from [`schemas/review-result.schema.json`](../schemas/review-result.schema.json) in `categories` and in the persona body. |

### Variables

| Variable | Description | Default | Valid values |
|----------|-------------|---------|--------------|
| `FULLSEND_FORGE` | Forge platform. Set automatically by the harness `forge.<platform>.env` section. | (set by harness) | `"github"`, `"gitlab"` |
| `FULLSEND_APP_SET` | GitHub App identity prefix used by the host pre-script to recognize the configured `<prefix>-review[bot]` author when verifying finding-id stamps in resolved threads. The workflow maps the repository variable explicitly; when unset, the organization-specific and shared review-bot identities remain recognized. This identifies the trusted bot record but does not replace resolver-role verification. | _(unset)_ | A configured GitHub App set prefix |
| `REVIEW_FINDING_SEVERITY_THRESHOLD` | Minimum severity for findings to include in the review. Findings below this level are filtered out at two independent stages (agent output and post-review processing) as defense-in-depth. Default is set in `harness/review.yaml` (`env.runner` and `env.sandbox`). | `low` | `info`, `low`, `medium`, `high`, `critical` |
| `FULLSEND_PERSONAS_FILE` | Path to the persona manifest the fullsend runner writes after staging skills, in the sandbox and on the host. Set by the runner, not configured by users. The skill uses the entries whose `skill` is its own directory name. When the manifest is unset, missing (an older runner), or has no such entries, the skill reads the roster from persona frontmatter. When it is unset, missing, or lists no personas, post-review drops nothing. See [Add, replace or disable a review persona](#add-replace-or-disable-a-review-persona). | _(set by runner)_ | A file path |
| `REVIEW_SKIP_AUTHORS` | Comma-separated list of forge usernames to skip review for. When a PR/MR is opened by a user in this list, the review dispatch exits early without running the agent. Set in `env.runner` in your harness YAML (consumed by the pre-script on the runner). | _(empty — all PRs/MRs are reviewed)_ | Comma-separated logins, e.g. `app/renovate,app/dependabot` |
| `REVIEW_PROTECTED_PATHS` | Comma-separated list of path prefixes the review agent treats as protected. PRs that modify files under these paths cannot be approved by the agent — only a human can grant approval. Default is set in `harness/review.yaml` (`env.runner` and `env.sandbox`); an unset value is a misconfiguration (fail-closed). Set to an empty string to deliberately disable protected-path enforcement entirely. When set to a value that parses to no valid paths (e.g. stray or consecutive commas), the script aborts (fail-closed) as a likely misconfiguration. | See [`harness/review.yaml`](https://github.com/fullsend-ai/agents/blob/main/harness/review.yaml) | Comma-separated path prefixes (e.g. `.github/,deploy/,manifests/`) |
| `REVIEW_RISK_ASSESSMENT_ENABLED` | Enables the risk assessment (GitHub only). When `true`, the orchestrator dispatches a risk-assessment sub-agent alongside the review dimensions. The sub-agent computes a composite 1–5 risk score from metadata signals, git history, and linked issue context. The post-script applies a `risk/*` label, posts a sticky risk comment, and gates the review verdict when the score is at or above `REVIEW_RISK_VERDICT_THRESHOLD`. Set in `forge.github.env` in the harness — not in the top-level `env:` block, since the risk assessment scripts depend on the GitHub API and produce fabricated scores on other forges. | `true` (GitHub) | `"true"`, `"false"` |
| `REVIEW_RISK_VERDICT_THRESHOLD` | Risk score threshold at or above which the review verdict is downgraded from `approve` to `comment`. Only active when `REVIEW_RISK_ASSESSMENT_ENABLED` is `true`. Scores ≥ threshold, missing scores, and degraded assessments all trigger the downgrade (fail-closed). Set in `forge.github.env` in the harness. Set to `6` to disable verdict gating (retains `risk/*` label and comment while keeping informational-only scoring). | `4` | Integer `1`–`6` |
| `REVIEW_GIT_FETCH_DEPTH` | Controls clone deepening for git history analysis (risk assessment Tier 2). When set to `"0"`, the pre-script unshallows the target repo clone so the risk-assessment sub-agent can access full commit history. When unset and `REVIEW_RISK_ASSESSMENT_ENABLED` is `true`, defaults to `"0"` automatically — the Tier 2 sub-agent requires full git history. Set explicitly to any other value (e.g., `"1"`) to disable deepening even with risk assessment enabled (opts out of deepening). Not forwarded to the sandbox, so the post-script re-checks the checkout: a clone still shallow after a failed deepen is a degraded risk assessment and withholds auto-approval. Set in `env.runner` in harness YAML (consumed by the pre-script on the runner). | _(auto: `"0"` when risk assessment enabled, no deepening otherwise)_ | `"0"` to fully unshallow |
| `TIMEOUT_SECONDS` | Mirror of the harness `timeout_minutes`, in seconds, read by the `pr-review` skill to skip the challenger pass and write a result before the deadline (see [Time budget](#time-budget)). Set in `env.sandbox`; change it together with `timeout_minutes`. | `2700` | Seconds, equal to `timeout_minutes × 60` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Fleet-wide base pin for the `sonnet` alias on the Claude Code runtime, exported by [`env/gcp-vertex.env`](../env/gcp-vertex.env) (mounted by every harness). Claude Code resolves the alias itself — for the main model, the Agent tool's `model:` argument and sub-agent frontmatter — and a pinned alias is used as written with no startup fallback. Override it when your Vertex project does not serve the pinned id. With `opus` unpinned, a run that reaches the CLI with no `--model` defaults to this id; every harness here sets `model:`. | `claude-sonnet-4-6` | A Claude model id your Vertex project serves, set via `env.sandbox` in a `base:` overlay |

Override any variable by extending the harness file via a `base` reference and setting `env.runner` / `env.sandbox` in your custom harness YAML. `base` composition merges `env.runner`/`env.sandbox` per-key — child values override, everything else inherits from the base (ADR 0045, ADR 0055). Per ADR 0080 and ADR 0081, this harness-level override is the correct path; the CI workflow `env:` block is reserved for infrastructure plumbing, not agent behavior knobs like these.

When severity filtering removes all findings from a negative review verdict, the
verdict is downgraded to a comment (applying the `requires-manual-review` label).
The severity threshold is absolute — it applies to all findings regardless of
the `actionable` flag, respecting the user's configured threshold throughout.

Whenever severity filtering drops findings, post-review appends a notice to the
review body naming the configured threshold and the number of findings that were
not posted, so a filtered review is not mistaken for a clean pass. The count
comes from the same filter that drops the findings, so it always matches what
was posted. A review with nothing filtered is left unchanged.

On a verified re-review with a prior findings ledger, newly reported
`info`/`low` findings do not block the review or start a fix run. They may
remain visible in the posted review. Prior high/critical findings always
remain blocking, regardless of the configured posting threshold. A prior
medium finding blocks when it was explicitly marked actionable, or when its
actionable state is absent and the prior review was `request-changes`; an
explicitly non-actionable medium remains advisory. A legacy projection with
unknown prior action is held for a human and is not promoted into an
automatic fix loop. Carried actionable findings at or above the configured
threshold remain blocking. A prior `reject` verdict is also held for human
review and is never automatically promoted. This does not change the global
severity threshold or treat a missing finding as resolved.

### GitLab host validation

`gitlab-review-ops.lib.sh` validates `GITLAB_HOST` against `CI_SERVER_HOST`,
a GitLab CI predefined variable set automatically by the runner. Validation
fails closed when `CI_SERVER_HOST` is not set.

## How the agent works

The review agent follows the same pre-script / sandbox / post-script pipeline as the other agents.

1. **Pre-script** validates inputs and fetches PR metadata. On a re-review, it also fetches current review-thread state, applies verified human dismissals to the prior-finding ledger, and discards the raw thread content before sandbox creation.
2. **Sandbox** — the agent runs the `pr-review` orchestrator skill. The orchestrator runs a security-triage pre-pass for large PRs, then dispatches the specialized dimension sub-agents in parallel (plus the risk-assessment sub-agent when enabled), each covering a distinct review dimension (correctness, security, intent & coherence, style & conventions, docs currency, user experience, and optionally cross-repo contracts — whichever personas are staged; see [Add, replace or disable a review persona](#add-replace-or-disable-a-review-persona)). Sub-agents run concurrently and return structured findings. The orchestrator collects, deduplicates, and synthesizes findings across dimensions, runs PR-level checks (scope authorization, protected paths), and produces a structured JSON review result. The agent cannot push files, edit code, or push — it is strictly read-only.
3. **Validation loop** — the output is checked against a schema. The review harness runs a single iteration (see [Time budget](#time-budget)), so a failed validation is not retried and the review is lost. Contract change: `finding.category` in `schemas/review-result.schema.json` is a closed enum (the dimension categories in `pr-review` `references/re-review.md` plus `protected-path`, `provenance-warning`, `scope-authorization-implicit`, `sub-agent-failure`), no longer any non-empty string. Anything that produces review results must emit only these categories. The `pr-review` orchestrator remaps stray dimensional categories in step 6b to limit this risk.
4. **Post-script** posts the review on the PR. On GitHub, it also resolves still-open review threads whose only comments are outdated inline comments authored by the review agent, so stale comments do not remain in the PR's unresolved-review state.

On re-review, the sandbox receives a validated `fullsend:review-findings-v2` projection containing `action`, severity, category, file, optional line, id, optional `actionable`, and an `{id, status}` disposition per prior id—not prior descriptions, remediation text, rationales, evidence, or review-thread bodies. Immediately before sandbox creation, the host fetches current thread state and marks eligible findings dismissed only when a verified write-or-higher human other than the PR author resolved a thread containing a trusted review-bot comment with the exact finding-id stamp. Unstamped thread comments stay open; path and line are not used as a fallback. A legacy marker without ids is assigned one before sandbox ingress. Resolved and human-dismissed findings stay in the projection with their anchor so they are recognised and not raised again. A null file retains PR-level category context without serving as a path or severity anchor. The pre-script continues to accept v1 markers for existing comments. Only GitHub `app-verified` re-reviews use file-backed records for remediation-candidate matching.

## Time budget

The runner gives the sandbox `timeout_minutes` (45 in
[`harness/review.yaml`](https://github.com/fullsend-ai/agents/blob/main/harness/review.yaml)) and kills it at the
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

Supported runtimes: **claude** (stable default), **pi** (experimental). On pi, each sub-agent runs with its own model, see [Fullsend pi docs](https://fullsend.sh/docs/runtimes/pi) on how to define a different model for a sub-agent.

**Codex** is not a supported runtime for review yet. The `pr-review` skill dispatches native Codex children only when the runtime note lists registered sub-agent roles, which depends on [fullsend #6970](https://github.com/fullsend-ai/fullsend/issues/6970); this section changes after a live review run on Codex is linked here. The skill passes no `model`: the runner binds each child's model from `agents[].subagents`, or its run-level default.

Effort: `high` (explicit in the harness; override per run with `fullsend run --effort` or `FULLSEND_EFFORT`, values `low`–`max`).

## Source

[`harness/review.yaml`](https://github.com/fullsend-ai/agents/blob/main/harness/review.yaml)
