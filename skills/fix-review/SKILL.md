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

At steps 1, 2, 4, 7a, 7b, 7c, and 8: `echo "::notice::STEP <N>: <title>"`

## Time budget

If the `TIMEOUT_SECONDS` environment variable is set, use it to manage time.

Capture the start time at the very beginning:

```bash
AGENT_START=$(date +%s)
```

Before starting pre-commit (7b), before the direct-execution fallback
inside 7b, before each retry iteration (7c), and before commit (8),
check remaining time **only if `TIMEOUT_SECONDS` is set**:

```bash
if test -n "${TIMEOUT_SECONDS:-}"; then
  NOW=$(date +%s)
  ELAPSED=$((NOW - AGENT_START))
  REMAINING=$((TIMEOUT_SECONDS - ELAPSED))
  echo "::notice::Time check: ${ELAPSED}s elapsed, ${REMAINING}s remaining"
fi
```

Thresholds (fractions of budget, except the fallback floor, which is
a flat 300s — what it guards costs the same whatever the budget is):
- **Before 7b (pre-commit):** < 10% remaining → skip pre-commit
- **Before the direct-execution fallback in 7b:** < 300s remaining →
  skip the fallback (its `pip install` steps risk a hard timeout),
  proceed to 7c and disclose the skip in the commit message
- **Before retry in 7c:** < 20% remaining → commit with disclosure
- **Before 8 (commit):** < 8% remaining → skip gitlint validation

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

If `PR_NUMBER` is not set, stop.

Fetch the PR metadata using the forge-specific commands from your forge skill
(e.g., `gh pr view` on GitHub, `curl` on GitLab).

If the PR is closed or merged, stop.

### 2. Gather review feedback

```bash
echo "::notice::STEP 2: Gather review feedback"
```

First, fetch the current PR diff so you know exactly what code is on the branch.
Use the forge-specific commands from your forge skill (e.g., `gh pr diff` on
GitHub, `curl` to fetch MR changes on GitLab).

**If trigger type is `"bot"` (bot-triggered):**

**Step 2a — Read the pre-fetched review body:**

The workflow pre-fetches the review body to `/sandbox/workspace/review-body.txt`. Read it:

```bash
REVIEW_BODY_FILE="/sandbox/workspace/review-body.txt"
[ -s "${REVIEW_BODY_FILE}" ] || echo "::error::No review body found"
cat "${REVIEW_BODY_FILE}"
```

Use this pre-fetched file as the review source. Do not re-fetch the review through
the forge API; the sandbox token may not have permission to read review details.

**Step 2b — Understand the review before acting:**

Read the entire review carefully. Identify: (1) the reviewer's overall concern, (2) individual findings with file/line references, (3) whether findings share a root cause.

**Step 2c — Build your action list:**

For each finding, record: `finding`, `path`, `description`, `related_findings`. Ignore `<details>` blocks (prior iterations). Inline PR comments are not used; humans direct fixes via `/fs-fix`.

**If trigger type is `"human"`:** Use `HUMAN_INSTRUCTION` as primary directive. If vague, infer conservatively from PR diff.

### 3. Discover repo conventions

Read `CLAUDE.md`, `CONTRIBUTING.md`, `AGENTS.md`. Discover test/lint commands from `Makefile`, `package.json`, linter configs. Determine test command, lint command, commit conventions.

### 4. Plan fixes

```bash
echo "::notice::STEP 4: Plan fixes"
```

Start from the whole-review theme, not individual findings. Plan a single coherent fix for related findings; individual fixes for standalone findings. For each, determine: (1) Is feedback valid? (2) What's the minimal fix? (3) Should I disagree?

**Strategy escalation:** If `FIX_ITERATION` > `STRATEGY_ESCALATION_THRESHOLD` (default: 3), read commit history (`git log --oneline "${BASE_BRANCH}..HEAD"` — use the local `${BASE_BRANCH}` ref, not `origin/${BASE_BRANCH}`; sandbox network policy may block git protocol access), try a fundamentally different approach, and note the change in structured output.

### 5. Read affected code

Read full files (not just reviewed lines), related test files, and affected imports/types/call sites.

### 6. Implement fixes

For each finding (top-down in file): make the change, follow existing patterns, avoid new dependencies unless requested, update tests if needed. **Scope guardrail:** Only address review feedback—no unmentioned refactors, features, bug fixes, or doc improvements.

### 7. Verify

**7a. Secret scan — MANDATORY FIRST STEP**

```bash
echo "::notice::STEP 7a: Secret scan"
```

```bash
scan-secrets <files-you-modified>
```

If secrets are detected: hard stop. Remove them, re-scan.

**7b. Pre-commit hooks — run them, do not skip them**

```bash
echo "::notice::STEP 7b: Pre-commit hooks"
```

Same rules as the code agent (see step 9b of the code-implementation
skill for the full text):
- Maximum 2 pre-commit/hook-execution runs per validation-loop
  iteration (not per sandbox). A `pre-commit run` that failed on
  infrastructure before executing any hook does not count — the
  direct-execution fallback takes its place. A validation-loop retry
  is a new iteration with a fresh budget; 7c's own retries do not
  reopen 7b.
- Pre-format your code before running pre-commit.
- If `pre-commit` itself cannot run — typically because it cannot
  fetch remote hook repositories — do not skip verification, unless
  the fallback floor below says you cannot afford it. Otherwise fall
  back to running the configured hooks directly, honoring each hook's
  `entry`, `args`, `rev`, `stages`, `additional_dependencies`, and
  file filters.
- If the second run still fails, log the exact hook, file, and error
  in the commit message and move on. Never claim hooks passed when
  they did not.

```bash
test -f .pre-commit-config.yaml && pre-commit run --files <all-changed-files>
```

**Time recheck before the fallback.** Run this **only** when the
`pre-commit run` above failed on infrastructure (could not fetch hook
repositories, or died before executing any hook) — not after a pass,
not after real hook errors. The 10% gate measured the fast path; the
fallback `pip install`s each hook at its pinned `rev` and can outrun a
thin margin, timing out with no commit at all. Re-check against a flat
300s floor (absolute, because the cost does not scale with the budget):

```bash
RUN_FALLBACK=1
if test -n "${TIMEOUT_SECONDS:-}" && test -n "${AGENT_START:-}"; then
  NOW=$(date +%s)
  REMAINING=$((TIMEOUT_SECONDS - (NOW - AGENT_START)))
  if test "$REMAINING" -lt 300; then
    RUN_FALLBACK=0; echo "::warning::Direct-execution fallback skipped: ${REMAINING}s remaining < 300s floor"
  else
    echo "::notice::Fallback time check: ${REMAINING}s remaining >= 300s floor — proceeding"
  fi
else
  echo "::notice::Fallback time check skipped: TIMEOUT_SECONDS or AGENT_START unset — no floor applied"
fi
```

Guard both variables (an unset `AGENT_START` reads as 0 and would
always skip) and print on every path.

If `RUN_FALLBACK` is `0`: skip the fallback — `repo: local` hooks
included, since a local `entry` can fetch too and 7c's lint still runs —
treat 7b as finished, and put this in the commit message:

> Note: pre-commit hooks were not run. `pre-commit` could not
> complete (infrastructure failure), and the remaining time budget
> was below the floor for running the hooks directly.

Skipping consumes no run but closes 7b for this iteration.

If `1`, run the fallback as described above.

**7c. Tests and linters — MANDATORY**

```bash
echo "::notice::STEP 7c: Tests and linters"
```

Discover build/test commands: Read Makefile, package.json, pyproject.toml, or equivalent. Run test command (e.g., `make test`, `npm test`, `go test ./...`, `pytest`), then lint command (e.g., `make lint`, `golangci-lint run`, `eslint`, `ruff`) as separate invocations (not `&&`-chained; lint runs even if tests fail).

If tests fail: read output, fix, re-run secret scan (7a) then tests (7c). Don't re-run pre-commit — 7b is closed for this iteration whether you spent the budget or skipped it. Retry limit: `MAX_RETRIES` (default: 1).

**7d. Self-review**

Run `git diff`. Check for: unrelated changes, debug prints/TODOs, secrets, protected paths.

### 8. Commit

```bash
echo "::notice::STEP 8: Commit"
```

**8a. Stage files**

`git add` only files you modified.

**8b. Scan staged content**

```bash
git diff --cached --stat
scan-secrets --staged
```

**NEVER use `git commit -s` or `Signed-off-by`.** DCO is for humans; bot commits are exempt.

**8c. Commit**

Follow repo conventions. Reference PR number. Note disagreements.

```bash
git commit -m "fix: address review feedback on PR #${PR_NUMBER}

<summary>

Addresses #${PR_NUMBER}"
which gitlint &>/dev/null && gitlint --commit HEAD
```

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
  "files_changed": ["src/input.sh"]
}
```

**Schema:** `additionalProperties: false`. Use only shown fields. `trigger_source` is `"bot"` or `"human"` (normalized, not raw username). Action types: `fix` (required: `type`, `finding`, `description`) or `disagree` (required: `type`, `finding`, `reason`). Top-level required: `pr_number`, `trigger_source`, `actions`, `summary`, `tests_passed`, `files_changed`. Actions array must have ≥1 item.

Validate: `fullsend-check-output "${FULLSEND_OUTPUT_DIR}/agent-result.json"`. If fails after 3 attempts, write best JSON and exit.

## Partial work

If token limit reached: commit partial work, document addressed/remaining findings in structured output.

## Constraints

`agents/fix.md` is authoritative for prohibitions. On conflict, agent definition wins.
