# Rebase-only short-circuit

Referenced from `SKILL.md` step 2a-1. Read this file in full before
deciding whether to skip sub-agent dispatch.

When a push rewrites commits without changing the tree (identical file
content to the prior reviewed commit), skip sub-agent dispatch and
reuse the prior review. Parent chain and timestamps change; file
content does not.

## Detection

Use the forge-specific skill's "Tree identity (rebase-only)" commands.
The three-dot compare in step 2a is merge-base-to-HEAD
(`changed_since_prior`). After a same-tree rebase rewrite it lists the
full PR diff, not zero files, so it cannot detect identical content.

## Conditions

Short-circuit only when every condition holds:

1. `PRIOR_REVIEW_SHA` is non-empty.
2. `PRIOR_REVIEW_PROVENANCE` is exactly `app-verified`.
3. `/sandbox/workspace/prior-review.txt` is non-empty.
4. Tree-identity commands succeeded (no 404, no timeout) and printed
   `TREES_IDENTICAL=true`.
5. Base-branch file count is unchanged and trusted:
   - Run the forge-specific skill's "Base-branch file count
     (rebase-only)" commands.
   - `PRIOR_BASE_FILE_COUNT` equals `CURRENT_BASE_FILE_COUNT` from the
     forge-specific Base-branch file count (rebase-only) commands.
   - `PRIOR_BASE_FILE_COUNT` is less than 300 (GitHub's compare
     `files` array truncates at 300; a count of 300 is untrusted).
   - GitHub: `PRIOR_BASE_TOTAL_COMMITS` does not exceed 250.
   - GitLab: `COMPARE_TIMEOUT` is not `true`.
6. The forge-specific skill's "Base ref stability (rebase-only)"
   command reports `BASE_REF_STABLE=true` — the live base ref/target
   branch matches `PRIOR_BASE_REF`, parsed directly from the hidden
   Head SHA comment the prior review persisted (step 7 of `SKILL.md`).
   Tree identity (condition 4) only proves HEAD's content is unchanged
   relative to `PRIOR_REVIEW_SHA` — it says nothing about which base
   the prior review evaluated the diff against. Condition 5's
   file-count check does not fill this gap either: both sides of that
   comparison are computed against the *current* base ref, so identical
   trees make it match trivially regardless of whether a retarget
   happened. A retarget with no new commits would otherwise still pass
   conditions 1-5. Comparing the persisted `PRIOR_BASE_REF` against the
   live base ref closes that gap by direct confirmation rather than by
   inferring stability from the absence of a retarget signal — treat a
   missing `PRIOR_BASE_REF` (prior review predates this field) or a
   mismatch as unverified and fail this condition.

If any condition fails, continue to step 3. Fall-through cases:
force-push or missing SHA (404), provenance not `app-verified`,
different trees (code changed), untrusted or unequal base-branch file
counts, missing or mismatched persisted base ref.

A rebase that drops a fix commit changes the tree, so this path does
not fire. That fall-through is required so a later review can still
see the content regression.

The trivial case `PRIOR_REVIEW_SHA == HEAD_SHA` (a re-trigger on an
already-reviewed commit) is intentionally allowed: it reuses that same
commit's own genuine review, gated by the "This PR was NOT reviewed"
marker check in Result step 2 below, so no new content exists to
review.

## Result

Skip steps 3–6 (no dimension sub-agents, no security-triage, no
risk-assessment, no challenger). Produce the result in step 7:

1. Parse prior findings from the current section of
   `/sandbox/workspace/prior-review.txt` (same extraction as step 2a).
   Treat a finding as `actionable: true` when the prior body includes a
   Remediation line for it. This is an approximation, not a recovery of
   the original `actionable` value: the schema defines `actionable` as
   a judgment call about auto-fixability, not merely whether a
   Remediation line was rendered, so this heuristic can escalate the
   derived verdict to `request-changes` more often than the original
   review would have (e.g. an advisory medium/low finding with
   remediation text that was not originally flagged auto-fixable).
   Accept the approximation — it only ever escalates toward more
   scrutiny, never toward reusing an approval that should not apply.
2. Before deriving a verdict, confirm the current section of
   `/sandbox/workspace/prior-review.txt` does not contain the literal
   string "This PR was NOT reviewed". `agents/review.md`'s failure
   output uses that exact marker and also renders a `## Review` header
   with no parseable findings, so without this check a failure notice
   mistaken for a genuine prior review would parse as zero findings and
   short-circuit to `approve` under step 6f's "no findings" rule. If
   the marker is present, continue to step 3 instead of
   short-circuiting.
3. Derive the verdict from the parsed findings using step 6f. If the
   derived action requires `findings[]` (`request-changes` or
   `reject`) and required finding fields cannot be parsed
   (`severity`, `category`, `file`, `description`), continue to
   step 3 instead of short-circuiting.
4. Compose the body using step 7's format exactly — no custom heading,
   summary prose, or visible SHAs:
   - The hidden Head SHA comment (step 7), using the current HEAD SHA
     and current base ref.
   - If no prior findings were parsed: omit `## Review` and
     `### Findings` entirely; the body is the hidden comment followed
     by "Looks good to me" (step 7's no-findings case).
   - If prior findings exist: standard `## Review` / `### Findings`
     sections with the findings rendered in the step 7 severity format.
5. Fetch the prior risk assessment using the same sticky-comment fetch
   defined in step 3c-2. When `REVIEW_RISK_ASSESSMENT_ENABLED` is true
   and a prior risk comment is found, include its score, level, and
   rationale as `risk_assessment` in the result — the tree is
   unchanged, so the prior score still applies and treating a missing
   field as stale would otherwise strip the PR's risk labels. If the
   env var is false, or no prior risk comment exists, omit
   `risk_assessment` (matches step 3c-2's own failure fallback — its
   absence is not an error).
6. Write the result with `action` (derived verdict), `head_sha`
   (current HEAD SHA), `body` (composed above), `risk_assessment` when
   found (step 5), and `findings` when the action requires them
   (step 7 table).

Do not dispatch sub-agents. Go to step 7.
