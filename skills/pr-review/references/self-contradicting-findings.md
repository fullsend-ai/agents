# Self-contradicting findings

A finding is self-contradicting when its own description or
remediation concedes that the flagged behavior is not a regression
introduced by this PR, follows an established pattern, matches
existing code, or is acceptable, intentional, or correct.

Incidental mentions of "pattern" or "existing" are not a match. The
finding must concede that the flagged behavior itself is acceptable,
pre-existing, or intentional.

## Disposition

1. **No concrete improvement** (empty/absent `remediation`, or text
   that only restates the current state): drop it. Do not mention it
   in the review body.
2. **Concrete improvement despite accepting the current state:** keep
   as `info` / `enhancement-opportunity` with `actionable: false`.
   Leave the suggested improvement in `remediation`.
3. **Genuine defect** that mentions existing patterns only as context
   (without conceding the flagged behavior is fine): leave unchanged.

Linked issue #1051 proposed a third disposition — elevate an
internally contradictory finding for human review during output
generation — that this filter does not implement. Disposition 3 above
is a different, narrower concept: a genuine defect that mentions an
existing pattern only as context is left unchanged, not escalated.
This filter intentionally covers two of the issue's three proposed
dispositions (drop / info-enhancement); it adds no escalation
mechanism.

Skip `protected-path`, `sub-agent-failure`, `provenance-warning`,
`permission-expansion`, `permission-reduction`, `role-escalation`,
`workflow-permission`, and `secret-exposure`. Process findings are not
self-contradicting analysis; human approval is still required for
protected paths. The permission/role/secret-exposure categories are
mandated confirmation findings per `sub-agents/security.md` — e.g., a
permission reduction reported as "info confirming intentionality"
must always be emitted, even when it concedes the change is
acceptable.

After disposition, apply `$REVIEW_FINDING_SEVERITY_THRESHOLD`. An
`info` enhancement below the threshold is omitted from the review
body and the `findings` array.

This filter still runs when the challenger was skipped, so 6e
findings and unchallenged sets are covered.
