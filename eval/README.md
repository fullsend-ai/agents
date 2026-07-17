# Eval Harness

Functional tests for fullsend agents. Each agent has its own eval
directory (`triage/`, `review/`) containing an `eval.yaml` config and a
`cases/` directory with test case definitions.

## Running evals

```bash
EVAL_ORG=my-org ./eval/run-functional.sh triage
EVAL_ORG=my-org ./eval/run-functional.sh review
```

## Prerequisites

- **agent-eval-harness** — `pip install -e eval/.agent-eval-harness`
- **fullsend** — must be on `PATH`
- **openshell** — must be on `PATH`
- **yq**, **jq**, **gh**, **git**, **uuidgen** — used by setup/teardown hooks

## Environment variables

### Required

| Variable | Description |
|----------|-------------|
| `GH_TOKEN` | GitHub PAT used by all eval scripts. See [required scopes](#required-token-scopes) below. Falls back to `gh auth token` if unset. |
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

The `repo` scope covers read/write access to repositories and also
includes `pull_requests:write` for creating PRs and posting comments
during the agent run.

## Lifecycle

Each test case follows this lifecycle:

1. **`setup-fixture.sh`** — creates an ephemeral GitHub repo under
   `EVAL_ORG`, pushes test content, and creates the fixture (issue or PR).
2. **`run-fullsend.sh`** — clones the ephemeral repo and runs the agent
   pipeline against it.
3. **`capture-fixture.sh`** — snapshots the fixture state (labels,
   comments, reviews) into `fixture-state.json` for judges.
4. **`teardown-fixture.sh`** — deletes the ephemeral repo.
