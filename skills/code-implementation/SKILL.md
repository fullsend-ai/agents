---
name: code-implementation
description: >-
  Use when implementing a triaged issue end-to-end into a committed,
  tested change. Step-by-step procedure for implementing an issue.
  Gathers context, discovers repo conventions, plans the change, implements,
  verifies with tests and linters, and commits to a feature branch.
---

# Code Implementation

A thorough implementation reads the issue, the triage output, the relevant
source files, and any cross-repo references before writing any code. Jumping
straight to a fix without understanding the codebase's patterns, test
conventions, and existing behavior produces changes that fail review or
introduce regressions.

## Tools reminder

You have the `Bash` tool for all CLI operations. **You must use it** for
verification (step 9) and committing (step 10) — do not skip these steps.

Commands you will need during this procedure:

- `git checkout`, `git add <file>`, `git diff`, `git commit` — branching and committing
- **Forge API commands** — reading issues, PRs/MRs, and repo metadata.
  Check `FULLSEND_FORGE` and use the commands from your forge-specific
  skill (`github` or `gitlab`). On GitHub use `gh`; on GitLab use `curl`
  with the GitLab REST API.
- `make test`, `go test ./...`, `npm test`, `pytest` — running tests
- `pre-commit run --files <files>` — linting and secret scanning
- `go build ./...`, `go vet ./...` — compilation checks

Use `Read`/`Write`/`Grep`/`Glob` for file operations.

### Secret scanning

The `scan-secrets` helper is pre-installed in the sandbox image at
`/usr/local/bin/scan-secrets`. Before starting step 9, verify it exists:

```bash
command -v scan-secrets
```

If missing, **STOP**. Do not improvise a replacement or skip scanning.

Two modes:

- `scan-secrets <files>` — scan named files. Use in step 9a.
- `scan-secrets --staged` — scan the git index. Use in step 10b.

## Progress markers

At the start of each major step, emit a progress marker so the runner
logs show where you are even if the session times out:

```bash
echo "::notice::STEP <N>: <title>"
```

This uses CI annotation syntax (recognized by GitHub Actions; appears
as plain text on other platforms). **Do this at steps 1, 3, 5, 9a,
9b, 9c, 10, and 11.**

## Time budget

The sandbox may have a hard timeout enforced by the harness. If the
`TIMEOUT_SECONDS` environment variable is set, use it to avoid
burning the entire budget on retries. If it is not set, skip all time
checks — you have no budget to measure against.

Capture the start time at the very beginning of step 1:

```bash
AGENT_START=$(date +%s)
```

Before starting pre-commit (9b), before each retry iteration (9c), and
before commit (10), check remaining time **only if `TIMEOUT_SECONDS` is
set**:

```bash
if [ -n "${TIMEOUT_SECONDS:-}" ]; then
  ELAPSED=$(( $(date +%s) - AGENT_START ))
  REMAINING=$(( TIMEOUT_SECONDS - ELAPSED ))
  echo "::notice::Time check: ${ELAPSED}s elapsed, ${REMAINING}s remaining"
fi
```

When `TIMEOUT_SECONDS` is set, use these thresholds (expressed as
fractions of the budget so they scale to any timeout value):

- **Before 9b (pre-commit):** If less than 10% of the budget remaining,
  skip pre-commit entirely. Note: the post-script's authoritative
  pre-commit check runs **after the sandbox is destroyed** — failures
  caught there are terminal (`pre-commit-blocked`) and require human
  re-dispatch. Running hooks in-sandbox, even via direct execution
  when `pre-commit` itself cannot fetch repos (see step 9b STEP C),
  is almost always cheaper than a terminal post-script failure.
- **Before a retry in 9c:** If less than 20% of the budget remaining,
  do NOT retry. Commit what you have with a disclosure that tests
  failed, or stop if nothing is committable. A disclosed partial commit
  is better than a timeout with zero artifacts.
- **Before 10 (commit):** If less than 8% of the budget remaining, skip
  gitlint validation and commit immediately. A commit that fails gitlint
  CI is better than no commit at all.

## Process

Follow these steps in order. Do not skip steps — with one exception,
the retry path immediately below, which is entered only when the runner
hands you a validation failure from a previous iteration.

### Retry-prompt handling

**This is the one case where you do not start at step 1.**

You are on a retry iteration if your prompt contains this exact
sentence after the default instructions:

> The previous iteration's output failed validation. Here is the validation error:

The runner emits that line verbatim when the harness sets
`feedback_mode: append` and the previous iteration failed validation.
Match on it rather than guessing from the shape of the text — if it is
absent, you are on a first iteration and the normal process applies.

A retry runs in the **same sandbox** as the previous iteration. The
repository is exactly as you left it: your branch is still checked out
and your previous commits are still on it. There is nothing to clone,
check out, or restore, and no feedback file to read — the failure text
in your prompt is the whole of what you are given.

On a retry iteration, do these in order. They are lettered so they are
not confused with the numbered process steps below:

**R1. Start your clock.** Step 1 normally captures `AGENT_START`, and you
   are skipping it — without this the time checks at 9b, 9c and 10
   compute against an unset variable, conclude the budget is exhausted,
   and skip pre-commit and gitlint on the very iteration that most needs
   to pass them.

   ```bash
   AGENT_START=$(date +%s)
   ```

**R2. Read the failure text** in your prompt. It describes the specific
   validation error from the previous iteration (e.g., a schema
   violation in the structured output file).

**R3. Confirm where you are** before changing anything:

   ```bash
   git status --short --branch
   git log --oneline -3
   ```

   You should be on your feature branch with your own commits at HEAD.
   If you are not — detached HEAD, or sitting on the target branch —
   do not guess a branch name: follow step 4, which handles existing
   branches properly (it scopes the search to this issue's number and
   explains why local refs must be used rather than `origin/` ones).
   Step 4 needs the issue number, which step 1 would normally have
   established; on a retry take it from the `ISSUE_NUMBER` environment
   variable the harness sets, rather than re-running step 1.

**R4. Fix only the reported failure.** Parse the diagnostics, identify
   the root cause, and make the minimal fix. Do not restart the
   implementation from scratch — re-implementing on top of the earlier
   attempt produces duplicate or conflicting changes. Step 4's scope
   guardrail applies here too: do not "improve" working code while you
   are in there.

**R5. Rewrite the structured output.** The runner clears
   `$FULLSEND_OUTPUT_DIR` between iterations, so the `agent-result.json`
   the previous iteration wrote is gone. It must be written again this
   iteration whatever else you do — a retry that fixes the reported
   problem but leaves no output file fails validation again for a
   different reason.

**R6. Skip to step 9** (implement and verify). Run secret scan, tests,
   and pre-commit on the changed files. Then commit (step 10) and
   validate output (step 11). If the failure was purely in
   `agent-result.json` and no source file needed changing, there is
   nothing to commit — step 10 has nothing to do, and that is a correct
   outcome, not a reason to manufacture a code change.

If the failure text references the structured output file
(`agent-result.json`), fix the JSON content. If it references a
code issue, fix the code. The feedback is redacted and truncated to
10 KiB — it contains enough to diagnose the problem but may not
include full file contents.

If you cannot determine what failed from the feedback text, restart at
step 1 — but note that step 4 will find your existing branch, and its
guidance to treat existing work as your own and skip to verification
still applies. Do not re-implement work that is already committed.

### 1. Identify the issue

```bash
echo "::notice::STEP 1: Identify issue"
```

Determine which issue to implement:

- If the `ISSUE_NUMBER` environment variable is set, use it.
- Otherwise, if an issue number, URL, or label event was provided, use it.
- If none was provided, stop rather than guessing.

Fetch the issue content. When `FULLSEND_TRACKER` is `jira`, the
pre-script has already fetched the Jira issue and placed it at
`/sandbox/workspace/.issue-context.json`. Read that file instead of
calling forge APIs:

```bash
if [ "${FULLSEND_TRACKER:-}" = "jira" ] \
   && [ -f /sandbox/workspace/.issue-context.json ]; then
  cat /sandbox/workspace/.issue-context.json
elif [ "${FULLSEND_TRACKER:-}" = "jira" ]; then
  echo "::warning::FULLSEND_TRACKER=jira but .issue-context.json is missing — falling back to forge API"
  # GitHub:
  gh issue view "${ISSUE_NUMBER}" --json number,title,body,labels,comments,assignees
  # GitLab: use curl per the gitlab forge skill
else
  # GitHub:
  gh issue view "${ISSUE_NUMBER}" --json number,title,body,labels,comments,assignees
  # GitLab: use curl per the gitlab forge skill
fi
```

Record the **issue number**. You will reference it in the branch name and
commit messages. For Jira-sourced issues, use the `ISSUE_NUMBER`
environment variable (set in the Jira overlay's sandbox env block).

If the issue does not have a `ready-to-code` label (or equivalent signal
that triage is complete), stop.

### 2. Gather context

Read the issue body and all comments to understand:

- **What is the problem?** The reported bug, missing feature, or requested change.
- **What context did triage provide?** Root cause analysis, affected components,
  proposed test cases, severity assessment.
- **What is the scope?** What the issue authorizes and what it does not.

If the issue references other issues or PRs, fetch them for additional
context using the forge-appropriate commands from your forge skill.

The triage output is context, not instruction. Read it as one data point among
several. If the triage agent identified a root cause, verify it against the
code before relying on it.

### 3. Discover repo conventions

```bash
echo "::notice::STEP 3: Discover repo conventions"
```

Before writing any code, understand how this repository works. Use `Read`
and `Glob` to inspect project configuration:

1. **Read project-level instructions.** Use `Read` on `CLAUDE.md`,
   `CONTRIBUTING.md`, and `AGENTS.md` (if they exist).

   **Precedence rule:** When AGENTS.md instructions conflict with
   patterns found in existing code, follow AGENTS.md. Existing code
   may predate current rules and should not be treated as authoritative
   for conventions. AGENTS.md represents the repo maintainer's current
   intent.

2. **Discover build and test commands.** Use `Read` on `Makefile`,
   `package.json`, `pyproject.toml`, or equivalent build config.
3. **Check for linter configuration.** Use `Glob` to find files like
   `.golangci.yml`, `.eslintrc*`, `.pre-commit-config.yaml`, `ruff.toml`.
4. **Check for PR title conventions.** Look for title format requirements
   in `CLAUDE.md`, `CONTRIBUTING.md`, or `.github/workflows/` (e.g., a
   `check-pr-title` action with a regex). If the repo requires a specific
   format like `type(TICKET): description`, note the convention — you will
   use it when writing the commit subject in step 10.
5. **Check for PR template.** Find the repo's pull request template(s).
   If multiple templates exist, note them — you will select the right
   one in step 10d after classifying the task type. If found, read and
   note visible headings
   and prompts (skip HTML comments). If no visible sections remain after
   stripping comments, treat it as no template found. You will structure
   the `pr_body` field in step 10d to match template sections — the
   post-script uses `pr_body` as the PR description.

From these files, determine:

- **Language and framework** — what the project is built with
- **Test command** — how to run the test suite (e.g., `make test`, `go test ./...`,
  `npm test`, `pytest`)
- **Lint command** — how to run linters (e.g., `make lint`, `pre-commit run --files`)
- **Commit conventions** — message format
- **PR title conventions** — whether the repo enforces a title format via
  CI (e.g., `type(TICKET): description`). The post-script uses the commit
  subject as the PR title and will inject a `(#ISSUE_NUMBER)` scope if
  missing, but matching the repo's expected format directly is preferred.
- **Branch conventions** — naming patterns, target branch

Determine the correct target branch from the issue context. If the issue
references a specific branch (e.g., "set up builds on the 3.18 branch"),
use that branch. Otherwise, determine the repo's default branch by trying
these commands in order until one succeeds:

```bash
# Try each discovery method; use the first that returns a non-empty value.
DEFAULT_BRANCH=""
if [ "${FULLSEND_FORGE:-github}" = "github" ]; then
  DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef \
    --jq '.defaultBranchRef.name' 2>/dev/null)" || true
fi
if [ -z "${DEFAULT_BRANCH}" ]; then
  DEFAULT_BRANCH="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null \
    | sed 's|^origin/||')" || true
fi
if [ -z "${DEFAULT_BRANCH}" ] || [ "${DEFAULT_BRANCH}" = "HEAD" ]; then
  DEFAULT_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|^refs/remotes/origin/||')" || true
fi
```

**Do not skip discovery and assume `"main"`.** If all discovery methods
fail, `${DEFAULT_BRANCH:-main}` provides a last-resort fallback — but
the post-script will auto-correct it to the API-discovered default branch
when no explicit allowed list is configured. Getting discovery right here
avoids an unnecessary correction and the warning that goes with it.

Write the structured output file with the target branch now. Write only
`target_branch` at this stage — `pr_body` is added after implementation
(step 10d) so a timeout never leaks placeholder text as the PR description.

```bash
mkdir -p "${FULLSEND_OUTPUT_DIR}"

jq -n --arg tb "${DEFAULT_BRANCH:-main}" '{target_branch: $tb}' \
  > "${FULLSEND_OUTPUT_DIR}/agent-result.json"
```

The post-script validates `target_branch` against allowed branches. When
no explicit `CODE_ALLOWED_TARGET_BRANCHES` list is configured, the
post-script auto-corrects to the API-discovered default branch if the
agent's value does not match.

### 4. Check for existing branch

Before creating a new branch, check whether a branch already exists for this
issue from a previous run:

```bash
git branch -a | grep "agent/<number>-"
```

**If no branch exists:** Proceed to step 5.

**If a branch exists:** Check whether a PR/MR is already open for it
using the forge-appropriate command from your forge skill (e.g.,
`gh pr list --head "<branch-name>"` on GitHub, or search MRs via
`curl` on GitLab).

- **Open PR/MR exists for this branch:** The work is already done and under
  review. Validate structured output — step 3 already wrote it, but on a
  validation retry the output directory was cleared, so write it again
  before validating — then **stop.** Do not add more commits on top of a
  working implementation — that causes scope creep and timeouts. Your exit
  state (no new commit) tells the post-script there is nothing new to push.

  ```bash
  fullsend-check-output "${FULLSEND_OUTPUT_DIR}/agent-result.json"
  ```
- **No open PR:** A previous run left commits that were never pushed or
  whose PR was closed. Check out the branch and review the delta:

  ```bash
  git checkout <branch-name>
  git log --oneline <target-branch>..HEAD
  git diff <target-branch>..HEAD --stat
  ```

  Use the local `<target-branch>` ref (e.g., `main`) discovered in
  step 3 — not `origin/<target-branch>`. The sandbox checks out the
  default branch at its latest commit before running, so the local ref
  is already current. Origin refs may not be available when the sandbox
  network policy blocks git protocol access.

  Treat the existing code as if you just wrote it. **Skip to step 9**
  (verification) — run secret scan, tests, and pre-commit on the changed
  files. If everything passes, the post-script will push the branch and
  create the PR. If tests or pre-commit fail, fix only the failing issues
  in a new commit on the same branch — do not rewrite or redo the
  existing work.

**Scope guardrail:** When working on top of an existing branch, your
changes must be strictly limited to fixing verification failures or
completing incomplete work. Do not "improve" a working implementation by
adding RBAC configs, extra test cases, documentation, or config files
the issue does not mention.

### 5. Create branch

```bash
echo "::notice::STEP 5: Create branch"
```

The sandbox checks out the default branch at its latest commit, so
`HEAD` is already the correct base. Do not run `git fetch origin` — the
sandbox network policy blocks git protocol access.

If the `BRANCH_NAME` environment variable is set, use it:

```bash
git checkout -b "${BRANCH_NAME}"
```

Otherwise, create a feature branch from the current HEAD:

```bash
git checkout -b agent/<number>-<short-description>
```

The branch name must follow the `agent/<issue-number>-<short-description>`
convention. Keep the description to 2-4 lowercase hyphenated words derived
from the issue title.

### 6. Identify the task type

Before planning, determine what kind of work this issue requires:

- **Bug fix** — the standard path. Reproduce, plan, implement, test, commit.
- **Feature / enhancement** — new behavior. Plan, implement, test, commit.
- **Test-only** — the issue asks for tests, not production code changes. Write
  tests that cover the described behavior. Do not modify production code unless
  tests require it (e.g., exporting a function for testability).
- **Already-fixed** — if step 7 reveals the bug no longer exists, validate
  structured output and stop cleanly. Do not implement a fix for a resolved
  issue.
- **Label-gated** — if the issue has a label like `do-not-implement` or a gate
  label that signals no work should be done, validate structured output and
  stop cleanly:

  ```bash
  fullsend-check-output "${FULLSEND_OUTPUT_DIR}/agent-result.json"
  ```

### 7. Verify the problem exists

Before implementing, confirm the reported behavior is still present:

1. Read the code paths the issue describes. Does the bug still exist in the
   current codebase?
2. If there is a quick way to verify — run a targeted test, check a return
   value, trace the logic — do it.
3. If the bug has already been fixed (by a recent commit, a dependency update,
   or another PR), validate structured output and **stop**. Do not implement
   a fix for a resolved issue. Your exit state (no commit) tells the
   post-script to report accordingly.

   ```bash
   fullsend-check-output "${FULLSEND_OUTPUT_DIR}/agent-result.json"
   ```

For feature requests and test-only tasks, skip this step — there is no bug to
reproduce.

### 8. Plan the implementation

Before writing code, form a concrete plan:

1. **Read affected files in full** — not just the lines mentioned in the issue.
   Understand the surrounding context, imports, types, and call sites.
2. **Read test files** that cover the affected code. Understand how the existing
   tests are structured, what patterns they follow, what helpers exist.
3. **Read related files** — if the change touches an API handler, read the
   router, middleware, and model files. If it touches a controller, read the
   reconciler pattern and RBAC config.
4. **Follow cross-repo references** — if the issue, docs, or triage comments
   link to other repos (e.g., an e2e test suite, a dependent service, a
   related PR in another repo), read those references to understand the full
   picture. Use the forge-appropriate commands from your forge skill to fetch
   what you need. For files in other repos that are not part of an issue
   or PR, use `Read` on a local clone if available, or note the gap in
   your plan and proceed with the context you have.
   Do not chase every import — focus on references that the issue context
   points you toward.
5. **Identify what to change** — list the specific files and functions you will
   modify or create.
6. **Identify what tests to write or update** — new behavior needs new tests;
   changed behavior needs updated tests.
7. **Assess risk** — will this change affect other callers? Does it change a
   public interface? Could it break downstream consumers?
8. **Search for old literal values when changing constants or defaults** — when
   the task changes a constant, default, or configuration value from X to Y:
   1. Search for all references to the constant/variable **name** (symbol search).
   2. Search for the **old value X** as a string literal in test files, docs, and
      config (e.g., `*_test.go`, `*.md`, `*.yaml`). Tests often hardcode expected
      values rather than referencing constants, so a symbol-only search misses them.
   3. Evaluate each match — some may be intentional (e.g., testing the non-default
      case) while others are stale assumptions that need updating.
9. **Verify API contracts per code path** — if the fix removes, empties,
   or changes a parameter sent to an external API, check the API documentation or
   test each code path that uses the function. Different operations
   (e.g., approve vs request-changes) often have different required fields.

When requirements are ambiguous, distinguish between "vague but actionable"
(you can make a reasonable conservative interpretation) and "genuinely
uninterpretable" (no viable path forward). For vague-but-actionable issues,
implement the most conservative interpretation and note your assumptions in
the commit message.

Do not start writing code until you can articulate: what you will change, why,
and how you will verify it works.

### 9. Implement and verify

Write the code change, then verify it.

**Context efficiency:** A PostToolUse hook automatically compacts verification
tool output. Successful runs of scan-secrets, pre-commit, tests, linters, and
gitlint produce a one-line summary; only failures show full output. You do not
need to redirect output or parse results manually — just run the commands and
react to what you see.

**Implementation:**

- **Follow existing patterns unless AGENTS.md specifies otherwise** (see
  step 3 precedence rule). If the repo uses a specific error handling
  idiom, use it. If controllers follow a specific reconciliation pattern,
  follow it. If test files use a specific helper library, use it.
- **Do not introduce new dependencies without justification.** If the change can
  be made with the existing dependency set, prefer that.
- **Write or update tests.** Every behavioral change must have a corresponding
  test change. If the issue includes a proposed test case from triage, evaluate
  it critically — use it if it's good, improve it if it's not, replace it if
  it's wrong.

**9a. Secret scan — MANDATORY FIRST STEP**

```bash
echo "::notice::STEP 9a: Secret scan"
```

Run the secret scan against your changed files before anything else:

```bash
scan-secrets <files-you-modified>
```

If secrets are detected: hard stop. Remove them, re-scan. Only proceed after
the scan passes.

**9b. Pre-commit hooks — run them, do not skip them**

```bash
echo "::notice::STEP 9b: Pre-commit hooks"
```

Pre-commit is bounded, not optional. Exactly two things let you stop
short: the time-budget threshold above (under 10% of the budget
remaining), and STEP D's two-run cap. Nothing else authorizes skipping
it. The post-script (`post-code.sh`) runs an authoritative pre-commit
check on the CI runner before pushing. However, the post-script runs
**after the sandbox is destroyed** — any failure it catches is
terminal (`pre-commit-blocked`), ending the run with no PR and
requiring human re-dispatch. "The post-script runs it authoritatively"
is therefore **not** a valid reason to skip verification. Running
hooks in-sandbox catches the same failures while the agent can still
fix them, avoiding an expensive terminal failure.

```bash
test -f .pre-commit-config.yaml && echo "pre-commit config found"
```

If no `.pre-commit-config.yaml`, skip to 9c.

**Setup:**

```bash
if ! command -v pre-commit &>/dev/null; then
  pip install pre-commit 2>/dev/null || pip3 install pre-commit 2>/dev/null
fi
```

Do NOT run `pip install pre-commit` if pre-commit is already on the PATH.
The sandbox image ships a pinned version with network policies tuned to it.
Do NOT run `pre-commit install --install-hooks` — it registers a git hook
that can block `git commit`.

**STEP A — Pre-format your code before running pre-commit.** Many hooks
auto-fix files (formatters, trailing-whitespace, end-of-file-fixer). Doing
this yourself first eliminates an entire re-run cycle. Check the repo's
`.pre-commit-config.yaml` for which formatters are configured, then run
them manually on your changed files. For example:

```bash
# Run the repo's formatter directly — language varies:
#   Go: gofmt -w / goimports -w
#   Python: black / ruff format
#   JS/TS: prettier --write
#   Rust: rustfmt
# Check what is available on PATH and what the repo uses.
```

For config files (YAML, JSON, TOML) you create or modify: read 1-2
existing files in the same directory to match indentation, quoting,
and line length. Most linter failures on config files come from
mismatched style.

**STEP B — Run pre-commit once on all changed files:**

```bash
pre-commit run --files <all-your-changed-files>
```

Never run per-file. Many linter hooks analyze the entire project per
invocation — running per-file multiplies that cost.

The first run may be slow (installs hook environments). This is normal.

**STEP C — React to the result:**

- **Exit 0** — all hooks passed. Stage and proceed to 9c.
- **Exit 1 with auto-fix only** (hooks say "Fixed" / "Fixing"): files
  are already corrected. Stage them and re-run once to confirm:

  ```bash
  git add <fixed-files>
  pre-commit run --files <all-your-changed-files>
  ```

- **Exit 1 with linter errors**: fix only what the linter reports — do
  not refactor, do not rewrite. Re-run once:

  ```bash
  pre-commit run --files <all-your-changed-files>
  ```

- **Any other failure** (exit 3, network error, infrastructure error) —
  **do not skip verification.** When `pre-commit` fails because it
  cannot fetch remote hook repositories (common in sandboxes with
  restricted network access), fall back to running the configured
  hooks directly:

  1. Parse `.pre-commit-config.yaml` to identify each hook's `repo`
     type, `entry` command, `args`, `rev`, `stages`,
     `additional_dependencies`, and file filters. Honor them when you
     invoke the tool yourself: append the hook's `args` after `entry`,
     pass only the changed files matching the hook's `files` /
     `types` / `exclude` patterns, and pass no filenames at all when
     the hook sets `pass_filenames: false`. Skip any hook whose
     `stages` excludes the pre-commit stage — the post-script will not
     run it either, so running it here invents a failure. Install a
     hook's `additional_dependencies` alongside the tool; without
     them a plugin-driven hook (a flake8 or mypy with plugins, say)
     reports different results than the post-script will. A hook
     invoked with the wrong arguments, the wrong file set, or the
     wrong dependencies does not tell you what the post-script will
     see.
  2. **`repo: local` hooks:** Run the `entry` command directly. Local
     hooks need no network beyond what the entry itself uses (e.g.,
     `uvx`, `uv`, `pip` access to PyPI is typically allowed by the
     sandbox network policy). Example:

     ```bash
     # .pre-commit-config.yaml entry: uvx ty check --ignore unresolved-import
     uvx ty check --ignore unresolved-import <your-changed-files>
     ```

  3. **Remote hooks with obvious PyPI equivalents:** Install and run
     the underlying tool directly, **in the same mode the configured
     hook uses** — formatter hooks rewrite files, so run the formatter
     in write mode and stage the result exactly as in the auto-fix
     branch above; pure linters only report. Checking instead of
     writing leaves the file unformatted, which is the failure the
     post-script turns terminal. Common mappings:
     - `astral-sh/ruff-pre-commit` → `ruff check` (reports; add
       `--fix` only if the hook's `args` do) and `ruff format`
       (writes)
     - `psf/black` → `black` (writes)
     - `pycqa/isort` → `isort` (writes)
     - `pycqa/flake8` → `flake8` (reports)

     Install via `pip`/`uvx` if not already on PATH — PyPI access is
     allowed. Pin the install to the hook's `rev` from the YAML: a
     newer release can format or lint differently from the version the
     post-script runs, which turns an in-sandbox pass into a runner
     failure. `rev` is a git tag, not a PyPI version — strip a leading
     `v` (`rev: v0.6.9` → `pip install ruff==0.6.9`) and otherwise use
     it verbatim. If the tag does not map cleanly onto a PyPI version
     (date-based or project-specific tags), do not guess a pin and do
     not silently fall back to the latest release: that is case 4
     below. Likewise do not discard the installer's stderr — a tool
     that cannot be installed is case 4, not a pass.

     ```bash
     # Example: ruff hooks from astral-sh/ruff-pre-commit, rev v0.6.9
     command -v ruff &>/dev/null || pip install "ruff==0.6.9"
     if command -v ruff &>/dev/null; then
       ruff check <your-changed-files>   # plus the hook's args
       ruff format <your-changed-files>  # writes — stage what it fixes
       git add <your-changed-files>
     else
       echo "::warning::ruff unavailable — ruff hooks not run"  # case 4
     fi
     ```

  4. **Remote hooks with no obvious equivalent:** Log that the hook
     could not be run and why. Disclose this in the commit message.
  5. **React to direct-execution results the same way as pre-commit
     results:** if a hook reports errors, fix them and re-run the
     direct execution once. A `pre-commit run` that died on
     infrastructure executed no hooks, so it does not consume a run:
     the direct-execution fallback takes its place as run 1, and the
     re-run after your fixes is run 2. STEP D then applies.

**STEP D — After the retry, STOP regardless of the result.**

If the second run passes (whether `pre-commit run` or direct execution
of hooks), great. If it fails again, **you are done with pre-commit for
the entire session**. Log the exact hook name, file, and error in your
commit message and move on to 9c. Do NOT attempt a third run. Do NOT try
a different fix. What is exhausted is the retry budget, not the problem:
RULE 2 still requires you to disclose the failure, so a human sees it
even if the runner rejects the commit.

**RULES:**

1. **Maximum 2 pre-commit/hook-execution runs total across the entire
   session.** One initial run, one retry. A `pre-commit run` that failed
   on infrastructure before executing any hook does not count — the
   direct-execution fallback takes its place as the initial run. No
   more — not even if step 9c sends you back to fix your code. Once
   you have used your 2 runs, pre-commit is done. Do not re-run it
   during retries.
2. **Always disclose.** If pre-commit did not pass, say so in the commit
   message with the exact error. Never claim hooks passed when they did
   not.
3. **Pre-existing failures on files you did not touch are not your
   responsibility.** Only run hooks on **your** changed files.
4. **Do not refactor to satisfy a linter.** Fix the specific reported
   error — nothing more.

**9c. Tests and linters — MANDATORY**

```bash
echo "::notice::STEP 9c: Tests and linters"
```

You MUST run both **tests** and **linters** on the code you changed.
Both are mandatory — do not skip either one.

**Run targeted tests** — only test the packages/modules you changed:

- **Go:** `go test ./path/to/changed/pkg/...` for each changed package.
  Use `go test ./...` only if changes span many packages or affect shared
  libraries.
- **Python:** `pytest path/to/test_file.py` or
  `pytest tests/unit/test_module.py` for the module you changed. Run
  `pytest` (full suite) only as a final check.
- **JS/TS:** `npm test -- --testPathPattern='changed-module'` or the
  framework's equivalent filter flag.
- **Makefile targets:** If the Makefile has granular test targets (e.g.,
  `make test-unit`, `make test-pkg PKG=./internal/foo`), prefer those
  over `make test`.

Determine which packages to test from your changed files:

```bash
git diff --name-only <target-branch>
```

Use the local `<target-branch>` ref, not `origin/<target-branch>`, for
the reasons given in step 4. This shows all files that differ between
the target branch and the working tree — including previously
committed changes on the feature branch.

Full-suite runs (`go test ./...`, `npm test`, `pytest`) are acceptable as
a final validation after targeted tests pass, but prefer targeted runs
first to save time and context budget.

**Run the repo's lint command** — this is the lint command you identified
in step 3 from `CLAUDE.md`, `CONTRIBUTING.md`, `Makefile`, or CI config.
You MUST run it now. Linting is separate from pre-commit (9b) — even if
pre-commit passed or was skipped, you still run the lint command here.

```bash
# Use the exact lint command discovered in step 3. Examples:
make lint                                         # Go repos with Makefile
golangci-lint run ./...                           # Go without Makefile
uv run ruff check src/ tests/                     # Python with ruff
npm run lint                                      # JS/TS repos
eslint src/                                       # JS/TS without npm script
```

If the repo specifies multiple lint/format commands (e.g.,
`ruff format && ruff check && pytest`), run all of them — not just the
test command. Lint violations like `SIM401` or `UP038` require you to
understand the error and rewrite your code, the same way you handle test
failures.

**If tests or linters fail due to missing tools or infrastructure** (not
due to your code): try the Makefile's setup targets first (`make deps`,
`make setup`, etc.). If the tool genuinely cannot be installed in the
sandbox, note this in your commit message body so reviewers know what was
not verified:

> Note: <suite-name> tests could not run (<reason>). <other-suite>
> tests passed. Manual verification of <suite-name> is required.

**Do NOT silently skip tests or linters and commit as if everything
passed.** If you cannot run the relevant test suite or lint command, you
must disclose that.

**If tests or linters fail due to your code:**

1. Read the failure output carefully. Understand the root cause.
2. Fix the issue in your implementation. Do not weaken or skip tests.
   For lint errors, fix the specific reported violation — do not
   refactor unrelated code or disable the lint rule.
3. Re-run secret scan (9a), then tests and linters (9c). This consumes
   one retry iteration. **Do NOT re-run pre-commit (9b) during
   retries** — you already used your 2 pre-commit runs, and RULE 2
   requires you to disclose any hook failure in the commit message.
4. Repeat until both tests and linters pass or the retry limit is
   reached.

The retry limit is read from the `MAX_RETRIES` environment variable
(default: 1 if unset). The harness may also enforce a hard timeout
independently — if the harness kills the session, your retry count is
irrelevant. Prefer committing with a disclosed issue over burning time
on additional retry iterations.

If the retry limit is reached and tests or linters still fail, do not
commit. Validate structured output, then stop:

```bash
fullsend-check-output "${FULLSEND_OUTPUT_DIR}/agent-result.json"
```

**9d. Self-review**

Before staging, review your own changes:

```bash
git diff
```

Read every line. Check for:

- Changes that don't serve the issue (scope creep, unrelated formatting)
  <!-- skillsaw-disable-next-line content-placeholder-text -->
- Accidental artifacts: debug prints, commented-out code, TODO comments
- Secret material: `.env`, `*.pem`, `*.key`, `credentials.json`
- Protected-path files (see agent definition for the authoritative list)

If you added more than necessary, revert the extras before staging.

### 10. Commit

```bash
echo "::notice::STEP 10: Commit"
```

Stage **only the files you modified or created** and commit.

**10a. Stage files**

```bash
git add path/to/file1 path/to/file2
```

Only include files you deliberately created or modified.

**10b. Review and scan what you are committing**

```bash
git diff --cached --stat
```

Confirm only your intended files are present. Unstage anything unexpected:

```bash
git reset HEAD <file-you-did-not-intend-to-stage>
```

Then run the secret scan against the staged content:

```bash
scan-secrets --staged
```

This is not a repeat of 9a — it scans what you *actually staged*, which may
differ from what you named. If the scan fails, do not commit.

**NEVER use `git commit -s` or add `Signed-off-by` trailers.** DCO is a
human attestation of personhood and legal authority to contribute — agents
are not people. The DCO app already waives the check for bot authors, so
the trailer is unnecessary. Including it causes gitlint
`body-max-line-length` failures because the bot noreply email makes the
trailer ~90 characters.

**10c. Commit**

The commit message must:

- **Use the repo's commit convention as discovered in step 3.** If
  `CONTRIBUTING.md`, `CLAUDE.md`, `.gitlint`, or the existing commit history
  uses a specific format (e.g., Conventional Commits, Angular-style, ticket
  prefixes), follow it.
- **Include the issue reference in the commit subject.** The post-script
  uses the commit subject as the PR title. Many repos enforce PR title
  conventions like `type(TICKET): description`. Always include the issue
  number as a scope: `<type>(#<number>): <description>`. If the repo uses
  Jira-style ticket IDs (e.g., `PROJ-123`) and the issue title or body
  contains one, use that instead: `<type>(PROJ-123): <description>`.
- **Fall back to `<type>(#<number>): <description>` if no convention was
  found.** The `(#<number>)` scope ensures the PR title passes most
  title-check CI jobs.
- **Reference the issue number in the body.** If your implementation
  fully addresses the issue scope, use `Closes #<number>`. If your
  implementation addresses only a subset of the issue (e.g., the triage
  identified 4 components but you implemented 2), use
  `Related to #<number>` instead — premature closure loses the remaining
  work items. Use the same keyword in both the commit body and `pr_body`
  for consistency.

**Title length — check `.gitlint` if it exists:**

```bash
test -f .gitlint && cat .gitlint
```

Most repos enforce a title length limit (commonly 72 characters). If
`.gitlint` has `[title-max-length] line-length=72`, keep the title
(first line) under that limit. Use a concise `<type>: <description>`
that fits.

**Body line length — comply with the repo's gitlint config:**

If `.gitlint` has a `[body-max-line-length]` rule (e.g. `line-length=72`),
you **MUST** hard-wrap commit body text at that limit. This is enforced
by CI. The post-script will unwrap the commit body when building the PR
description (legacy path), so your hard-wrapped commit body will still
render as nice prose on GitHub. When you provide `pr_body` in the result
file, the post-script uses it verbatim (no unwrapping), so `pr_body` is
not subject to gitlint line-length constraints.

Hard-wrap guidelines when a limit is configured:
- Break lines at word boundaries before hitting the limit
- List items that exceed the limit: start the continuation on the next
  line, indented by 2 spaces
- URLs that exceed the limit may remain on one line (gitlint usually
  allows this via `ignore-body-lines`)
- `Closes #N` and similar trailers: keep on one line
- **`Signed-off-by:`** — do NOT use `git commit -s`. The DCO is a
  human attestation of personhood and legal authority to contribute.
  No human is present to make that certification in an autonomous
  agent session. Your commits use the GitHub App bot identity, which
  the DCO app auto-exempts. The human who merges the PR accepts
  responsibility for the contribution

The commit body should:
- Explain **what** changed and **why** (not just "fix bug")
- Describe the root cause or motivation
- Summarize which files/functions were modified and the approach
- Note any trade-offs, assumptions, or edge cases

```bash
git commit -m "<type>(#<number>): <short-description>

<What changed and why. Hard-wrap at the limit from
.gitlint if one is configured. Write substantive
content for human reviewers.>

Closes #<number>"
```

Keep commit body concise (respects gitlint line-length limits). PR body
in agent-result.json holds the template-structured description if needed.

**After committing, validate the commit message if gitlint is available:**

```bash
which gitlint &>/dev/null && gitlint --commit HEAD
```

If gitlint fails, **undo and recommit** with a corrected message (do not
use `--amend` — always create new commits to preserve attribution):

```bash
git reset --soft HEAD~1
git commit -m "<fixed title>

<fixed body — respect ALL line-length rules>"
gitlint --commit HEAD
```

Common gitlint failures:
- **T1 title-max-length** — shorten the title.
- **B1 body-max-line-length** on prose — re-wrap the offending line.

Repeat until gitlint passes. Do not leave a commit that you know will
fail CI. If gitlint is not available, manually verify that no line in
the title or body exceeds the configured limits.

If a git hook fires during `git commit` and fails (e.g., the repo shipped
a `.git/hooks/pre-commit`), do NOT enter a fix-and-retry loop. You already
ran pre-commit in step 9b (which is the same check). Commit with
`--no-verify` to bypass the git hook and disclose the failure in the commit
message. The post-script runs an authoritative pre-commit on the runner.

**Do not push the branch.** The post-script handles pushing, PR creation,
and failure reporting.

**10d. Write pr_body to structured output**

Now that implementation is complete, add `pr_body` to the result file.
The post-script uses `pr_body` as the PR description (no gitlint
line-length constraints) and automatically appends the closing
reference (`Closes` or `Related to`) — do not include closing
references in pr_body.

If step 3 found PR template(s), select the one matching the task type
from step 6 and structure `pr_body` to match its sections. Otherwise,
write a best-effort description covering what changed, why, testing
approach, and any caveats.

**Cross-repo ordering:** When the motivating issue references a
different repository (e.g., a failure observed in an upstream repo),
lead the summary with what files in **this** repository are changing
and why. Place cross-repo references in a secondary "Context" or
"Related" subsection — not in the opening sentence. Reviewers read
the first line to orient themselves; leading with an external repo
reference can mislead them about which repository the PR targets.

Use a quoted heredoc to capture `pr_body` content without shell
expansion, then pass it to `jq --arg`:

```bash
pr_body=$(cat <<'PRBODY'
<pr_body content>
PRBODY
)
jq --arg pb "$pr_body" '. + {pr_body: $pb}' \
  "${FULLSEND_OUTPUT_DIR}/agent-result.json" > "${FULLSEND_OUTPUT_DIR}/agent-result.json.tmp" \
  && mv "${FULLSEND_OUTPUT_DIR}/agent-result.json.tmp" "${FULLSEND_OUTPUT_DIR}/agent-result.json"
```

**Closing reference:** If your implementation addresses only a subset of
the issue scope, add `closes_issue: false` to the result file so the
post-script uses `Related to` instead of `Closes` in the PR body:

```bash
jq '. + {closes_issue: false}' \
  "${FULLSEND_OUTPUT_DIR}/agent-result.json" > "${FULLSEND_OUTPUT_DIR}/agent-result.json.tmp" \
  && mv "${FULLSEND_OUTPUT_DIR}/agent-result.json.tmp" "${FULLSEND_OUTPUT_DIR}/agent-result.json"
```

If your implementation fully addresses the issue, omit this field — the
default is `true` (the post-script appends `Closes`).

### 11. Validate structured output

**This step is MANDATORY.** The harness runs a validation loop that
checks `$FULLSEND_OUTPUT_DIR/agent-result.json` against
`schemas/code-result.schema.json`. If validation fails, the harness
retries the agent. Producing a valid output file is not optional.

You wrote the initial output file in step 3. Confirm it still exists
and contains the correct target branch:

```bash
echo "::notice::STEP 11: Validate structured output"
cat "${FULLSEND_OUTPUT_DIR}/agent-result.json"
```

The file must be valid JSON with `target_branch` (required) and
optionally `pr_body` and `closes_issue`:

```json
{
  "target_branch": "main",
  "pr_body": "## Summary\n\nWhat changed and why.\n\n## Testing\n\nHow it was tested."
}
```

**Schema compliance:** The schema uses `additionalProperties: false`.
Only `target_branch`, `pr_body`, and `closes_issue` are allowed. Any
other fields will cause validation to fail.

Validate the output against the schema:

```bash
fullsend-check-output "${FULLSEND_OUTPUT_DIR}/agent-result.json"
```

If validation fails, read the error output, fix the JSON file, and
re-run the check. If it still fails after 3 attempts, write the best
JSON you have and exit.

## Partial work

If you hit a token limit or context window boundary before completing the
implementation, and the tests pass on the partial work: commit what you have.
The review agent downstream will evaluate completeness — incomplete-but-passing
code is caught at the review stage, not the implementation stage. State in the commit
message description that the work is partial (e.g., "partial
implementation") and use `Related to #<number>`
instead of `Closes #<number>`. Set `closes_issue: false` in the result
file so the post-script uses the same keyword in the PR body.

**Structured output is still required for partial work.** The output file
written in step 3 must exist and be valid. Run `fullsend-check-output`
(step 11) even when exiting early.

## Constraints

The agent definition (`agents/code.md`) is the authoritative list of
prohibitions. This skill does not restate them. If a step in this skill
appears to conflict with the agent definition, the agent definition wins.
