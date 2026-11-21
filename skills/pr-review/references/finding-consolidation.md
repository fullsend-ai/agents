# Consolidating agreeing authorization findings

Required procedure for step 6e-1 of the review orchestrator. Run it
after the contradiction check in 6e-1.

When a PR modifies protected paths and has no linked issue, the
protected-path rule (6e, "Insufficient context") raises a high
`protected-path` finding, and the intent-coherence sub-agent
independently raises a `missing-authorization` finding for the same
reason. The two findings usually land on different files at different
severities, so 6b does not merge them, and 6e-1's contradiction check
does not apply because the findings agree. The author then sees one
remediation ("link an issue") split across two findings.

1. If the combined set contains a `protected-path` finding whose
   premise is that no linked issue or authorizing decision exists,
   and one or more `missing-authorization` findings whose premise is
   also the absence of a linked issue or authorizing decision, merge
   each such `missing-authorization` finding into the single
   `protected-path` finding, except one that carries an open prior
   `id` (see step 2):
   - Keep `category: "protected-path"`, its file anchor, and the
     higher severity (the protected-path rule's **high**).
   - Fold any extra context from the authorization finding into the
     `protected-path` description (e.g., "introduces a new
     user-facing control with no recorded design discussion").
   - Emit one remediation: link or open an issue authorizing the
     change.
   - Preserve `actionable: true` if either finding had it.
   - Remove the merged `missing-authorization` finding from the set.

2. Keep an authorization finding separate when it covers something
   the `protected-path` finding does not:
   - Its premise is not the absence of authorization — e.g., the PR
     links an issue but the change exceeds that issue's scope
     (`scope-exceeded`, `unauthorized-change`, `scope-creep`).
   - It flags unauthorized changes outside the protected paths that
     linking an authorizing issue would not resolve.
   - It carries an open prior-finding `id` (status absent, `open`, or
     `reclassified` in `prior-review.txt`; see `references/re-review.md`).
     The post-script does not carry `protected-path` ids in the
     prior-finding ledger, so removing the finding would leave its id open
     with no visible finding. Leave it as a separate finding with its id,
     and answer it with the usual `dispositions` entry.

3. Do not consolidate when there is no `protected-path` finding (the
   `missing-authorization` finding stays as reported), or when the
   `protected-path` finding was raised with sufficient context or
   downgraded to info by the contradiction check — those do not
   share the missing-authorization premise.
