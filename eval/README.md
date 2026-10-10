# Eval Harness

Functional tests for fullsend agents. Each agent has its own eval
directory (`triage/`, `review/`, `code/`, `fix/`, `retro/`) containing
an `eval.yaml` config and a `cases/` directory with test case
definitions.

## Running evals

```bash
EVAL_ORG=my-org ./eval/run-functional.sh triage
EVAL_ORG=my-org ./eval/run-functional.sh review
```

Replace the agent name (`review`, `triage`, etc.) as needed. The
script runs three phases:

1. **Create workspaces** — sets up case directories
2. **Execute** — creates ephemeral GitHub repos, runs the agent against
   each test case, and tears down the repos
3. **Score** — evaluates agent output using LLM judges and deterministic
   checks defined in `eval.yaml`

Results are written to `eval/runs/<agent>/<run-id>/`.

### Tiers

`EVAL_TIER` selects how many cases run and what gates the result:

- **`full`** (default) — runs every case in `cases/`, as described above.
  This is what local runs, merge-queue runs, the nightly run and PRs with
  the `eval-full` label use.
- **`release`** — runs only this agent's case(s) whose `annotations.yaml`
  sets `release: true`. If the agent has no `release: true` case, the
  script prints a notice and exits 0.

Both tiers gate on the same things: a non-zero case exit (including a
sandbox, provider or harness that would not load) and the deterministic
contract judges `pr_created`, `new_commit` and `sandbox_started`. The
other judges run and are reported, but don't fail the run:

- LLM quality judges (name ends in `_quality`, e.g. `review_quality`,
  `triage_quality`)
- live-model behaviour checks: `finding_expectations`, `required_labels`,
  `forbidden_labels`, `risk_label_present`, `expected_files`
- the `max_turns`/`max_cost` budget judges

Their thresholds stay in each `eval.yaml`; `run-functional.sh` drops
them from the runtime copy of the config only. Review has no
`max_turns` judge, because its turn count does not track the work done.

If `EVAL_TIER` is unset, it defaults to `release` when running as a
cross-repo `workflow_call` under GitHub Actions (`GITHUB_ACTIONS=true` and
`GITHUB_REPOSITORY` set to something other than `fullsend-ai/agents`) —
this is how the fullsend release gate calls into this repo's functional
tests — and to `full` otherwise. Setting `EVAL_TIER` explicitly always
wins over the default.

```bash
EVAL_ORG=my-org EVAL_TIER=release ./eval/run-functional.sh review
```

In CI (`.github/workflows/functional-tests.yml`), each change runs the
full tier once:

| Event | Tier |
|---|---|
| Pull request | `release`. With the `eval-full` label, `full`, from the next push or `ok-to-test` run (adding the label alone starts no run). |
| Merge queue | `full`, on the commit that lands |
| Nightly (`functional-tests-nightly.yml`) | `full`, every agent, report-only |
| Manual dispatch, cross-repo `workflow_call` | the `tier` input, or the script default |

There is no run on push to `main`: the merge queue already tested that
commit.

### Linting cases

Validate that all test cases have the required annotations before
running:

```bash
bash eval/lint-cases.sh <agent>
bash eval/lint-measurements.sh
```

## Prerequisites

- **agent-eval-harness** — `pip install -e eval/.agent-eval-harness`
- **fullsend** — must be on `PATH`
- **openshell** — must be on `PATH`
- **yq**, **jq**, **gh**, **git**, **uuidgen** — used by setup/teardown hooks

### Harness submodule

The eval harness scripts live in `eval/.agent-eval-harness`. Initialize
the submodule before running:

```bash
git submodule sync eval/.agent-eval-harness
git submodule update --init eval/.agent-eval-harness
```

### GCP credentials

A GCP service account with Vertex AI access is required for model
calls during both execution and scoring.

## Environment variables

### Required

| Variable | Description |
|----------|-------------|
| `GH_TOKEN` | GitHub PAT used by all eval scripts. See [required scopes](#required-token-scopes) below. Falls back to `gh auth token` if unset. In GitHub Actions, this is populated from the `EVAL_GH_TOKEN` repository secret. |
| `EVAL_ORG` | GitHub org or user where ephemeral repos are created (e.g. `my-test-org`). |

### Optional

| Variable | Description |
|----------|-------------|
| `FULLSEND_DIR` | Path to the fullsend scaffold directory. Defaults to the repo root. |
| `EVAL_TIMEOUT` | Runner timeout in seconds. Defaults to `1800` (30 min). |
| `EVAL_RUNTIME` | Run every case under this runtime (`claude` or `pi`) via `fullsend run --runtime`, instead of the workspace config. |
| `EVAL_MODEL` | Model override for every case (alias, id or `provider/id`, e.g. `google-vertex/gemini-2.5-flash`) via `fullsend run --model`. |
| `EVAL_EFFORT` | Effort override via `fullsend run --effort`. |
| `EVAL_TIER` | `full` or `release` — see [Tiers](#tiers) above. Defaults to `release` under a cross-repo Actions `workflow_call`, `full` otherwise. |
| `GOOGLE_APPLICATION_CREDENTIALS` | GCP service account key file for Vertex AI. |
| `ANTHROPIC_VERTEX_PROJECT_ID` | GCP project ID for Anthropic Vertex. |
| `GOOGLE_CLOUD_PROJECT` | GCP project ID. |
| `CLOUD_ML_REGION` | GCP region for Cloud ML. |
| `AGENT_EVAL_HARNESS_DIR` | Path to the agent-eval-harness checkout. Defaults to `eval/.agent-eval-harness`. |

### Derived (set automatically by the runner)

The runner script (`run-fullsend.sh`) derives these from `GH_TOKEN` and
passes them to the agent under test:

| Variable | Source | Purpose |
|----------|--------|---------|
| `PUSH_TOKEN` | `GH_TOKEN` | Push access for the agent's feature branch. |
| `REVIEW_TOKEN` | `GH_TOKEN` | Identity token for posting review comments. See [#245](https://github.com/fullsend-ai/agents/issues/245) for plans to use a separate identity. |

## Required token scopes

`GH_TOKEN` must be a PAT (classic) with the following scopes:

| Scope | Script | Operation |
|-------|--------|-----------|
| `repo` | `setup-fixture.sh` | `gh repo create`, `git clone`, `git push` |
| `repo` | `run-fullsend.sh` | `git clone` the ephemeral repo |
| `repo` | `capture-fixture.sh` | `gh issue view`, `gh pr view` |
| `delete_repo` | `teardown-fixture.sh` | `gh repo delete` |

The `repo` scope grants full control of repositories, which includes
the ability to create PRs and post comments during the agent run.

## Test case structure

Each case directory under `eval/<agent>/cases/` contains:

- `input.yaml` — fixture definition (forge, fixture type, title, body,
  PR files). Issue cases may set `labels`, applied before the agent runs
  (e.g. `ready-to-code` for a code case). Pull-request cases may add
  `followup_files` and a `prior_review` body/provenance to exercise a
  re-review. Each PR file is written ending with exactly one final
  newline, whatever block style its `content` uses.
- `annotations.yaml` — expected outcomes (labels, review expectations)
  and the report-only budgets: `max_cost_usd`, plus `max_turns` where the
  eval has a `max_turns` judge. Set `release: true` to include the case
  in `EVAL_TIER=release` runs (see [Tiers](#tiers) above).
- `repo/` (optional) — base repo contents pushed to main before the
  fixture is created

Every file, endpoint, symbol and label that a case's issue or PR refers
to must exist in its fixture repo (`repo/`, plus the PR's files) or in
the fixture's `labels`. The expected outcome in `annotations.yaml` must
be what a careful engineer would conclude from that repo alone: an agent
that checks the code and finds a gap will rightly answer `needs-info`.
When a case needs code that the shared fixture repo lacks, give the case
its own repo under `eval/<agent>/repos/` rather than changing the shared
one (e.g. triage cases 001 and 003).

## Lifecycle

Each test case follows this lifecycle:

1. **`setup-fixture.sh`** — creates an ephemeral GitHub repo under
   `EVAL_ORG`, pushes test content, and creates the fixture (issue or PR).
2. **`run-fullsend.sh`** — clones the ephemeral repo and runs the agent
   pipeline against it.
3. **`capture-fixture.sh`** — snapshots the fixture state (labels,
   comments, reviews) into `fixture-state.json` for judges.
4. **`teardown-fixture.sh`** — deletes the ephemeral repo.

## Known issues

- **Self-review 422.** The runner reuses `GH_TOKEN` as `REVIEW_TOKEN`.
  If the token owner is also the PR author, GitHub rejects
  `REQUEST_CHANGES` reviews on your own PR. Use a token from a
  different account or a GitHub App installation token.
  See [#245](https://github.com/fullsend-ai/agents/issues/245).

- **fullsend `UploadFile` bug.** In fullsend v0.31.0, `UploadFile`
  fails when the source filename matches the destination basename.
  See [fullsend-ai/fullsend#5231](https://github.com/fullsend-ai/fullsend/issues/5231).

- **`checkStatus` drops string errors.** fullsend's `checkStatus` does
  not handle string-typed error responses from the GitHub API, causing
  silent failures.

## Measurement manifests (online scoring)

Per-agent manifests under [`eval/measurements/`](./measurements/) are the
**default online-scoring policy** for stock agents (which scorers run after
managed jobs via `fullsend eval-measure`). They are **not** functional PR-gate
scenarios under `eval/<agent>/`.

Scorer *implementations* live in `fullsend-ai/fullsend`; this repo only
declares defaults. Jobs fetch these files from `agents@v0` unless a consumer
overrides under `FULLSEND_DIR`. See [`eval/measurements/README.md`](./measurements/README.md)
and [fullsend#6036](https://github.com/fullsend-ai/fullsend/pull/6036) (ADR 0087
lands with that PR).
