# Testing Agent Changes Locally

This guide covers how to test agent changes in this repo on your local
machine. For general background on running agents locally, see
[Running agents locally](https://fullsend.sh/docs/guides/user/running-agents-locally.html).

## Prerequisites

- **fullsend** CLI on your `PATH`
- **gh** CLI authenticated (`gh auth status`)
- **openshell** and **openshell-gateway** installed
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

Export the variables the agent needs:

```bash
export GITHUB_ISSUE_URL="https://github.com/your-org/test-repo/issues/25"
export GH_TOKEN="$(gh auth token)"

# GCP/Vertex AI credentials — required by most agents via
# common/env/gcp-vertex.env and the host_files GOOGLE_APPLICATION_CREDENTIALS
# mount in harness YAML.
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/your/service-account-key.json"
export ANTHROPIC_VERTEX_PROJECT_ID="your-gcp-project-id"
export GOOGLE_CLOUD_PROJECT="your-gcp-project-id"
export CLOUD_ML_REGION="us-east5"
```

If you're testing a new env var, export it here too. You can also use
`--env-file` with a dotenv file if you prefer.

### 2. Run the agent

```bash
fullsend run triage \
  --fullsend-dir . \
  --target-repo .
```

- `--fullsend-dir .` tells fullsend to use this repo's harness files.
- `--target-repo .` points at a local repo checkout for the agent to
  work against.
- Add `--no-post-script` to inspect the agent's output without
  applying GitHub mutations (posting comments, applying labels). For
  features that change post-script behavior, you'll want to run
  without this flag — just point at a test issue where you don't mind
  making changes.

For agents that need additional variables (e.g., the code agent needs
`ISSUE_NUMBER`, `REPO_FULL_NAME`, and `PUSH_TOKEN`), export them
before running.

### 3. Inspect the output

The agent writes its result JSON to the output directory printed by
`fullsend run`. Check it to verify your new configuration option
produced the expected output:

```bash
cat /tmp/fullsend/agent-triage-*/iteration-*/output/agent-result.json | jq .
```

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
  --target-repo .

# New behavior (var set)
export TRIAGE_AUTO_CODE=off
fullsend run triage \
  --fullsend-dir . \
  --target-repo .
```

## Functional eval tests

The `eval/` directory contains functional test scenarios that run agents
against ephemeral GitHub repos and score the results. See
[eval/README.md](eval/README.md) for setup and usage.

To run triage evals:

```bash
EVAL_ORG=my-org ./eval/run-functional.sh triage
```

Eval tests are expensive (they consume model tokens and create real
GitHub repos). Use them when you need to verify end-to-end behavior
for a significant change, not for every iteration.
