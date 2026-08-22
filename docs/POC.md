# POC: measured test plans — codecov → `ready-tests` → QualityFlow → review

Status: proof of concept, 2026-08-18. Nothing here is on `main` yet.

## The problem

Agent PRs *claim* tests; nothing *measures* them. On the last 40 fullsend PRs,
90% of test-plan checkboxes were `[x]`, codecov posted a patch number on almost
every one, and 0 of 88 agent reviews read it. PR #6285 shipped with 6/6 boxes
ticked and `codecov/patch` at 28% against an 80% target. The 80% gate in
`AGENTS.md` did not hold because prose gates are advisory; a data path is not.

## The loop

```
codecov/patch check_run (head SHA)
        │ conclusion=failure               conclusion=success
        ▼                                          ▼
check-run-ready-label.yml            check-run-ready-label.yml
  add label `ready-tests`               remove label + comment
        │
        ▼  (label bridge: check_run never reaches CEL, labels do)
.fullsend/harness/qualityflow-ready-tests.yaml
  trigger: label_changed && name == "ready-tests" && action == "added"
        │
        ▼
QualityFlow (COVERAGE_MODE=auto)
  reads codecov via `gh api .../check-runs`, "measured overrides static":
  STP gets a coverage-gap report, test-generator targets uncovered file:lines,
  commits tests to the PR branch
        │
        ▼
pr-review (this branch)
  step 2c fetches `codecov/*` check-runs for HEAD_SHA → `coverage` in the
  correctness context package; claim < measurement → `test-inadequate` (medium)
code-implementation (this branch)
  pr_body Testing section names the command that ran and the printed coverage;
  no checkbox claims; unrun = `not measured`
```

Each hop is one boring mechanism (a check run, a label, a CEL expression, one
`gh api` call) so every step is observable in the PR timeline.

## Where each piece lives

| Hop | Repo / branch | What |
|-----|---------------|------|
| check_run → label | fullsend core `feat/checkrun-ready-label` | `check-run-ready-label.yml`: on `check_run` completed with name `codecov/*`, add/remove `ready-tests` (labels must start with `ready-`), plus a `check_run` shape in normevent |
| label → agent | `.fullsend` `feat/qf-ready-tests-trigger` | `harness/qualityflow-ready-tests.yaml` (`base:` = pinned QF harness, own CEL trigger) registered in `config.yaml`; per-org `dispatch.yml` mirrors it until the org leaves per-org mode |
| agent plans at the gap | QualityFlow engine `feat/coverage-gap-mode` (PR #1); `qualityflow-fullsend` `feat/coverage-gap-mode` | scenario-builder rule "measured overrides static", STP coverage-gap report, `COVERAGE_MODE: "auto"` |
| review reads the number | this repo, this branch | `skills/pr-review/SKILL.md` §2c, `sub-agents/correctness.md`, `skills/code-implementation/SKILL.md` |

## What this branch changes (agents)

- `skills/code-implementation/SKILL.md`: the Testing section of `pr_body`
  reports what step 9c ran (`go test ./internal/harness/... — 47 passed`),
  the coverage number only if the repo's test command already prints one,
  and `not measured` for anything not run. Checkbox claims are banned.
- `skills/pr-review/SKILL.md`: new step 2c — one `gh api
  repos/$REPO/commits/$HEAD_SHA/check-runs` call filtered to `codecov*`;
  result (or `no coverage signal`) is passed as `coverage` to `correctness`.
- `skills/pr-review/sub-agents/correctness.md`: body claims tested + patch
  below target → `test-inadequate`, medium, quoting both sides. No signal is
  neither a finding nor a pass.

No new tokens: the codecov call is a single REST request with the token the
review already has.

## Try it

```bash
# 1. the number the review will see (any PR head)
gh api "repos/fullsend-ai/fullsend/commits/<HEAD_SHA>/check-runs?per_page=100" \
  --jq '[.check_runs[] | select(.name|startswith("codecov")) | {name,conclusion,summary:.output.summary}]'

# 2. the routing decision, offline (fullsend built from main, .fullsend checkout)
fullsend dispatch --input-driver json --output-driver json \
  --config-dir ~/Desktop/dot-fullsend \
  --input-file <normevent with transition.label.name=ready-tests>
# → [{"agent":"qualityflow-ready-tests","role":"coder",...}]

# 3. label a non-fork PR `ready-tests` in an enrolled repo and watch dispatch → QualityFlow
```

## Not in this POC

- Codecov flags / coverport runtime coverage feeding tier-classifier (phase 2).
- Removing the `/fs-plan-tests` slash command — it stays; the label is additive.
- Model routing per event — harness overlays cannot pick a model; use two
  harnesses if a cheaper QF pass is wanted.
