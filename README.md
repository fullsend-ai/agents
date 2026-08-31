# fullsend agents

First-class agents for the [fullsend](https://github.com/fullsend-ai/fullsend) platform. These agents automate the software development lifecycle on GitHub, GitLab, and Jira Cloud — from issue triage through code implementation, review, fix, prioritization, and retrospective analysis.

## Agents

| Agent | Description | Trigger | Runtimes |
|-------|-------------|---------|----------|
| **Triage** | Assesses issue sufficiency, searches for duplicates, applies control labels | New issues, `/fs-triage` | claude, pi |
| **Code** | Implements fixes and features following repo conventions | `ready-to-code` label, `/fs-code` | claude, pi |
| **Review** | Dispatches parallel sub-agents across six review dimensions | PR events, `/fs-review` | claude, pi (single-context) |
| **Fix** | Implements targeted fixes from review feedback | Review comments, `/fs-fix` | claude, pi |
| **Prioritize** | Scores issues using the RICE framework | Schedule, `/fs-prioritize` | claude, pi |
| **Retro** | Analyzes completed workflows and proposes improvements | PR close, `/fs-retro` | claude, pi (single-context) |
| **Scribe** | Maps meeting notes to issue backlog updates and new issues | Schedule | claude, pi |

Claude Code (`claude`) is the stable default every repo gets; `pi` is in its enablement (experimental) phase and is selected per repo with `runtime: pi` — see fullsend's [Runtimes](https://github.com/fullsend-ai/fullsend/blob/main/docs/runtimes.md). Every harness sets `effort: high` explicitly.

See [`docs/`](docs/) for detailed documentation on each agent.

## Repository structure

```
agents/      Agent system prompts (one per agent)
docs/        User-facing documentation
harness/     Harness configurations (sandbox image, timeout, scripts, plugins)
profiles/    Network endpoint and binary allowlist definitions (portable, local-path)
providers/   Provider bindings mapping profile types to credentials
policies/    Shared sandbox base policy (filesystem, landlock, process — no network rules)
env/         Shared environment snippets (GCP Vertex AI auth, SSL CA workaround)
schemas/     JSON Schema for validating agent structured output
scripts/     Pre-scripts (input validation) and post-scripts (forge mutations)
skills/      Reusable skill definitions loaded by agents at runtime
plugins/     Sandbox plugins (e.g. gopls LSP for the code agent)
eval/        Functional eval harness and default online-scoring manifests
```

## Architecture

Agents run inside sandboxed containers with strict filesystem, network, and binary restrictions. Each agent follows a three-phase pipeline:

1. **Pre-script** — runs on the CI runner to validate inputs and prepare the environment
2. **Sandbox** — runs the agent with restricted permissions; the agent writes code and produces structured JSON output
3. **Post-script** — runs on the runner with elevated permissions to perform forge mutations (pushing branches, creating PRs/MRs, posting comments, applying labels)

The agent never has direct write access to the repository. All mutations flow through post-scripts.

## Testing

Run all agent shell script test suites from the repo root:

```bash
make test
```

This is an alias for `make script-test`, which runs the `scripts/*-test.sh` suites. CI also runs `make check-bundle` and executes `make script-test` twice (source and bundled modes) via `.github/workflows/script-test.yml`.

## Script bundling

Harness fetches each runner script as an isolated blob, so post-scripts cannot `source` files from `scripts/lib/` at runtime. Scripts that use shared libraries are maintained as source files and bundled before commit:

| Kind | Path | Edit? |
|------|------|-------|
| Library | `scripts/lib/*.lib.sh` | Yes — functions only, no side effects |
| Source | `scripts/*.src.sh` | Yes — editable script with `source` calls |
| Bundled | `scripts/*.sh` (from `.src.sh`) | No — generated; referenced by harness |

Bundled scripts are self-contained — child harnesses that override `post_script` must provide their own self-contained script or bundling setup. A custom post-script that tries to `source` a base lib at runtime will fail because the harness only fetches the single script blob.

After editing a `.src.sh` or `.lib.sh` file:

```bash
make script-build      # regenerate bundled .sh files
make check-bundle      # verify committed bundles are current
```

Commit source and bundled files together. Test bundled scripts locally with:

```bash
make script-test SCRIPT_TEST_TARGET=bundled
```

Library tests source `.lib.sh` directly. Script tests honor `SCRIPT_TEST_TARGET` (`source` by default, `bundled` in CI's second pass).

To add a new post-script, create `scripts/my-agent.src.sh` with `source` calls to libs under `scripts/lib/`, add it to `BUNDLE_SRCS` in the `Makefile`, run `make script-build`, and commit both `.src.sh` and `.sh` together. To add a new shared library, create `scripts/lib/my-thing.lib.sh` with an include guard (`[[ -n "${MY_THING_SH_LOADED:-}" ]] && return 0`), then `source` it from the relevant `.src.sh` and rebuild.
## Versioning

This repository is versioned in lockstep with [fullsend](https://github.com/fullsend-ai/fullsend). Tags are pushed by fullsend's release workflow after a successful release — they are not created here directly. The `v0` floating tag always points to the latest stable (non-prerelease) version.

## Workflows

| File | Managed by | Purpose |
|------|-----------|---------|
| `fullsend.yaml` | fullsend (centrally managed) | Routes GitHub events to agent dispatch workflows |
| `release.yml` | This repo | Creates GitHub Releases and moves the `v0` tag on version tag push |
| `notify-agent-sync.yml` | This repo | Dispatches `agents-updated` event to `.fullsend` for cross-repo digest sync (manual trigger only) |
| `script-test.yml` | This repo | Runs agent shell script tests on PRs and main branch pushes |
