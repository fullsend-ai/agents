# History-rewrite procedures

Numbered git steps for rebase, squash, and redo/reset. Activation rules
are in `SKILL.md`. Follow these steps in order when a rewrite is
authorized.

## How to rebase

1. Read the PR/MR base branch from forge metadata (GitHub: `baseRefName`,
   GitLab: `target_branch`). Call it `BASE`.
2. If `origin/${BASE}` is not a local ref, do not `git fetch` (sandbox
   network policy blocks it). Record in structured output that the rebase
   could not run because the base ref is missing, and stop the rebase.
3. If `origin/${BASE}` is already an ancestor of `HEAD`, the branch is up
   to date. Do not rebase. If rebase was the only instruction, produce
   structured output and stop with no new commit.
4. Run `git rebase origin/${BASE}` non-interactively rather than `git rebase -i`.
5. On conflicts: resolve them, `git add` the resolved files, then
   `GIT_EDITOR=true git rebase --continue`. Repeat until the rebase
   finishes. If the rebase cannot be resolved, `git rebase --abort`,
   record the failure in structured output, and stop.
6. Do not push. The post-script force-pushes with `--force-with-lease`.
7. After a successful rebase, further code fixes land as **new commits**
   on the rebased history. Do not amend rebased commits. A rebase-only
   run needs no extra commit — the rewritten commits are the result.
8. Set the top-level `rebased_onto_target: true` field in `agent-result.json`
   whenever this run's HEAD reflects a rebase onto the target that still
   needs to be published on the remote PR — whether from a human-requested
   rebase or a bot-triggered forge-conflict reconciliation with
   `FIX_CONFLICT_UPDATE_STRATEGY=rebase` (see "Reconcile forge-reported
   merge conflicts" in `agents/fix.md`) — not only in the same iteration
   that `git rebase` executes. This is the only signal the post-script
   trusts to skip replaying local commits onto the stale remote PR tip —
   ancestry alone can't tell a real rebase apart from a GitLab MR
   reconstruction against a target that has since moved on.
   Concretely:
   - Set it once step 4 (or the conflict resolution in step 5) finishes
     successfully.
   - Set it on the step-3 no-op too, unconditionally, whether the rebase
     was requested by a human or is a bot-triggered forge-conflict
     reconciliation with `FIX_CONFLICT_UPDATE_STRATEGY=rebase` — the
     rebase's effect still needs publishing even though no `git rebase`
     command ran this iteration (this happens when the sandbox
     reconstructed the branch from the target, e.g. GitLab). Do not try to
     decide this by comparing local HEAD to the real remote PR tip: step 2
     forbids `git fetch`, and on GitLab the local `origin/${BASE}` (and
     `origin/${BRANCH}`) tracking refs are reconstructed, not the real
     remote tip, so that comparison can't be evaluated from inside the
     sandbox. The post-script's own ancestry checks already treat the skip
     as a no-op when the remote PR is already based on the current target,
     so setting `true` here unconditionally never overrides an up-to-date
     remote.
   - On a validation-loop retry that rewrites `agent-result.json` without
     re-running `git rebase` (see "Validation retry behavior" in the
     `fix-result-contract` skill), carry this field forward from the
     iteration that performed (or no-op'd) the rebase if its result
     still needs publishing.
   - Never set this field for a failed/aborted rebase. A bot-triggered
     run may set it only when reconciling a forge-reported conflict with
     `FIX_CONFLICT_UPDATE_STRATEGY=rebase`. The post-script independently
     verifies either a harness-captured human rebase request **or** a
     runner-side forge conflict before trusting a `true` value. A wrong
     `true` here makes the post-script force-push over real remote commits.

A rebase rewrites commit SHAs. Together with squash and redo/reset (see
below), that is an allowed exception to "create a new commit; do not
amend." It does not authorize `git commit --amend` or replacing the
branch for a change of strategy.

Every rebase run (success, no-op, or failure) still writes structured output
with ≥1 `actions` item — a `fix` action whose `finding` records the rebase
and whose `description` records the outcome.

## How to squash

A squash's range is the whole PR, computed fresh each time — it is not
limited to commits authored by this fix agent, and it is not the same
range redo/reset uses (below).

1. Read the PR/MR base branch from forge metadata (GitHub: `baseRefName`,
   GitLab: `target_branch`). Call it `BASE`.
2. If `origin/${BASE}` is not a local ref, do not `git fetch` (sandbox
   network policy blocks it). Record in structured output that the squash
   could not run because the base ref is missing, and stop.
3. `REWRITE_BASE="$(git merge-base HEAD origin/${BASE})"`.
4. If `git rev-list --count ${REWRITE_BASE}..HEAD` is already `1`, the PR
   is already a single commit. Do not rewrite. Record the no-op in
   structured output. Do not set `history_rewritten`. Continue with any
   additional requested code fixes as new commits.
5. Otherwise, produce exactly **one** commit between `REWRITE_BASE` and
   HEAD:
   - Ordinary case: `git reset --soft ${REWRITE_BASE}`, then create one
     new commit whose tree is the previous HEAD tree. Do not use
     `git commit --amend`. Do not use `git reset --hard` here — it
     discards the working tree, not just the commit boundaries.
   - **Manual squash** (fallback): use this when the ordinary case above
     is not practical. The common case is squash combined with rebase,
     where replaying several original commits — possibly from different
     authors, written at different times, against different context —
     onto the new base can produce enough conflicts, spread across enough
     commits, that resolving them one commit at a time is more
     error-prone than just writing the final code directly. When that
     happens: `git reset --hard ${REWRITE_BASE}`, then re-implement the
     PR's net effect as a single new commit with similar code. The result
     does not need to be byte-identical to the pre-squash tree — it needs
     to deliver the same behavior. Because this path rewrites code, not
     just history, re-run the verification in the `fix-review` skill
     (tests, linters, secret scan) against the reimplementation before
     committing, the same as any other fix.
6. Do not push. The post-script force-pushes with `--force-with-lease`.
7. **Commit message**: cover the whole PR, not just its original goal. By
   the time a PR is squashed it has often accumulated changes the
   starting intent didn't anticipate — fixes from review feedback,
   corrections, scope adjustments. The squash commit message must briefly
   describe everything that ended up in the PR: the original goal *and*
   what changed along the way and why. A message that only restates the
   initial intent is incomplete once the code has moved past it.
8. If this run also needs to address other review findings or human
   instructions alongside the squash, fold that work into the single
   squash commit rather than appending it afterward: make the edits
   first, then run the squash mechanics (step 5) once so the one new
   commit's tree already includes them. Do not land same-run work as a
   separate commit on top of the squash — step 9 (and the post-script
   publish gate) requires exactly one commit between `origin/${BASE}` and
   HEAD, so an appended commit either forces you to drop
   `history_rewritten` (silently undoing the squash when the post-script
   rebases onto the pre-squash remote tip) or gets the whole push refused.
   "Further fixes as new commits" only applies to a **later** run, after
   this squash has already been published and a fresh `/fs-fix` starts
   from the single squashed commit.
9. Set the top-level `history_rewritten: true` field in
   `agent-result.json` whenever this run's HEAD reflects a squash that
   still needs to be published on the remote PR — a completed squash
   (mechanical or manual) that leaves exactly one commit between
   `origin/${BASE}` and HEAD, or a validation-loop retry carrying the
   field forward from the iteration that performed it. Never set this
   field for a failed/aborted squash, a no-op (already one commit), or a
   bot-triggered run. The post-script requires this field together with a
   harness-verified human squash request (TRIGGER_SOURCE plus the literal
   `/fs-fix` instruction text) before skipping the replay onto the remote
   PR tip, and additionally refuses to publish unless exactly one commit
   actually results. A wrong `true` here, or a squash that doesn't
   actually collapse to one commit, makes the post-script refuse the push
   rather than silently accept a partial squash.

Every squash run (success, no-op, or failure) still writes structured
output with ≥1 `actions` item — a `fix` action whose `finding` records
the squash and whose `description` records the outcome, including the
rewrite base and how many commits were combined (or why it did not run).

## Authorized rewrite range (redo / reset)

Redo/reset's range is narrower than squash's: the only commits it may
rewrite are the contiguous suffix of commits at HEAD authored by this fix
agent. Commits below that suffix — human-authored or code-agent — are not
in scope for a redo/reset and must be preserved exactly. Identify the
range as follows:

1. Read the PR/MR base branch from forge metadata (GitHub: `baseRefName`,
   GitLab: `target_branch`). Call it `BASE`.
2. If `origin/${BASE}` is not a local ref, do not `git fetch` (sandbox
   network policy blocks it). Record in structured output that the rewrite
   could not run because the base ref is missing, and stop the rewrite.
3. `MERGE_BASE="$(git merge-base HEAD origin/${BASE})"`.
4. Run `scripts/authorized-range.sh origin/${BASE}` from this skill. It
   prints `REWRITE_BASE=<sha>` and `IN_SCOPE=<n>` for the contiguous
   suffix of commits at HEAD authored by this fix agent (the identity
   rule is under "Fail closed" in SKILL.md), or exits non-zero with the
   reason when HEAD is out-of-scope.
5. The rewrite base is the `REWRITE_BASE` printed in step 4. If the
   script exited non-zero, fail closed: record that the authorized range
   could not be determined, and do not rewrite.

Do not rewrite past a human-authored commit. Do not rewrite commits
authored by the code agent (`fullsend-code` or any name other than
`$GIT_AUTHOR_NAME`). Unrelated branch changes stay intact. When ownership
is ambiguous, fail closed and explain the blocker in structured output.

## How to redo / reset

1. Identify the authorized range (above). Let `REWRITE_BASE` be the
   rewrite base.
2. If the range cannot be determined, fail closed as above.
3. `git reset --hard ${REWRITE_BASE}`. This discards the in-scope
   fix-agent commits only. Human-authored commits and code-agent
   commits below `REWRITE_BASE` remain.
4. Re-implement the requested work as **new commit(s)** on top of
   `REWRITE_BASE`. If redo was the only instruction, re-implement the
   previous fix intent from the review body and the rest of the human
   instruction. Do not recreate the discarded commits as-is — the
   point of a redo is a different approach.
5. Do not push. The post-script force-pushes with `--force-with-lease`.
6. Set `history_rewritten: true` in `agent-result.json` whenever this
   run's HEAD reflects an authorized reset that still needs publishing
   (same carry-forward rules as squash). Never set it for a
   failed/aborted reset or a bot-triggered run.

Every redo run (success or failure) still writes structured output with
≥1 `actions` item — a `fix` action whose `finding` records the redo and
whose `description` records the outcome, including the rewrite base and
that human-authored commits were preserved (or why the rewrite did not
run).
