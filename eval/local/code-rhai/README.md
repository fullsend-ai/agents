# code-rhai: feature-scale cases from RHAI epics

Correctness-graded cases for the fullsend code agent (AISDLC-5). The pipeline
guard in [`eval/code/`](../code/) stays untouched; this eval asks whether the
agent's PR actually delivers an epic.

```bash
EVAL_ORG=<user-or-org> ./eval/run-functional.sh local/code-rhai
```

That runs the baseline arm on every case. To run selected cases, another
coder model or runtime, or a different review model, see
[Model pin, arms and comparing them](#model-pin-arms-and-comparing-them) and
[Local run notes](#local-run-notes); to add a case, see
[Building cases](#building-cases).

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
judged on its own terms. A failure of the eval's own capture (the fixture
record missing, an unreadable PR reference) is recorded as `failed` with
`infrastructure: true`, whatever the agent's final message said, and leaves
`output/infrastructure-failure.json`, which `run-functional.sh` counts as a
case failure in its result line and exit code (the hook's own exit code is
swallowed by the harness's continue-on-failure hook mode).

1. Deterministic first: the outcome; a PR exists; the repository's own test
   command still passes on the PR head; budgets are reported.
2. For a PR: the fullsend review agent reviews it (findings kept, nothing
   posted), then a tool-using judge (Claude Code runner, Opus 5; it may read and search
   only the staged workspace and write only its verdict directory)
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
  --case eval/local/code-rhai/cases/001-rhai-517-nemo-capability-manifest
# fill regression_tests.command
eval/scripts/check-case.sh eval/local/code-rhai/cases/001-rhai-517-nemo-capability-manifest
```

The Jira key (`source.epic`) is the case's identifier; the tracker URL is not
recorded because it needs a Red Hat login and adds nothing to the key. The
epics used here are in Jira's Public visibility class, readable by Red Hat
partners and customers, and the project agreed at its kickoff that their text
can be part of this external dataset.

`build-case.sh` needs a sample with descriptions (schema_version 4 or later
from the rhai-epics sampler). It refuses epics that span repositories or lack
a description. `check-case.sh` confirms the input is real task text, the regression
command is set and passes on the bare snapshot inside the same sandbox the
eval uses, and no TODO is left. The
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
   without `.git`), and runs the regression command on the PR head inside a
   throwaway OpenShell sandbox (`run-in-sandbox.sh`: the coder's image and
   policy, the credential-free `package-registries` provider as the only
   network, so the PR's own install scripts and tests never see this
   machine's home directory or tokens). The command must therefore work with
   the toolchain in the coder's image, which `check-case.sh` verifies.
3. `run-review-agent.sh` runs `fullsend run review` on the PR, configured
   as production runs it (see [The review step](#the-review-step)), with the
   post-script disabled, and keeps `agent-result.json` as
   `output/review-result.json`, rendered as `judge/review.md`, plus the
   review run's cost, per-model usage and the agents repo commit, so the
   review agent version and the models that actually ran are on record.
4. `teardown-fixture.sh` deletes the throwaway repo.

The check judges read `output/`; the agent judge gets `judge/` staged into
its working directory. The review findings are evidence for the judge,
not a verdict; the judge prompt says so. Because the review agent is itself
under evaluation (AISDLC-24), compare judge scores with and without the
review input on the first few cases, and keep the recorded version.

## The review step

The review agent is a parent plus nine persona sub-agents. The parent reads
the PR, decides which personas the change warrants, dispatches them and
writes the verdict; the personas carry the judgement (the `challenger` is
the only one that may remove or downgrade a finding). There is no single
production configuration: every repository fullsend is installed on sets its
own in `.fullsend/config.yaml`, and they differ (the fullsend repo routes two
more personas to Gemini than the agents repo does; a repo with no entry gets
the harness defaults), and the external repositories the cases come from
have none. The eval's reference is the agents repo's own entry, the repo
that owns the review agent: since 2026-10-06 it runs the parent on the pi
runtime on `sonnet`, with `challenger` on `opus`, `correctness` and
`security` on `openai/gpt-6.1-sol`, `docs-currency` and `style-conventions`
on `google-vertex/gemini-3.8-flash`, and the other personas on their
persona-file tiers (`sonnet`, `haiku`). The aliases there mean Sonnet 5.5
and Opus 5.5.

The eval sets only the parent's runtime and model (`pi`, `sonnet`), so the
review is the same for every arm. Everything else comes from the fullsend
config the eval runs under, the agents repo root `config.yaml`, and that is
where the eval deviates from production:

- The repo root config pins `opus` to Sonnet 5.5 for the repo's evals (a
  cost choice, 2026-10-03) and carries no `subagents` routing, so a run
  that changes nothing gets a Claude-only review with the challenger on
  Sonnet 5.5 and no GPT or Gemini personas.
- On a developer machine whose Vertex project does not serve the 5.5
  generation, the Claude aliases must be pinned one generation back
  (`sonnet: claude-sonnet-5`, `opus: claude-opus-5`) or every persona call
  fails; the production `subagents` block can be added to the eval's review
  entry at the same time, with `OPENAI_API_KEY` in the environment for the
  GPT personas. The local wrapper used for the recorded runs does both.
  Reaching Claude 5.5 on EnMaaS from the pi runtime is not possible on the
  current fullsend build (its gateway route sends a header EnMaaS rejects
  for Claude, and a `models.json` redirect in pi's config is refused).

`output/review-metrics.json` `per_model_usage` is the record of what ran: a
persona whose model the project cannot serve shows there as requests with
zero tokens. Runs before 2026-10-14 carried exactly that failure; their
review evidence was a parent-only review, and their write-ups say so.

## Model pin, arms and comparing them

`harness/code.yaml` says `model: opus`, an alias that Claude Code resolves to
Opus 5 where the Vertex project serves it and to Opus 4.6 where it does not
(the fleet projects, as of 2026-09-21). `models.skill` pins the baseline id;
`runner.command` carries the harness `{model}`/`{effort}` placeholders, which
`run-fullsend.sh` turns into `fullsend run --model/--effort`, so the production
harness file is untouched.

Each coder model is an arm; the cases, the review step and the judges are the
same for every arm. The one supported way to run an arm is one
`run-functional.sh` invocation: a plain `run-functional.sh local/code-rhai`
runs the baseline pinned in `models.skill`, and `EVAL_MODEL=<model id>` runs
another. `run-fullsend.sh` picks the runtime from the model id,
provider-prefixed ids such as `openai/...` on pi and bare Anthropic ids on
Claude Code, unless `EVAL_RUNTIME` is set. `EVAL_REVIEW_RUNTIME` and
`EVAL_REVIEW_MODEL` override the review parent's runtime and model (see
[The review step](#the-review-step)); `EVAL_SKIP_REVIEW=1` skips it.

Arms are compared after the fact with two harness skills. `eval-anova` in
`--analyze-only` mode reads the finished runs under `eval/runs/code-rhai/`
(grouping them by the model each run records), fits a repeated-measures
ANOVA over the per-case composite with case as the blocking factor, and
writes `anova.json`; `eval-compare` renders the side-by-side report and
picks up `anova.json` when it is there. Checked on the two five-case reruns
of 2026-10-14/15: F = 2.25, p = 0.21, not significant, as expected at that
size. eval-anova's own executor (`orchestrate.py` without `--analyze-only`,
driven by a `matrix:` block) is not a supported way to run this eval: it
calls the harness scripts directly and skips everything `run-functional.sh`
sets up, so the config declares no `matrix:` block. A fan-out over several
arms is a loop over `run-functional.sh` invocations. The submodule is pinned
to agent-eval-harness v1.56.3, the first release that enforces the judges'
`denied_tools`; `run-functional.sh` refuses to score on anything older or on
a version that is not a plain `N.N.N` release.

## Local run notes

`EVAL_CASES="001-rhai-517-nemo-capability-manifest 004-rhai-369-konflux-data-registry"`
(whitespace-separated case directory names) limits a run to those cases: the
workspace, the retry of pre-agent failures and the final per-case check all
use the same list.

For a macOS host: `TMPDIR=/tmp`; a `GOOS=linux` fullsend build in
`EVAL_SANDBOX_BINARY`; `--forge github` is passed by `run-fullsend.sh`. CI is
unaffected.

The regression sandbox asks for 8 GiB (`EVAL_SANDBOX_MEMORY` overrides it;
the odh-dashboard jest workers were killed under less). `run-in-sandbox.sh`
waits up to `EVAL_SANDBOX_READY_TIMEOUT` (900 s) for the sandbox to be Ready
and records `sandbox_failed` after that; on this Mac a fresh sandbox has been
Ready within a minute, with the coder image cached.

Memory during judging: `judge/` is a declared output so the agent judge can
browse it, and the harness stages declared outputs by reading every file
into memory and writing it back into the judge's workspace, `pr-head/`
included (a full checkout, 110 MB and 11,000 files for odh-dashboard). A
judging pass over the five cases, with two odh-dashboard checkouts, peaked at
678 MB of resident memory (agent-eval-harness 1.56.3, 2026-10-16). That is
fine for a local run; a repository an order of magnitude larger would not
be. Staging by copying instead of through memory is a harness change, not an
eval one, and is on the list to propose upstream.
