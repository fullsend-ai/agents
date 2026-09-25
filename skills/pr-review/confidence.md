# Review verdict confidence

Read this file from step 6g of `SKILL.md` after the outcome is fixed
(6f). Set optional `confidence` (`high`, `medium`, or `low`) describing
how strongly the evidence and sub-agent agreement support the verdict.
Confidence is advisory: it does not change the action. Omit `confidence`
entirely for the `failure` action.

Downstream graduated-approval work: [`graduated-approval-policy.md`](https://github.com/fullsend-ai/fullsend/blob/main/docs/problems/graduated-approval-policy.md).

## Provenance (`merged_from`)

6b and 6d keep an internal `merged_from` array so 6g can measure
corroboration and severity gaps. Strip it before writing
`agent-result.json` — it is not in the output schema. 6c's
distinct-category findings are not merges; do not attach it there.

**6b.** Attach `merged_from` on **every** same-category merge, not
only when severities disagreed — one entry per input finding:
`{dimension: <category>, severity: <that finding's severity>}`.
Length ≥ 2 is corroboration (two sub-agents agreeing at the same
severity left no marker when this field was disagreement-only).
Distinct `dimension` values distinguish two sub-agents from one
sub-agent citing the same location twice. Carry the field through
6c–6f.

**6d.** Strip `merged_from` before the challenger prompt so 6b's
merge signal cannot influence adjudication (the challenger's output
schema also omits it). After adjudication, copy it back:

- `kept` / `downgraded`: copy from the pre-challenger finding that
  shares category and location.
- `merged`: union the `merged_from` arrays of every pre-challenger
  finding at the same file and overlapping location that is not
  itself a separate `adjudicated_findings` row, and append
  `{dimension: <category>, severity: <severity>}` for each collapsed
  input. If that set is empty, attach
  `merged_from: [{dimension: challenger-merge, severity: <output
  severity>}]` so 6g still sees that a merge happened (length 1, not
  high corroboration) rather than looking like a never-merged finding.

Confidence is two steps that must not be mixed: pick a band from
evidence, then apply action ceilings that can only lower it.

## Step 1 — evidence band

Evaluate only the evidence conditions below, in order: low first, then
medium, then high. Assign the first band whose condition holds. Do not
consider the action (`comment-only`, `reject`, `approve`) in this step.

Read corroboration and severity gaps from `merged_from` on 6b-merged
findings: one entry per input finding, each `{dimension, severity}`.
Two or more entries means more than one input was merged (positive
corroboration even when the dimensions match). A severity gap is the
spread between the lowest and highest `severity` in that array. Treat
`info < low < medium < high < critical`.

**Low** (checked first). Assign if any of:

- The challenger pass failed and you fell back to the pre-challenger
  finding set (a `low`-severity `sub-agent-failure` finding from 6d
  item 4 is present). Dimension sub-agent failures recorded at step 5
  as `info`/`high` `sub-agent-failure` findings are a different event;
  they do not satisfy this bullet. If a dimension failure should
  lower confidence, treat it as its own explicit condition, not this
  one.
- A 6b merge combined findings that disagreed on severity by two or
  more levels, and that finding drives the verdict.
- The verdict rests on a finding the challenger downgraded, or on a
  reconciliation (6e-1) that resolved a direct contradiction between
  sub-agents.
- Required PR context was missing or partial.

**Medium** (checked next). Assign if no low condition holds and any of:

- A 6b merge combined findings that disagreed on severity by exactly
  one level.
- The verdict rests on a single finding with no corroboration from a
  second sub-agent (`merged_from` missing or length 1) and no
  challenger confirmation.

**High** (checked last). Assign only if no low or medium condition
holds and:

- No detected conflict survived synthesis: no `sub-agent-failure`
  finding, no `merged_from` severity disagreement in any 6b merge, and
  no reconciliation contradiction. This is *absence of detected
  conflict*, not positive corroboration. Sub-agents that examined
  disjoint areas do not corroborate each other, so high additionally
  requires that each finding driving the verdict was either raised by
  more than one sub-agent (`merged_from` length ≥ 2) or confirmed by
  the challenger.
- No findings: every **dispatched** dimension sub-agent (not the full
  roster — dispatch is selective, typically 3–6) and the challenger
  returned without error. A deliberately narrow dispatch does not
  itself lower the band.

**Residual.** If no low and no medium condition holds but a high
exclusion applies (for example a two-level `merged_from` gap on a
finding that does not drive the verdict), assign medium. Do not leave
the band unset.

## Step 2 — action ceilings

After step 1, apply these caps. A ceiling may only lower the band; it
never raises it.

- `approve` with no findings: the step-1 band may stay high only when
  every dispatched dimension sub-agent and the challenger returned
  without error; otherwise cap at medium.
- `comment-only`: cap at medium unless **every** driving medium finding
  was raised by more than one sub-agent (`merged_from` length ≥ 2) AND
  survived the challenger unchanged. Only then may a step-1 band of
  high stand. Comment-only may rest on one or more medium findings
  (see 6f); do not treat a single driving finding as the only shape.
- `reject`: cap at medium unless the architectural objection was
  raised independently by more than one sub-agent or explicitly
  confirmed by the challenger. Only then may a step-1 band of high
  stand.

## Provisional boundaries

The one-level and two-level severity-gap splits above are provisional
heuristics, not calibrated thresholds. Per
`graduated-approval-policy.md`, confidence bands should ultimately be
derived from observed review outcomes; treat this rubric as a starting
point pending eval-case calibration.
