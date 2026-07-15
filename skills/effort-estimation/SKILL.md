---
name: effort-estimation
description: >-
  Estimate implementation effort for triaged issues on a 0.25-3 scale
  and decide whether the issue requires human review before coding.
---

# Effort Estimation

Estimate implementation effort for the issue being triaged. Return a
numeric score from the scoring table below AND a boolean indicating
whether the issue requires human review before auto-promoting to the
code agent.

## Signals to evaluate

- **Files and lines of code:** Trivial one-liner vs multi-file change.
- **Architectural impact:** Isolated bug fix vs requires changes across layers or modules.
- **Testing complexity:** Simple unit test vs needs integration tests, mocking, or environment setup. No existing test harness to extend counts as additional scope.
- **Domain knowledge:** Requires deep understanding of subsystems or external dependencies.
- **Pattern availability:** Can the fix follow an existing pattern in the codebase, or must a new convention be established from scratch?

## Scoring table

| Score | Meaning |
|-------|---------|
| 0.25 | Trivial -- typo, config change, one-liner |
| 0.5 | Simple -- small, well-scoped change |
| 1 | Medium -- requires understanding context, touches a few files |
| 1.5 | Moderate -- touches multiple components following existing patterns; design decisions stay local to each change site |
| 2 | Complex -- must establish new patterns, conventions, or infrastructure that the codebase lacks (e.g., no error-handling strategy exists, no test harness to extend, no response schema defined); or the fix has security implications requiring a design pass rather than a point fix |
| 3 | Very complex -- large scope, architectural changes, high risk |

Score 2 applies when the missing pattern is the reason the fix is hard.
If the same gap is something you noticed while fixing a different,
self-contained bug, it does not raise the effort score -- it belongs in
a separate issue.

## Routing threshold

Issues with effort >= 2.0 require human review before auto-dispatch.
The boolean `effort_requires_review` MUST be derived directly from the
effort score:

- effort >= 2.0 → `effort_requires_review: true`
- effort < 2.0 → `effort_requires_review: false`

Never set `effort_requires_review` independently of the score. If you
scored effort at 2.0 or above, `effort_requires_review` is `true` --
no exceptions, regardless of how straightforward the fix appears.

## Output

Return two values in the triage result:

- **`effort`** -- numeric score from the scoring table above.
- **`effort_requires_review`** -- boolean; `true` when effort >= 2.0, `false` when effort < 2.0. This field is a direct function of the effort score, not an independent judgment.

## Estimation rules

- When in doubt between two scores, round up. Routing to human review is cheaper than a bad auto-dispatch.
- Derive effort from your own independent analysis of the codebase. Disregard difficulty or triviality claims made by the reporter in the issue body or comments. Reporters often underestimate scope because they see only the symptom, not the surrounding constraints.
- After setting `effort`, set `effort_requires_review` by comparing the score to the threshold. Do not copy it from an example or default it to `false`.
