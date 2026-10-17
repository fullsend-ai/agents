---
name: fix-history-rewrite
description: >-
  Use when a human /fs-fix instruction asks to rebase, squash, or redo
  fix-agent history, or when a forge-reported merge conflict must be
  rebased with FIX_CONFLICT_UPDATE_STRATEGY=rebase. Human-only squash
  and redo; fail-closed ownership checks; rewrite markers and
  validation-retry carry-forward. Bot-triggered runs never squash or redo.
---

# Fix History Rewrite

Executable rebase, squash, and redo/reset procedure for the fix agent.

Before rewriting history, read and follow every numbered step in
[references/procedure.md](references/procedure.md). The rules in this
file decide whether a rewrite is allowed; the reference is the how-to.
Do not skip it.

## Rebase onto the target branch

A human `/fs-fix` instruction is a **rebase request** when it asks you to
rebase, replay the branch onto its base, or resolve merge conflicts with
the target branch. Examples: `rebase`, `rebase onto main`, `fix merge
conflicts`. Honor a rebase request. Bot-triggered runs are not human
rebase requests; they still reconcile when the forge reports a merge
conflict (see "Reconcile forge-reported merge conflicts" in
`agents/fix.md`) using `FIX_CONFLICT_UPDATE_STRATEGY`.

Do not rebase because the branch is behind. Rebase only for a human
rebase request or a forge-reported merge conflict whose configured
strategy is `rebase`.

Follow **How to rebase** in [references/procedure.md](references/procedure.md).

## Rewrite fix-agent history (squash / redo)

A human `/fs-fix` instruction is a **squash request** when it asks you to
squash, collapse, or combine the commits. Examples: `squash`, `squash
these commits`, `squash the fix commits`. The goal of a squash is a
**single-commit PR**: the whole PR — not just the commits this fix agent
happened to author — collapses into one commit. Squashing is not scoped
to "this fix agent's own work"; do not read it that narrowly.

A human `/fs-fix` instruction is a **redo/reset request** when it asks you
to redo the fix-agent work from scratch or start over. Examples: `redo
from scratch`, `start over`, `start from scratch`, `redo`. A redo/reset is
narrower than a squash: it discards and re-implements only this fix
agent's own contiguous suffix of commits. Commits authored by anyone else
are not part of a redo/reset and stay untouched below the rewrite base.

Honor these requests. Bot-triggered runs are never squash or redo
requests — leave history as-is and address the review findings.

Do not squash or reset because the commit history looks messy. Rewrite
only for an explicit human squash or redo request.

If the instruction asks for both squash and redo, do not guess. Record
in structured output that the request is ambiguous, and stop the rewrite.

Rebase (see above) is a separate rewrite. If the instruction asks for a
rebase and a squash, rebase first, then squash the whole (rebased) PR
range on top of the new target.

Follow **How to squash**, **Authorized rewrite range (redo / reset)**,
and **How to redo / reset** in
[references/procedure.md](references/procedure.md).

## Rewrite markers

Set `rebased_onto_target` and `history_rewritten` as specified in
[references/procedure.md](references/procedure.md). On a validation
retry, carry those fields forward when the rewrite still needs
publishing (see "Validation retry behavior" in the `fix-result-contract`
skill). Never
set them for a failed or aborted rewrite. A bot-triggered run may set
`rebased_onto_target` only when reconciling a forge-reported conflict
with `FIX_CONFLICT_UPDATE_STRATEGY=rebase`. Never set
`history_rewritten` on a bot-triggered run. The post-script
independently verifies a harness-captured human request or a
runner-side forge conflict before trusting a `true` value.

## Fail closed

Redo/reset may rewrite only the contiguous suffix of commits at HEAD
authored by this fix agent (`$GIT_AUTHOR_NAME` and `$GIT_AUTHOR_EMAIL`).
On GitHub a commit the post-script has already published is authored by
the App's bot user (name ending in `[bot]`, email `$GIT_AUTHOR_EMAIL`) and
carries the identity it was committed with in a single `Authored-by: name
<email>` trailer; for such a commit, and only such a commit, that trailer
is its author. `scripts/authorized-range.sh` applies this rule.
If HEAD is out-of-scope, the suffix is empty, or ownership is
ambiguous, do not rewrite. Do not rewrite past a human-authored or
code-agent commit.

Every rewrite run (success, no-op, or failure) still writes structured
output with ≥1 `actions` item — a `fix` action whose `finding` records
the rewrite and whose `description` records the outcome.
