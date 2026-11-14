---
name: fix-result-contract
description: >-
  Use when writing or validating the fix agent's agent-result.json output.
  Canonical owner of the JSON handoff contract: schema requirements, the
  fullsend-check-output validation loop, partial-work behavior, failure
  handling, optional PR/MR title and description proposals (pr_title,
  pr_body), and validation-retry semantics — including carry-forward of
  rebased_onto_target, merged_target, conflict_update, history_rewritten,
  and the PR metadata fields when the runner clears the output directory
  between retries. Invoked from the fix-review skill's step 9 (Produce structured
  output) and referenced by agents/fix.md and fix-history-rewrite.
---

# Fix Result Contract

The fix agent's only channel back to the post-script is
`$FULLSEND_OUTPUT_DIR/agent-result.json`. This skill is the single
canonical owner of that contract: what the file must contain, how it is
validated, what to do when validation fails, and how fields survive a
validation retry. Every other fix-agent skill that touches structured
output points here instead of restating the rules.

## Produce structured output

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

**Schema** (`schemas/fix-result.schema.json`): `additionalProperties: false`.
Use only schema-defined fields — e.g. optional `rebased_onto_target`,
`merged_target`, `conflict_update`, and `history_rewritten` (see
"Validation retry behavior" below and the `fix-history-rewrite` skill)
and `ci_inspections` (`fix-ci-inspection` skill; each entry requires
`job` and `classification`, with `status`/`diagnosis`/`remediation`
optional — see the forge-specific `fix-review` skill for the recipes
that gather these). `trigger_source` is `"bot"`/`"human"`. Action types:
`fix` (needs `type`, `finding`, `description`) or `disagree` (needs
`type`, `finding`, `reason`). Required top-level fields: `pr_number`,
`trigger_source`, `actions` (≥1), `summary`, `tests_passed`,
`files_changed`.

## Propose PR/MR metadata

Optional `pr_title` and `pr_body` let the post-script replace the PR/MR
title or description. Set a field only when the current value is
materially inaccurate. That covers a changed file scope or approach,
superseded behavior descriptions, and stale results such as test counts,
whether this run or an earlier fix caused it. It also covers a human
`/fs-fix` instruction or a review finding that asks for it. Do not set
either field for cosmetic rewording. Omit any field that is still
accurate. The post-script leaves an omitted field unchanged.

- `pr_title`: single line, at most 200 characters. Keep the repo's
  title convention (for example the Conventional Commits type and scope
  already in the title).
- `pr_body`: at most 8000 characters, Markdown. Write the full
  replacement description, not a diff. Leave out the issue-closing line
  (`Closes #N`, `Related to …`) and the `### Post-script verification`
  section. The post-script keeps the existing ones and drops any copies
  in your text. Do not add closing references to other issues. Close
  every code fence and HTML comment you open: a body that could hide the
  appended sections is not applied.
- Each proposed field needs the SHA-256 of the exact current value you
  based it on: `pr_title_base_sha256` or `pr_body_base_sha256`. Hash
  the value as returned by the forge, with no trailing newline added. If
  the live value has changed by the time the post-script runs (for
  example a human edited it), that field is skipped with a warning.

```bash
# GitHub
gh pr view "${PR_NUMBER}" --json title,body > /tmp/pr-meta.json
# GitLab: save the MR JSON from the fix-review recipe to /tmp/pr-meta.json,
# then use '.description // ""' instead of '.body // ""' below.
jq -j '.title' /tmp/pr-meta.json | sha256sum | cut -d' ' -f1
jq -j '.body // ""' /tmp/pr-meta.json | sha256sum | cut -d' ' -f1
```

A metadata-only run (no code change) still needs at least one `actions`
entry. Record a `fix` action whose `finding` names the stale metadata.

The post-script applies the fields only after the output passes schema
validation and its secret scan. The outcome appears in the PR summary
comment. A failed update never fails the run. Like every other field,
these are public text: do not copy untrusted log or review content into
them verbatim.

Validate before exiting:

```bash
fullsend-check-output "${FULLSEND_OUTPUT_DIR}/agent-result.json"
```

If validation fails, read the error output, fix the JSON file, and
re-run the check. If it still fails after 3 attempts, write the best
JSON you have and exit.

## Failure handling

Secret scanning is **non-negotiable**. The `scan-secrets` helper runs
before tests on every verification pass. If secrets are detected — or if
the helper script is missing — hard stop. Do not improvise a replacement
or skip the scan.

Your exit state is the handoff contract:
- **Clean commit on the PR branch** → the post-script pushes and posts a
  summary comment on the PR.
- **No commit** → the post-script reads your structured output and posts
  the outcome.

## Partial work

If a token limit is reached before every finding is addressed: commit
the partial work, and document which findings were addressed and which
remain in `actions`. Use a `disagree`-style entry or the `summary` field
to call out remaining work — the schema has no dedicated "partial" flag,
so the `summary` must say so explicitly.

## Validation retry behavior

Distinct from `FIX_ITERATION`, which counts runs of the review→fix loop.
This is a retry *within a single run*: when the harness `validation_loop`
has `feedback_mode: append` and an iteration fails validation, the runner
relaunches the agent with the failure text appended to its prompt. The
agent is on such a retry if its prompt contains this exact sentence after
the default instructions:

> The previous iteration's output failed validation. Here is the validation error:

On a validation retry:

- The agent is in the **same sandbox** as the previous iteration. Its
  branch is still checked out and any commits it made are still on it —
  there is nothing to restore, and no feedback file to read.
- The failure text in the prompt is the only feedback given, and it is
  redacted and truncated. Today it reports structured-output schema
  violations, so the usual fix is to correct `agent-result.json`.
- Capture `AGENT_START=$(date +%s)` before anything else if the
  `fix-verification` skill's time checks rely on it — a validation retry
  does not re-enter the `fix-review` skill's opening steps, and an unset
  value makes the budget look exhausted.
- The runner clears the output directory between iterations, so
  `agent-result.json` must be written again this iteration even if the
  failure was elsewhere.
- Fix only the reported failure. Do not redo the fix work already done —
  re-applying it on top of existing commits produces duplicate or
  conflicting changes. The `fix-review` skill's "follow these steps in
  order" applies to a first iteration; on a validation retry, correcting
  the reported failure is the whole job.
- If a prior iteration in this run set `rebased_onto_target: true` (see
  "How to rebase" in the `fix-history-rewrite` skill) and that rebase's
  result still needs publishing, carry the field forward into this
  iteration's `agent-result.json` even though no `git rebase` is
  re-run. The runner clears the output directory between iterations, so
  a rewritten `agent-result.json` that drops the field is
  indistinguishable from a run that never rebased — the post-script
  fails closed and replays local commits onto the stale remote PR tip,
  silently undoing the rebase.
- If a prior iteration in this run set `merged_target: true` or wrote a
  `conflict_update` object (see "Reconcile forge-reported merge
  conflicts" in `agents/fix.md`) and that reconciliation still needs
  publishing, carry those fields forward the same way. Dropping
  `merged_target` makes the post-script replay onto the remote PR tip
  and drop the merge commit.
- If a prior iteration in this run set `history_rewritten: true` (see
  "Rewrite fix-agent history" in the `fix-history-rewrite` skill) and
  that squash/reset still needs publishing, carry the field forward the
  same way. Dropping it makes the post-script replay local commits onto
  the pre-rewrite remote PR tip and silently undo the squash or reset.
- If a prior iteration in this run proposed `pr_title` or `pr_body` (see
  "Propose PR/MR metadata" above), carry those fields and their
  `pr_title_base_sha256` / `pr_body_base_sha256` forward unchanged.
  Dropping them silently discards the metadata update. Do not recompute
  the base hashes from a re-read. The hashes must describe the value the
  proposal was based on.

## Constraints

`agents/fix.md` is authoritative for prohibitions. On conflict, the
agent definition wins.
