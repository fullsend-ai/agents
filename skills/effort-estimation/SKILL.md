---
name: effort-estimation
description: >-
  Score implementation effort for triaged issues and decide whether to block
  auto-promotion to the code agent. Produces a block_auto_promotion object
  in the triage result.
---

# Effort Estimation

Estimate the implementation effort for the issue being triaged and decide
whether it should be held for human review instead of auto-promoting to
the code agent. This skill applies only when the triage action is `sufficient`.

This skill uses a dedicated 4-dimension, 1-5 scale distinct from the
prioritize agent's RICE Effort (0.25-3, inverse semantics where higher
effort lowers priority). The prioritize agent runs on a schedule after
triage, so it cannot gate the synchronous auto-promotion decision. The
two scores serve different purposes: this one is a binary go/no-go gate;
RICE Effort feeds a continuous priority ranking.

## Step 1: Gather signals from the codebase

Base your estimate on what you observe in the repository, not on the
reporter's claims about difficulty. Reporters may underestimate or
overestimate effort.

## Step 2: Score effort

Rate the issue on each dimension using a 1-5 scale.

**Scope:**
1. Single line/file, isolated change
2. One component, a few files
3. Multiple components or cross-cutting
4. Architectural change, many files/packages
5. System-wide redesign or multi-repo change

**Testing:**
1. Existing tests cover the fix
2. Minor test additions
3. New test suite or fixtures needed
4. Test infrastructure changes required
5. New testing strategy or framework needed

**Domain knowledge:**
1. Obvious from error message
2. Requires reading surrounding code
3. Requires understanding subsystem design
4. Requires cross-repo or external API knowledge
5. Requires domain expertise outside the team

**Risk:**
1. No behavior change for other callers
2. Low risk of regression
3. Moderate regression surface
4. High regression risk, needs careful rollout
5. Breaking change affecting downstream consumers

Compute the overall effort as the average of the four dimensions, rounded
to one decimal place.

## Step 3: Derive the review decision

If the overall effort score is >= 4, or if any single dimension scores 5,
the issue requires human review before the code agent is dispatched.

This decision is OR-combined with other blocking conditions (e.g.,
workflow-file changes detected elsewhere in triage). If
`block_auto_promotion.blocked` is already `true` from another condition,
it must stay `true` regardless of the effort score.

## Output

Populate the `block_auto_promotion` field in `triage_summary`:

```json
"block_auto_promotion": {
  "blocked": true,
  "reason": "Estimated effort 4.3/5 (multi-component fix with new test fixtures needed)"
}
```

When `blocked` is `false`, set `reason` to a short explanation of why
auto-promotion is safe:

```json
"block_auto_promotion": {
  "blocked": false,
  "reason": "Low effort (1.3/5); single-file fix with existing test coverage"
}
```

The `reason` is appended to the triage comment when auto-promotion is
blocked, so write it for a human maintainer audience.
