# Eval Harness

Functional tests for fullsend agents. Each agent has its own eval
directory (`triage/`, `review/`, `code/`) containing an `eval.yaml`
config and a `cases/` directory with test case definitions.

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

### Linting cases

Validate that all test cases have the required annotations before
running:

```bash
bash eval/lint-cases.sh <agent>
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
  PR files)
- `annotations.yaml` — expected outcomes (labels, review expectations,
  `max_turns`, `max_cost_usd`)
- `repo/` (optional) — base repo contents pushed to main before the
  fixture is created

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
