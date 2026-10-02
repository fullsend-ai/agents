---
name: fix-review
description: >-
  Use when implementing fixes for review comments left on an open PR.
  Step-by-step procedure for addressing review feedback on an existing PR.
  Reads review comments, plans targeted fixes, implements, verifies with
  tests and linters, commits, and produces structured output for the
  post-script.
---

# Fix Review

A thorough fix reads every review comment, understands the reviewer's intent,
verifies the feedback against the actual code, and makes the smallest correct
change for each item. Jumping straight to edits without understanding context
produces fixes that introduce new issues or miss the reviewer's point.

## Tools reminder

Use `Bash` for verification and committing. Use `Read`/`Write`/`Grep`/`Glob` for file operations. The `scan-secrets` helper is at `/usr/local/bin/scan-secrets` — verify with `command -v scan-secrets`. If missing, **STOP**.

## Progress markers

At steps 1, 2, and 4: `echo "::notice::STEP <N>: <title>"`. The
`fix-verification` skill emits its own markers for steps 7a, 7b, 7c,
and 8.

## Time budget

If `TIMEOUT_SECONDS` is set, capture `AGENT_START=$(date +%s)` at the
very beginning — the `fix-verification` skill's time checks in steps 7
and 8 depend on it. See that skill for the exact commands and
per-step thresholds.

## Process

Follow these steps in order. Do not skip steps.

### 1. Identify the PR and trigger

```bash
echo "::notice::STEP 1: Identify PR and trigger"
```

Read the environment:

```bash
echo "PR_NUMBER=${PR_NUMBER}"
echo "TRIGGER_SOURCE=${TRIGGER_SOURCE}"
echo "FIX_ITERATION=${FIX_ITERATION:-1}"
echo "FIX_CONFLICT_UPDATE_STRATEGY=${FIX_CONFLICT_UPDATE_STRATEGY:-merge}"
```

- `PR_NUMBER` — which PR to fix (required)
- `TRIGGER_SOURCE` — forge username that triggered the fix (e.g.,
  `"orgname-review[bot]"` on GitHub, `"project_123_bot"` on GitLab,
  or `"alice"`). **This is a username, not the value you write to
  `agent-result.json`.** Derive the normalized trigger type now — you
  will need it in step 9:
  - On GitHub (`FULLSEND_FORGE=github`): if `TRIGGER_SOURCE` ends in `[bot]` → trigger type is `"bot"`
  - On GitLab (`FULLSEND_FORGE=gitlab`): if `TRIGGER_SOURCE` ends in `_bot` → trigger type is `"bot"`
  - Otherwise → trigger type is `"human"`
- `HUMAN_INSTRUCTION` — the human's instruction text (only when
  trigger type is `"human"`)
- `FIX_ITERATION` — which iteration of the review→fix loop this is
- `FIX_CONFLICT_UPDATE_STRATEGY` — `merge` (default) or `rebase` (agents/fix.md)

If `PR_NUMBER` is not set, stop.

Fetch the PR metadata via your forge skill (e.g., `gh pr view` on GitHub,
`curl` on GitLab). Reconcile a real conflict per agents/fix.md.

If the PR is closed or merged, stop.

### 2. Gather review feedback

```bash
echo "::notice::STEP 2: Gather review feedback"
```

First, fetch the current PR diff so you know exactly what code is on the branch.
Use the forge-specific commands from your forge skill (e.g., `gh pr diff` on
GitHub, `curl` to fetch MR changes on GitLab). Also inspect the PR's project
CI using the `fix-ci-inspection` skill (forge-specific recipes remain in this
skill's github/gitlab siblings).

**If trigger type is `"bot"` (bot-triggered):**

**Step 2a — Read the pre-fetched review body:**

Read `/sandbox/workspace/review-body.txt`:

```bash
REVIEW_BODY_FILE="/sandbox/workspace/review-body.txt"
grep -q '[^[:space:]]' "${REVIEW_BODY_FILE}" || echo "::warning::Empty review body, recovering"
cat "${REVIEW_BODY_FILE}"
```

If empty, pointer-only, or under 200 bytes, recover via your forge
skill's Review findings fallback. Do not re-fetch PR reviews. If still
unusable, log error or disagree.

**Step 2b — Understand the review before acting:**

Read the entire review carefully. Identify: (1) the reviewer's overall concern, (2) individual findings with file/line references, (3) whether findings share a root cause.

**Step 2c — Build your action list:**

For each finding, record: `finding`, `path`, `description`, `related_findings`. Ignore `<details>` blocks (prior iterations). Inline PR comments are not used; humans direct fixes via `/fs-fix`.

**If trigger type is `"human"`:** Use `HUMAN_INSTRUCTION` as primary directive. If empty or vague, also follow step 2a.

### 3. Discover repo conventions

Read `CLAUDE.md`, `CONTRIBUTING.md`, `AGENTS.md`. Discover test/lint commands from `Makefile`, `package.json`, linter configs. Determine test command, lint command, commit conventions.

### 4. Plan fixes

```bash
echo "::notice::STEP 4: Plan fixes"
```

Start from the whole-review theme. One coherent fix for related findings; individual fixes otherwise. For each: valid? minimal fix? disagree? Merge-commit secret-scan: apply [references/merge-commit-secret-scan.md](references/merge-commit-secret-scan.md).

**Strategy escalation:** If `FIX_ITERATION` > `STRATEGY_ESCALATION_THRESHOLD` (default: 3), read commit history (`git log --oneline "${BASE_BRANCH}..HEAD"` — use the local `${BASE_BRANCH}` ref, not `origin/${BASE_BRANCH}`; sandbox network policy may block git protocol access), try a fundamentally different approach, and note the change in structured output.

### 5. Read affected code

Read full files (not just reviewed lines), related test files, and affected imports/types/call sites.

### 6. Implement fixes

For each finding (top-down in file): make the change, follow existing patterns, avoid new dependencies unless requested, update tests if needed. **Scope guardrail:** Only address review feedback and `pr-related` project-CI failures within authorized scope (see the `fix-ci-inspection` skill). No unmentioned refactors, features, bug fixes, or doc improvements.

### 7. Verify

Follow the `fix-verification` skill: mandatory secret scanning (7a),
pre-commit hooks with the infrastructure fallback (7b), tests and
linters with the retry limit (7c), and self-review (7d).

### 8. Commit

Follow the `fix-verification` skill: stage only the files you
modified, scan the staged content, then commit following repo
conventions, referencing the PR number and noting any disagreements.

### 9. Produce structured output

**MANDATORY.** Write `$FULLSEND_OUTPUT_DIR/agent-result.json`:

```json
{
  "pr_number": 42,
  "trigger_source": "bot",
  "iteration": 1,
  "actions": [
    {"type": "fix", "finding": "Missing input validation", "path": "src/input.sh", "description": "Reject empty input before processing"},
    {"type": "disagree", "finding": "Rename the public command", "path": "src/cli.sh", "reason": "The existing name is part of the documented public interface"}
  ],
  "decision_points": [{"description": "Preserve the public command name", "alternatives": ["Rename the command", "Keep the documented name"], "rationale": "Renaming would break existing callers"}],
  "summary": "Addressed both review findings",
  "strategy_change": null,
  "tests_passed": true,
  "files_changed": ["src/input.sh"],
  "ci_inspections": [
    {"job": "lint", "status": "success", "classification": "passing", "diagnosis": "Lint passed."},
    {"job": "unit-tests", "status": "failure", "classification": "pr-related", "diagnosis": "Failing test matches this diff.", "remediation": "Fixed the test."}
  ]
}
```

**Schema:** `additionalProperties: false`. Use only schema-defined fields — e.g. optional `rebased_onto_target` (`fix-history-rewrite` skill) and `ci_inspections` (`fix-ci-inspection` skill; each entry requires `job` and `classification`, with `status`/`diagnosis`/`remediation` optional — see the forge-specific `fix-review` skill for the recipes that gather these). `trigger_source` is `"bot"`/`"human"`. Types: `fix` (needs `type`, `finding`, `description`) or `disagree` (needs `type`, `finding`, `reason`). Required: `pr_number`, `trigger_source`, `actions` (≥1), `summary`, `tests_passed`, `files_changed`.

Validate: `fullsend-check-output "${FULLSEND_OUTPUT_DIR}/agent-result.json"`. If fails after 3 attempts, write best JSON and exit.

## Partial work

If token limit reached: commit partial work, document addressed/remaining findings in structured output.

## Constraints

`agents/fix.md` is authoritative for prohibitions. On conflict, agent definition wins.
