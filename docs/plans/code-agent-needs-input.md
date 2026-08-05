# Plan: Code agent "needs input" pushback

Tracking issue: https://github.com/fullsend-ai/agents/issues/677

## Problem

The code agent has no way to refuse to open a PR it can't stand behind.

1. **Environment/tooling is broken.** `skills/code-implementation/SKILL.md` step
   9c currently says: if tests/linters can't run due to missing tools or infra
   (not the agent's code), try `make setup`, and if that still doesn't work,
   commit anyway with a disclosure buried in the commit message. Step 9a says
   to hard-stop if `scan-secrets` is missing, but that stop produces no
   informative signal — it falls through to the generic "no changed files"
   no-op comment in `post-code.src.sh`.
2. **The issue is genuinely uninterpretable.** Step 8 tells the agent to
   distinguish "vague but actionable" from "genuinely uninterpretable" — but
   never says what to do in the uninterpretable case.

Both cases currently produce, at best: *"No changed files in agent's
commit(s)"* — no explanation, no signal a human needs to act.

## Goals

- One structured way for the code agent to say "stopping, a human needs to
  act before I can make progress" — covering both causes above.
- Surface that as a label + explanatory comment on the issue, never a PR.
- Single label (`fs-code-needs-input`) reused for both causes — the comment
  body carries the specifics.
- Scope: code agent only (fix agent is a follow-up).

## Non-goals

- Fix agent (PR review-feedback loop).
- Genuine implementation failure (tests fail because the code is wrong) —
  unchanged: stop, no commit, no `needs_input`.
- The "already fixed" / "label-gated" / "PR already open" no-op paths —
  legitimate no-ops, keep today's generic no-op comment.

## Decisions (confirmed with user)

1. When `needs_input` fires, remove the `ready-to-code` label (it's no
   longer true).
2. Post a fresh conversational comment each time (not a sticky/marker
   comment) — matches how triage's `insufficient` action behaves.
3. Label color: no preference, pick anything distinct from `pr-open`'s
   purple.

## Design

### 1. Schema — `schemas/code-result.schema.json`

Add one optional field:

```json
"needs_input": {
  "type": "string",
  "minLength": 1,
  "maxLength": 4000,
  "description": "Set when the agent cannot proceed without human input — either the environment/tooling is broken (can't verify changes) or the issue is genuinely uninterpretable. Explain specifically what is needed. When set, do not commit; the post-script applies the needs-input label and posts this text as a comment instead of opening a PR."
}
```

`target_branch` stays required and unconditional — it's cheap to determine
(a `git`/`gh` call) independent of outcome, and the agent already writes it
in step 3 before it knows whether it will hit a blocker later.

### 2. Label — `harness/code.yaml`

```yaml
env:
  runner:
    CODE_ALLOWED_TARGET_BRANCHES: "${CODE_ALLOWED_TARGET_BRANCHES}"
    CODE_NEEDS_INPUT_LABEL: "fs-code-needs-input"
```

Hardcoded value, not a secret/repo var. `post-code.src.sh` reads it with a
fallback (`${CODE_NEEDS_INPUT_LABEL:-fs-code-needs-input}`) so it degrades
gracefully under an older harness config that doesn't set it.

### 3. Agent/skill changes — `skills/code-implementation/SKILL.md`

Three anchor points, all already-identified gaps in the existing text:

- **Step 8 (planning, ambiguity).** After the existing "distinguish vague
  vs. genuinely uninterpretable" sentence, add: for genuinely
  uninterpretable issues, write `needs_input` explaining what's ambiguous
  and why no conservative interpretation is safe, skip implementation, go
  to step 11 (validate output) and stop. No commit.
- **Step 9a (secret scan helper missing).** Reclassify as an environment
  blocker: set `needs_input` (e.g. "scan-secrets helper not found in
  sandbox image at /usr/local/bin/scan-secrets — cannot verify changes are
  free of secrets") instead of a bare stop with no signal.
- **Step 9c (tests/linters fail due to missing tools/infra) — the
  behavioral reversal.** Replace "commit anyway with a disclosure" with:
  after one `make setup`/`make deps` attempt, if the tool still can't run,
  set `needs_input` describing exactly what's missing (tool, command,
  error) and stop without committing. The code-caused-failure branch
  (tests fail because the implementation is wrong) is unchanged.

`agents/code.md`'s "Structured output" section gets a one-line addition
documenting `needs_input` alongside `target_branch`/`pr_body`.

### 4. Post-script — `scripts/post-code.src.sh`

Insert a check immediately after `RESULT_FILE` is parsed for
`target_branch`/`closes_issue` (before branch-name validation, before any
git/branch/secret-scan work):

```bash
CLOSES_ISSUE="true"
NEEDS_INPUT=""
if [ -n "${RESULT_FILE}" ]; then
  AGENT_TARGET="$(jq -r '.target_branch // empty' "${RESULT_FILE}" 2>/dev/null || true)"
  AGENT_CLOSES="$(jq -r '.closes_issue // empty' "${RESULT_FILE}" 2>/dev/null || true)"
  NEEDS_INPUT="$(jq -r '.needs_input // empty' "${RESULT_FILE}" 2>/dev/null || true)"
  if [ "${AGENT_CLOSES}" = "false" ]; then
    CLOSES_ISSUE="false"
  fi
fi

if [ -n "${NEEDS_INPUT}" ]; then
  gha_echo notice "Agent needs input — posting comment and stopping (no PR)"
  post_needs_input_comment "${NEEDS_INPUT}"
  exit 0
fi
```

New `post_needs_input_comment()` (defined earlier in the file than its call
site, near the other helpers sourced/defined in the "Setup" section):

```bash
post_needs_input_comment() {
  local needs_input="$1"
  local safe_issue_number
  safe_issue_number="$(_sanitize_workflow_value "${ISSUE_NUMBER}")"

  _post_failure_ensure_token

  local label="${CODE_NEEDS_INPUT_LABEL:-fs-code-needs-input}"
  gh label create "${label}" --repo "${REPO_FULL_NAME}" \
    --description "Code agent needs human input to proceed" --color "D93F0B" \
    --force 2>/dev/null || true
  gh api "repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/labels" \
    -f "labels[]=${label}" --silent 2>/dev/null || true
  gh api "repos/${REPO_FULL_NAME}/issues/${ISSUE_NUMBER}/labels/ready-to-code" \
    -X DELETE --silent 2>/dev/null || true

  local sanitized_input
  sanitized_input="$(sanitize_failure_detail "${needs_input}")"

  local body
  body="🚧 **Code agent needs input** — issue #${safe_issue_number}

The code agent stopped before implementing a fix because it needs input from a human before it can proceed safely.

**What it needs:**
${sanitized_input}

Once this is resolved, remove the \`${label}\` label and re-trigger with \`/fs-code\`."

  if ! gh issue comment "${ISSUE_NUMBER}" \
    --repo "${REPO_FULL_NAME}" \
    --body "${body}" 2>/dev/null; then
    gha_echo warning "Failed to post needs-input comment to issue #${safe_issue_number}"
  fi
}
```

Notes:

- `sanitize_failure_detail` (existing helper in
  `scripts/lib/post-failure-report.lib.sh`) is reused to redact tokens and
  cap length before the text is embedded in a public comment — same
  discipline as failure-report comments.
- This is a clean stop (`exit 0`), not an error — no PR, no push, no
  secret scan needed (nothing to scan).
- Plain `gh issue comment` (fresh comment each run), matching decision #2.
- `ready-to-code` is explicitly removed, matching decision #1.

## Test plan (TDD — tests first)

Existing test files establish two different conventions:

- `scripts/post-code-test.sh` re-implements small logic fragments (title
  rewriting, PR body assembly) as standalone shell functions and asserts
  against them, plus greps the bundled script for expected function names.
- `scripts/post-triage-test.sh` runs the *actual* `post-triage.sh` script
  end-to-end against fixture JSON, with a mock `gh` binary on `PATH` that
  logs every invocation to a file, and asserts on logged call patterns.

The `needs_input` short-circuit in `post-code.src.sh` is a clean early-exit
before any git operations, so it's a good fit for the `post-triage-test.sh`
style: run the real bundled `post-code.sh`, `REPO_DIR="."` (skip cd/git
setup entirely — we exit before any git commands run), mock `gh`, assert on
logged calls.

Planned new tests in `scripts/post-code-test.sh` (or a new
`scripts/post-code-needs-input-test.sh` if that keeps the file more
readable — TBD during implementation):

1. `needs-input-skips-push-and-pr` — given `{"target_branch":"main","needs_input":"..."}`,
   assert the mock `gh` log contains no `git push`/`pr create` calls (there
   won't be any `gh pr create` call logged at all).
2. `needs-input-applies-label` — assert log contains
   `gh api repos/OWNER/REPO/issues/N/labels -f labels[]=fs-code-needs-input --silent`.
3. `needs-input-removes-ready-to-code` — assert log contains
   `gh api repos/OWNER/REPO/issues/N/labels/ready-to-code -X DELETE --silent`.
4. `needs-input-posts-comment` — assert log contains
   `gh issue comment N --repo OWNER/REPO --body ...` with the `needs_input`
   text present in the body.
5. `needs-input-exits-zero` — the script exits 0 (clean stop, not a
   failure).
6. `no-needs-input-field-unaffected` — a normal result file (no
   `needs_input` key) still proceeds through the existing push/PR path
   (regression guard — reuse an existing passing scenario if one already
   covers this, otherwise add a minimal one).
7. Respect `CODE_NEEDS_INPUT_LABEL` env var override in the label-creation
   call (falls back to `fs-code-needs-input` when unset).

Schema tests: add a case to whatever exercises
`schemas/code-result.schema.json` (check `scripts/validate-output-schema.sh`
and its test file, if one exists, or add fixtures under the harness's
schema-validation test path) confirming:

- `{"target_branch": "main", "needs_input": "..."}` validates.
- `needs_input` longer than 4000 chars fails validation.
- `needs_input` as empty string fails validation (`minLength: 1`).

Run `make test` before starting (baseline green) and after each change
(TDD: write/extend a test, watch it fail for the right reason, then
implement, then watch it pass).

## Files touched

- `schemas/code-result.schema.json` — add `needs_input` field.
- `harness/code.yaml` — add `CODE_NEEDS_INPUT_LABEL` to `env.runner`.
- `agents/code.md` — document `needs_input` in "Structured output".
- `skills/code-implementation/SKILL.md` — steps 8, 9a, 9c updates described
  above.
- `scripts/post-code.src.sh` — `post_needs_input_comment()` + early-exit
  check (then `make script-build` to regenerate `scripts/post-code.sh`).
- `scripts/post-code-test.sh` (or new test file) — new test cases.
- Possibly a schema-validation test fixture, if one exists for
  `code-result.schema.json` specifically.

## Open items to watch during implementation

- Confirm exact insertion point in `post-code.src.sh` doesn't disturb the
  `AGENT_TARGET` branch-name-validation error path (needs_input check must
  come *before* that validation, since a needs_input-only result may not
  set a meaningful `target_branch` in edge cases — though per current
  design the agent always writes `target_branch` regardless).
- Confirm `make script-build` regenerates `scripts/post-code.sh` cleanly
  and `make check-bundle` passes (bundled script must match source).
- Lint agent docs (`hack/lint-agent-docs-test.sh` appeared in the test
  suite) may enforce structure on `agents/code.md` — check it after
  editing.
