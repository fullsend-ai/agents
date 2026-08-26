# Testing Agent Changes Locally

This guide covers how to test agent changes in this repo on your local
machine. For general background on running agents locally, see
[Running agents locally](https://fullsend.sh/docs/guides/user/running-agents-locally.html).

## Prerequisites

- **fullsend** CLI on your `PATH`
- **gh** CLI authenticated (`gh auth status`)
- **openshell** and **openshell-gateway** installed, matching the version
  fullsend pins in
  [`openshell-version.sh`](https://github.com/fullsend-ai/fullsend/blob/main/.github/scripts/openshell-version.sh)
  (currently 0.0.83) — an older version (e.g. the Homebrew tap's 0.0.73)
  can fail the sandbox pre-flight with an opaque `GitHub API unreachable
  from sandbox` error
- **podman** installed
- A test repo with issues you can point agents at (e.g.,
  `your-org/test-repo`)

For installation of openshell and fullsend, see
[Running agents locally](https://fullsend.sh/docs/guides/user/running-agents-locally.html).

## Starting the sandbox infrastructure

Before running an agent, you need the podman socket (or podman machine
on macOS) and the openshell gateway running. See
[Running agents locally](https://fullsend.sh/docs/guides/user/running-agents-locally.html)
for platform-specific setup instructions covering both Linux and macOS.

## Running an agent with `fullsend run`

The simplest way to test is to run the agent directly against a real
GitHub issue.

### 1. Set environment variables

Export the variables the agent needs. The issue URL and token vars
depend on which forge you're testing against:

**GitHub:**

```bash
# GitHub:
export GITHUB_ISSUE_URL="https://github.com/your-org/test-repo/issues/25"
export GH_TOKEN="$(gh auth token)"
export FULLSEND_FORGE="github"
```

**GitLab:**

```bash
export GITLAB_ISSUE_URL="https://gitlab.com/your-group/test-project/-/issues/25"
export GITLAB_TOKEN="glpat-xxxxxxxxxxxxxxxxxxxx"
export FULLSEND_FORGE="gitlab"
```

**Common (both forges):**

```bash
# GCP/Vertex AI credentials — required by most agents via
# common/env/gcp-vertex.env and the host_files GOOGLE_APPLICATION_CREDENTIALS
# mount in harness YAML.
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/your/service-account-key.json"
export ANTHROPIC_VERTEX_PROJECT_ID="your-gcp-project-id"
export GOOGLE_CLOUD_PROJECT="your-gcp-project-id"
export CLOUD_ML_REGION="global"
```

If you're testing a new env var, export it here too. You can also use
`--env-file` with a dotenv file if you prefer.

### 2. Clone the target repo

The issue URL above points at an issue in a separate repo (e.g.
`your-org/test-repo`) — clone it to its own local path so `--target-repo`
has real content to work against. The harness maps `GITHUB_ISSUE_URL`,
`GITLAB_ISSUE_URL`, or `FULLSEND_WORK_ITEM_URL` to a generic `ISSUE_URL` via the
per-forge env file (`env/github/*.env`, `env/gitlab/*.env`, or
`env/jira/triage.env`):

```bash
git clone git@github.com:your-org/test-repo /tmp/target-repo
```

### 3. Run the agent

```bash
fullsend run triage \
  --fullsend-dir . \
  --target-repo /tmp/target-repo \
  --output-dir /tmp/fullsend
```

- `--fullsend-dir .` tells fullsend to use this repo's harness files.
- `--target-repo` points at the target repo checkout (from step 2) for
  the agent to work against. Don't point it at `.` — that's this
  harness repo, not the repo the issue lives in.
- `--output-dir /tmp/fullsend` pins the output location so the `cat`
  command in step 4 works as written. Without it, fullsend defaults to
  Go's `os.TempDir()/fullsend`, which is `/tmp/fullsend` on Linux but
  `$TMPDIR/fullsend` (something like
  `/var/folders/.../T/fullsend/`) on macOS.
- Add `--no-post-script` to inspect the agent's output without
  applying GitHub mutations (posting comments, applying labels). For
  features that change post-script behavior, you'll want to run
  without this flag — just point at a test issue where you don't mind
  making changes.

Some agents need additional variables beyond the ones above — check the
target agent's `harness/<agent>.yaml` (top-level `runner_env`, `env:
runner:`, and `forge.<forge>.runner_env`) for what it expects, and
export those before running.

### 4. Inspect the output

The agent writes its result JSON to the output directory printed by
`fullsend run`. Check it to verify your new configuration option
produced the expected output:

```bash
cat /tmp/fullsend/agent-triage-*/iteration-*/output/agent-result.json | jq .
```

## Testing triage with Jira

Triage also supports Jira Cloud as a forge (see [`docs/triage.md`](docs/triage.md#jira-setup)).
Set `FULLSEND_FORGE=jira` instead of `github`/`gitlab`, along with the
Jira-specific env vars — `forge.jira` resolves natively with the current
runner, no override workaround needed:

```bash
export FULLSEND_WORK_ITEM_URL="https://your-site.atlassian.net/browse/TESTPROJ-42"
export JIRA_USER_EMAIL="you@example.com"
export JIRA_TOKEN="your-jira-api-token"
export JIRA_BASE_URL="https://your-site.atlassian.net"
export FULLSEND_FORGE="jira"

# Transition names for closing issues — set to match your Jira workflow.
export JIRA_DUPLICATE_TRANSITION="Duplicate"
export JIRA_NOT_PLANNED_TRANSITION="Won't Do"
export JIRA_SPLIT_TRANSITION="Done"
```

Run `fullsend run triage` the same way as step 3 above — `--target-repo`
should still point at a local checkout of the codebase the Jira issue
concerns, since triage reads repository context (docs, existing issues,
PRs) regardless of which forge hosts the issue itself.

## Testing a new configuration option

When testing a new env var, verify both cases:

1. **Unset** — run without the var and confirm the default behavior is
   preserved.
2. **Set** — run with the var set to each valid value and confirm the
   new behavior works.

Example testing a hypothetical `TRIAGE_AUTO_CODE` var:

```bash
# Default behavior (var unset)
fullsend run triage \
  --fullsend-dir . \
  --target-repo /tmp/target-repo \
  --output-dir /tmp/fullsend

# New behavior (var set)
export TRIAGE_AUTO_CODE=off
fullsend run triage \
  --fullsend-dir . \
  --target-repo /tmp/target-repo \
  --output-dir /tmp/fullsend
```

## Functional eval tests

The `eval/` directory contains functional test scenarios that run agents
against ephemeral GitHub repos and score the results, plus default
online-scoring manifests under [`eval/measurements/`](eval/measurements/README.md)
consumed by `fullsend eval-measure`. See [eval/README.md](eval/README.md)
for setup and usage.

To run triage evals:

```bash
EVAL_ORG=my-org ./eval/run-functional.sh triage

# Same cases under pi, or on another model — one variable each
EVAL_ORG=my-org EVAL_RUNTIME=pi ./eval/run-functional.sh triage
EVAL_ORG=my-org EVAL_MODEL=google-vertex/gemini-2.5-flash EVAL_RUNTIME=pi ./eval/run-functional.sh triage
```

Eval tests are expensive (they consume model tokens and create real
GitHub repos). Use them when you need to verify end-to-end behavior
for a significant change, not for every iteration.

## Runtime and model overrides

When running agents locally with `--fullsend-dir .`, the CLI reads the
root `config.yaml`. To switch from the default Claude Code runtime to
pi, add a `runtime` key:

```yaml
# config.yaml
runtime: pi
```

### Per-run overrides

Flags and environment variables override `config.yaml` values. Precedence
(highest to lowest): **flag > env > config/harness > default**.

**Flags:**

```bash
fullsend run triage \
  --fullsend-dir . \
  --target-repo /tmp/target-repo \
  --runtime pi \
  --model google-vertex/gemini-2.5-flash \
  --effort high
```

**Environment variables:**

| Variable | Description |
|----------|-------------|
| `FULLSEND_RUNTIME` | Runtime to use (`claude` or `pi`) |
| `FULLSEND_MODEL` | Model alias, ID, or `provider/id` (e.g. `google-vertex/gemini-2.5-flash`) |
| `FULLSEND_EFFORT` | Effort level for the run (`low`, `medium`, `high`, `xhigh`, `max`) |
| `FULLSEND_FALLBACK_MODELS` | Comma-separated fallback model list |
| `FULLSEND_PI_MODEL` | Pi-only alias for `FULLSEND_MODEL`, kept for backward compatibility: honoured only when the run is on pi, and only when neither `--model` nor `FULLSEND_MODEL` is set |
| `FULLSEND_PI_PROVIDER` | Pi-only: the provider prefix applied to a *bare* model id (default `anthropic-vertex`); a `provider/id` value passes through unchanged |

In CI, the same variable names work as repository variables. Use plain
names for fleet-wide defaults or role-prefixed names for per-agent
overrides (e.g. `TRIAGE_FULLSEND_MODEL`).

To select Gemini on Vertex AI, run under pi (Claude Code cannot run
non-Anthropic models) and use the model name directly — the same Vertex
credentials exported above (`GOOGLE_APPLICATION_CREDENTIALS`,
`GOOGLE_CLOUD_PROJECT`, `CLOUD_ML_REGION`) are used; fullsend exports
`GOOGLE_CLOUD_LOCATION` from the region for pi's built-in `google-vertex`
provider:

```bash
export FULLSEND_RUNTIME=pi
export FULLSEND_MODEL="google-vertex/gemini-2.5-flash"
```
