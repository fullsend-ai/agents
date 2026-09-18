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

Use `Bash` for verification (step 7) and committing (step 8).

- `git add <file>`, `git diff`, `git commit`
- Forge API commands from your forge skill (`gh` or `curl`)
- The **exact** test/lint command from step 3 (package manager included).
  Do not substitute `npx` for `pnpm` or a full-tree lint for
  `pnpm lint-staged`.
- `pre-commit run --files <files>` — not a substitute for the repo lint

Use `Read`/`Write`/`Grep`/`Glob` for file operations. Verify
`command -v scan-secrets` before step 7; if missing, **STOP**.
Modes: `scan-secrets <files>` (7a), `--staged` (8b).

## Progress markers

At steps 1, 2, 3, 4, 7a, 7b, 7c, 8: `echo "::notice::STEP <N>: <title>"`

## Time budget

If `TIMEOUT_SECONDS` is set, use it to manage time.

Capture the start time at the very beginning:

```bash
AGENT_START=$(date +%s)
```

Before starting pre-commit (7b), before the direct-execution fallback
inside 7b, before each retry iteration (7c), and before commit (8),
check remaining time **only if `TIMEOUT_SECONDS` is set**:

```bash
if [ -n "${TIMEOUT_SECONDS:-}" ]; then
  ELAPSED=$(( $(date +%s) - AGENT_START ))
  REMAINING=$(( TIMEOUT_SECONDS - ELAPSED ))
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

```bash
echo "::notice::STEP 3: Discover repo conventions"
```

Use `Read`/`Glob` on `CLAUDE.md`, `CONTRIBUTING.md`, `AGENTS.md`,
`Makefile`, `package.json`, `pyproject.toml`, and linter configs.

**Precedence rule:** When AGENTS.md conflicts with patterns in existing
code, follow AGENTS.md. Follow the documented lint/test command and
order, including stage-then-lint; do not reorder around `git add`.

Determine the exact **test command**, **lint command** (package manager
included, e.g. `pnpm lint-staged`), and **commit conventions**.

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
- Max 2 hook-execution runs per validation-loop iteration. An
  infrastructure failure before any hook runs does not count — the
  direct-execution fallback takes its place. 7c retries do not reopen 7b.
- Pre-format before running pre-commit.
- If `pre-commit` cannot fetch hook repos, run configured hooks
  directly (`entry`, `args`, `rev`, `stages`,
  `additional_dependencies`, file filters), unless the 300s floor
  below says you cannot afford it.
- If the second run fails, log hook/file/error in the commit message.
  Never claim hooks passed when they did not.

```bash
test -f .pre-commit-config.yaml && pre-commit run --files <all-changed-files>
```

**Time recheck before the fallback.** Only when `pre-commit run` failed
on infrastructure. Re-check the 300s floor:

```bash
RUN_FALLBACK=1
if [ -n "${TIMEOUT_SECONDS:-}" ] && [ -n "${AGENT_START:-}" ]; then
  REMAINING=$(( TIMEOUT_SECONDS - ($(date +%s) - AGENT_START) ))
  if [ "$REMAINING" -lt 300 ]; then
    RUN_FALLBACK=0; echo "::warning::Direct-execution fallback skipped: ${REMAINING}s remaining < 300s floor"
  else
    echo "::notice::Fallback time check: ${REMAINING}s remaining >= 300s floor — proceeding"
  fi
else
  echo "::notice::Fallback time check skipped: TIMEOUT_SECONDS or AGENT_START unset — no floor applied"
fi
```

Guard both variables (unset `AGENT_START` reads as 0) and print on
every path. If `0`: skip the fallback (`repo: local` included), close
7b, continue to 7c, and disclose:

> Note: pre-commit hooks were not run. `pre-commit` could not
> complete (infrastructure failure), and the remaining time budget
> was below the floor for running the hooks directly.

If `1`, run the fallback as described above.

**7c. Tests and linters — MANDATORY**

```bash
echo "::notice::STEP 7c: Tests and linters"
```

You MUST run both **tests** and **linters** using the exact step 3
commands. Do not substitute `npx lint-staged` for `pnpm lint-staged`.
Run them separately (not `&&`-chained; lint runs even if tests fail).

Linting is separate from pre-commit (7b). If the command reads the git
index (`lint-staged`, or docs say to stage first), `git add` intended
files with explicit paths (never `git add -A` / `.` / `--all`) then
run it. Do not substitute a full-tree lint (`pnpm lint:fix`).
Otherwise run it now and stage in 8a.

If tests or linters fail: fix, re-run 7a then 7c. Don't re-run
pre-commit. Retry limit: `MAX_RETRIES` (default: 1).

**7d. Self-review**

Review `git diff` and `git diff --cached`. Check for unrelated changes,
debug prints/TODOs, secrets, protected paths. Revert extras.

### 8. Commit

```bash
echo "::notice::STEP 8: Commit"
```

**8a. Stage files**

`git add` only files you modified (explicit paths). If 7c already
staged them, re-add so auto-fixes are included.

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

**Schema:** `additionalProperties: false`. Use only schema-defined fields — e.g. optional `rebased_onto_target` (`agents/fix.md` step 8). `trigger_source` is `"bot"`/`"human"` (normalized). Types: `fix` (needs `type`, `finding`, `description`) or `disagree` (needs `type`, `finding`, `reason`). Required: `pr_number`, `trigger_source`, `actions` (≥1 item), `summary`, `tests_passed`, `files_changed`.

Validate: `fullsend-check-output "${FULLSEND_OUTPUT_DIR}/agent-result.json"`. If fails after 3 attempts, write best JSON and exit.

## Partial work

If token limit reached: commit partial work, document addressed/remaining findings in structured output.

## Constraints

`agents/fix.md` is authoritative for prohibitions. On conflict, agent definition wins.
