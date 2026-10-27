---
name: fix-verification
description: >-
  Use when verifying and committing a fix-agent change after fixes are
  implemented: mandatory secret scanning, pre-commit hooks with
  infrastructure-fallback behavior, tests and linters, self-review, and
  committing with disclosures. Invoked from the fix-review skill's
  step 7 (Verify) and step 8 (Commit).
---

# Fix Verification

A fix is only as good as its verification. This is the fix agent's
executable procedure for steps 7 and 8 of the `fix-review` skill:
secret scanning, pre-commit hooks (with a bounded fallback when
pre-commit itself cannot run), tests and linters, self-review, and
committing with full disclosure of anything that did not pass. Jumping
straight to a commit without running this sequence risks shipping
secrets, unformatted code, or a regression the reviewer will just send
back.

## Tools reminder

Use `Bash` for verification and committing. Use `Read`/`Write`/`Grep`/`Glob` for file operations. The `scan-secrets` helper is at `/usr/local/bin/scan-secrets` — verify with `command -v scan-secrets`. If missing, **STOP**.

## Progress markers

At steps 7a, 7b, 7c, and 8: `echo "::notice::STEP <N>: <title>"`

## Time budget

If `TIMEOUT_SECONDS` is set, capture `AGENT_START=$(date +%s)` at the
very beginning of the fix run (the `fix-review` skill's step 1 is the
usual place) — these time checks depend on it. Then check remaining
time before 7b, before 7b's direct-execution fallback, before each 7c
retry, and before 8 — skip the check when `TIMEOUT_SECONDS` is unset.
Exact commands and the per-step thresholds (10% before 7b, a flat 300s
floor before the 7b fallback, 20% before a 7c retry, 8% before 8): see
[references/timing.md](references/timing.md).

## Process

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
not after real hook errors. Re-check remaining time against a flat
300s floor; see [references/timing.md](references/timing.md) for the
exact commands. If below the floor, skip the fallback — `repo: local`
hooks included, since a local `entry` can fetch too and 7c's lint
still runs — treat 7b as finished, and put this in the commit message:

> Note: pre-commit hooks were not run. `pre-commit` could not
> complete (infrastructure failure), and the remaining time budget
> was below the floor for running the hooks directly.

Skipping consumes no run but closes 7b for this iteration. Otherwise,
run the fallback as described above.

**7c. Tests and linters — MANDATORY**

```bash
echo "::notice::STEP 7c: Tests and linters"
```

You MUST run both **tests** and **linters** using the exact commands
from the `fix-review` skill's step 3 (package manager included). Do not
substitute `npx lint-staged` for `pnpm lint-staged`. Run them separately
(not `&&`-chained; lint runs even if tests fail).

Linting is separate from pre-commit (7b). If the command reads the git
index (`lint-staged`, or docs say to stage first), `git add` intended
files with explicit paths (never `git add -A` / `.` / `--all`) then
run it. Do not substitute a full-tree lint (`pnpm lint:fix`).
Otherwise run it now and stage in 8a.

If tests or linters fail: read output, fix, re-run secret scan (7a) then 7c. Don't re-run pre-commit — 7b is closed for this iteration whether you spent the budget or skipped it. Retry limit: `MAX_RETRIES` (default: 1).

**7d. Self-review**

Review `git diff` and `git diff --cached`. Check for: unrelated changes, debug prints/TODOs, secrets, protected paths. Revert extras.

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

## Partial work

If token limit reached: commit partial work, document addressed/remaining findings in structured output (see the `fix-review` skill's step 9).

## Constraints

`agents/fix.md` is authoritative for prohibitions. On conflict, agent definition wins.
