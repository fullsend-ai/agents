# fullsend agents

First-class agents for the [fullsend](https://github.com/fullsend-ai/fullsend) platform. These agents automate the software development lifecycle on GitHub — from issue triage through code implementation, review, fix, prioritization, and retrospective analysis.

## Agents

| Agent | Description | Trigger |
|-------|-------------|---------|
| **Triage** | Assesses issue sufficiency, searches for duplicates, applies control labels | New issues, `/fs-triage` |
| **Code** | Implements fixes and features following repo conventions | `ready-to-code` label, `/fs-code` |
| **Review** | Dispatches parallel sub-agents across six review dimensions | PR events, `/fs-review` |
| **Fix** | Implements targeted fixes from review feedback | Review comments, `/fs-fix` |
| **Prioritize** | Scores issues using the RICE framework | Schedule, `/fs-prioritize` |
| **Retro** | Analyzes completed workflows and proposes improvements | PR close, `/fs-retro` |

See [`docs/`](docs/) for detailed documentation on each agent.

## Repository structure

```
agents/      Agent system prompts (one per agent)
docs/        User-facing documentation
harness/     Harness configurations (sandbox image, timeout, scripts, plugins)
policies/    Sandbox security policies (filesystem, network, binary restrictions)
env/         Per-agent environment variables
schemas/     JSON Schema for validating agent structured output
scripts/     Pre-scripts (input validation) and post-scripts (GitHub mutations)
skills/      Reusable skill definitions loaded by agents at runtime
plugins/     Sandbox plugins (e.g. gopls LSP for the code agent)
common/      Shared configuration (GCP Vertex AI auth)
```

## Architecture

Agents run inside sandboxed containers with strict filesystem, network, and binary restrictions. Each agent follows a three-phase pipeline:

1. **Pre-script** — runs on the GitHub Actions runner to validate inputs and prepare the environment
2. **Sandbox** — runs the agent with restricted permissions; the agent writes code and produces structured JSON output
3. **Post-script** — runs on the runner with elevated permissions to perform GitHub mutations (pushing branches, creating PRs, posting comments, applying labels)

The agent never has direct write access to the repository. All mutations flow through post-scripts.

## Testing

Run all agent shell script test suites from the repo root:

```bash
make test
```

This is an alias for `make script-test`, which runs the seven `scripts/*-test.sh` suites plus `scripts/resolve-precommit-tools-test.py`. CI runs the same target via `.github/workflows/script-test.yml`.

## Versioning

This repository is versioned in lockstep with [fullsend](https://github.com/fullsend-ai/fullsend). Tags are pushed by fullsend's release workflow after a successful release — they are not created here directly. The `v0` floating tag always points to the latest stable (non-prerelease) version.

## Workflows

| File | Managed by | Purpose |
|------|-----------|---------|
| `fullsend.yaml` | fullsend (centrally managed) | Routes GitHub events to agent dispatch workflows |
| `release.yml` | This repo | Creates GitHub Releases and moves the `v0` tag on version tag push |
| `script-test.yml` | This repo | Runs agent shell script tests on PRs and main branch pushes |
