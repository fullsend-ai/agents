---
name: retro-filing-policy
description: >-
  Define which retro proposals are worth filing as GitHub issues. Produces
  a filing_decision object on each proposal in the retro result.
---

# Retro Filing Policy

Evaluate each candidate proposal and decide whether it should be filed as
a GitHub issue. This skill applies after you have generated candidate
proposals and before you write the final `agent-result.json`.

## Step 1: Screen each candidate

For each candidate proposal, check it against these criteria:

**File the proposal when ALL of the following hold:**

1. The proposal describes a concrete, actionable change (not an
   observation or a restatement of what happened).
2. No open issue in the target repo already covers the same change
   (the `retro-analysis` skill's duplicate-check step handles this).
3. The proposal targets a permitted repo (not a `.fullsend` repo
   unless explicitly justified; see `agents/retro.md` target repo
   restrictions).
4. The proposal does not match a suppressed category (see below).

**Do NOT file the proposal when ANY of the following hold:**

1. The proposal is evidence for an existing issue rather than a new
   improvement. Titles matching "Evidence for #N", "Evidence of #N",
   "Evidence:", or "Additional evidence" are evidence-for proposals.
   Fold their content into the `summary` field instead.
2. The proposal only suggests adding tests or documentation without
   identifying a behavior change.
3. The proposal restates the issue that triggered the retro without
   adding new analysis.
4. The candidate has low confidence -- you are speculating rather than
   drawing from observed evidence in logs, traces, or review comments.

## Step 2: Assign a filing decision

For each proposal in the `proposals` array, populate the
`filing_decision` field:

When the proposal should be filed:

```json
"filing_decision": {
  "file": true,
  "reason": "Actionable change to review prompt; no existing issue covers this"
}
```

When the proposal should NOT be filed:

```json
"filing_decision": {
  "file": false,
  "reason": "Evidence-for pattern — corroborates existing issue #1234"
}
```

The `reason` is included in the summary comment when the proposal is
not filed, so write it for a human maintainer audience.

## Customization

Users can override this skill with a repo-level or org-level skill of
the same name to adjust the filing criteria. For example, a team might:

- Raise the confidence bar ("only file proposals backed by two or more
  independent observations")
- Suppress specific categories ("do not file documentation-only
  proposals")
- Restrict target repos ("only file proposals in the source repo,
  never upstream")

When absent, the retro agent falls back to filing all proposals
(current behavior).
