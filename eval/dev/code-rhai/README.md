# code-rhai: feature-scale cases from RHAI epics

Correctness-graded cases for the fullsend code agent (AISDLC-5). The pipeline
guard in [`eval/code/`](../code/) stays untouched; this eval asks whether the
agent's PR actually delivers an epic.

```bash
EVAL_ORG=<user-or-org> ./eval/run-functional.sh dev/code-rhai
```

## What a case is

**The epic is the case.** The agent gets the epic's title and description,
verbatim, as a GitHub issue on a throwaway copy of the target repository, and
is expected to open one PR. Eligible epics have one or more linked PRs, all in
one repository: the PRs tell us which repository to use and show the epic was
achievable there. Nothing from those PRs is shown to the agent or the judge.

**Where the agent starts.** The repository as it was the moment the epic's
first PR was accepted into it (the parent of that PR's merge commit). That is
the code the humans' work was integrated into and tested against. If no linked
PR has merged yet, the current tip of the default branch. The choice and the
reason are recorded per case.

**How the run is graded, with no reference solution.**

Every run ends in one of three outcomes, recorded by the `outcome` judge:
`pr` (the agent opened a PR on an agent/ branch), `declined` (the agent
finished cleanly, opened no PR, and left a message saying why), or `failed`
(nothing usable). A decline is not a failure: whether stopping was right is
judged on its own terms.

1. Deterministic first: the outcome; a PR exists; the repository's own test
   command still passes on the PR head; budgets are reported.
2. For a PR: the fullsend review agent reviews it (findings kept, nothing
   posted), then a tool-using judge (Claude Code runner, Opus 5; it may
   write only its own verdict file)
   scores the PR 1 to 5 against the task's requirements. It works in a
   staged directory holding the task description, the case author's notes,
   the PR description and diff, the repository test result, the review
   agent's findings, and a full checkout of the PR head, so it can read the
   code around the change, its callers and the existing tests.
3. For a decline: a judge with the same tools scores the agent's stated
   reason 1 to 5 against the task, the notes, and the repository exactly as
   the agent saw it (`decline_quality`): were its factual claims true, and
   was stopping reasonable for a competent engineer with no one to ask?
   The PR-quality judge is skipped.

Five samples per judged case for reported numbers, one while testing
plumbing. The fixture is what fullsend production presents: the issue text
verbatim plus the `ready-to-code` label, nothing else. If a runtime or model
stops because the repository's own guidance or the task's gaps tell it to,
that is measured, not worked around.

## Case layout

```
cases/<NNN-slug>/
  input.yaml         the epic: title and description, verbatim
  annotations.yaml   provenance, snapshot, regression command, judge_notes, budgets
  repo/              working tree at the snapshot, no .git, no .github/workflows
                     (git-ignored: rebuilt from annotations.source by
                     eval/scripts/materialize-case.sh; the case dir is a card)
```

`annotations.yaml`:

```yaml
source:
  epic: RHAI-517
  epic_url: https://redhat.atlassian.net/browse/RHAI-517
  epic_summary: ...
  sample: sample.json (generated 2026-09-22T22:44Z)
  repo: trustyai-explainability/nemo-guardrails
  pull_requests:                     # evidence only; never shown to agent or judge
    - https://github.com/trustyai-explainability/nemo-guardrails/pull/69
  snapshot_commit: <sha>
  snapshot_rule: tip of develop at build time; no linked PR has merged yet
  vendored: full tree at the snapshot (N files, M MB); removed: .github/workflows
regression_tests:
  command: "uv sync --locked --group dev && uv run pytest -q -n auto tests"
test_timeout_s: 1800
judge_notes: ""                     # fixture facts only; empty by default (see below)
max_turns: 300
max_cost_usd: 40.00
```

## Building cases

```bash
eval/scripts/sample-to-cases.sh sample.json          # what the sample can yield
eval/scripts/build-case.sh --sample sample.json --epic RHAI-517 \
  --case eval/dev/code-rhai/cases/001-rhai-517-nemo-capability-manifest
# fill regression_tests.command
eval/scripts/check-case.sh eval/dev/code-rhai/cases/001-rhai-517-nemo-capability-manifest
```

`build-case.sh` needs a sample with descriptions (schema_version 4 or later
from the rhai-epics sampler). It refuses epics that span repositories or lack
a description. `check-case.sh` confirms the input is real task text, the regression
command is set and passes on the bare snapshot, and no TODO is left. The
human work per case is the regression command and a glance at the snapshot
choice.

`judge_notes` is almost always empty. It exists for facts about the fixture
that the judge cannot discover on its own, such as a directory deliberately
left out of the snapshot that the task would otherwise touch. It must never
describe the task, the human solution or the human PRs: the task text is the
only specification the judge gets, and anything the task leaves open is for
the judge to treat as open. Earlier drafts of the five cards carried notes
that restated the epic or described the human change; those were removed.

## How a run flows

`before_each`: `setup-fixture.sh` materializes `repo/` from the card if it is
missing, creates the throwaway repo from it and
opens the epic as an issue. Runner: `run-fullsend.sh` runs the code agent,
whose post-script opens the PR. `after_each`, in order:

1. `capture-fixture.sh` records issue and PR state.
2. `capture-pr-artifacts.sh` writes `output/` (JSON for the check judges) and
   `judge/` (plain text for the agent judge: `task.md`, `notes.md`, `pr.md`,
   `diff.patch`, `tests.md`, and `pr-head/`, a full checkout of the PR head
   without `.git`), and runs the regression command on the PR head on this
   machine, so the toolchain must be installed here. Containerising the
   test run is a later step.
3. `run-review-agent.sh` runs `fullsend run review` on the PR with the
   post-script disabled and keeps `agent-result.json` as
   `output/review-result.json`, rendered as `judge/review.md`, plus the
   review run's cost and the agents repo commit, so the review agent version
   is on record.
4. `teardown-fixture.sh` deletes the throwaway repo.

The check judges read `output/`; the agent judge gets `judge/` staged into
its working directory. The review findings are evidence for the judge,
not a verdict; the judge prompt says so. Because the review agent is itself
under evaluation (AISDLC-24), compare judge scores with and without the
review input on the first few cases, and keep the recorded version.

## Model pin, arms and matrix runs

`harness/code.yaml` says `model: opus`, an alias that Claude Code resolves to
Opus 5 where the Vertex project serves it and to Opus 4.6 where it does not
(the fleet projects, as of 2026-09-21). `models.skill` pins the baseline id;
`runner.command` carries the harness `{model}`/`{effort}` placeholders, which
`run-fullsend.sh` turns into `fullsend run --model/--effort`, so the production
harness file is untouched.

Each coder model is an arm. `matrix.factors.model` lists the arms (today
`claude-opus-4-6`, the fleet's code agent as it runs, and `openai/gpt-6-luna`
as the cheaper comparison); the cases, the review step and the judges are the
same for every arm. `run-fullsend.sh` picks the runtime from the model id,
provider-prefixed ids such as `openai/...` on pi and bare Anthropic ids on
Claude Code, unless `EVAL_RUNTIME` is set. A plain `run-functional.sh dev/code-rhai`
runs the baseline arm; `EVAL_MODEL=openai/gpt-6-luna` runs the other; a matrix
run through `eval-anova` runs them all. `EVAL_REVIEW_MODEL` overrides the
review step's model; `EVAL_SKIP_REVIEW=1` skips it.

Repeated trials and comparisons use the harness's `eval-anova` and
`eval-compare` skills (agent-eval-harness 1.49 or later; the submodule here is
1.22, so point `AGENT_EVAL_HARNESS_DIR` at a newer checkout). `--dry-run`
prints the grid and a cost bound without executing.

## Local run notes

`EVAL_CASES="001-rhai-517-nemo-capability-manifest 004-rhai-369-konflux-data-registry"`
(whitespace-separated case directory names) limits a run to those cases: the
workspace, the retry of pre-agent failures and the final per-case check all
use the same list.

For a macOS host: `TMPDIR=/tmp`; a `GOOS=linux` fullsend build in
`EVAL_SANDBOX_BINARY`; `--forge github` is passed by `run-fullsend.sh`. CI is
unaffected.
