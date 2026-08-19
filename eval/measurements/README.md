# Measurement manifests

Per-agent YAML that selects which **eval measurement** scorers run after a
managed agent job (`fullsend eval-measure`). This is **not** the functional
eval harness under `eval/<agent>/` (PR-gate scenarios / fixtures).

## Why this lives next to the agents

These files are the **default online-scoring policy** for the stock fullsend
agents — the same idea as shipping the agents themselves: “here is `code`,
and here is what we measure on wild `code` runs.”

Managed fullsend jobs resolve manifests as:

1. Local `${FULLSEND_DIR}/eval/measurements/${AGENT}.yaml` if present (override / BYOA)
2. Else a SHA-pinned fetch from `fullsend-ai/agents` at the `v0` tag:
   `fullsend eval-measure` resolves `tags/v0` via GitHub `GetRef` and then
   fetches `eval/measurements/${AGENT}.yaml` at that commit. It does **not**
   curl the floating `raw.githubusercontent.com/fullsend-ai/agents/v0/...` URL.
   `agents` is public, so the `GetRef` works without a token on both GitHub
   Actions and GitLab; unauthenticated calls share GitHub's ~60 req/hr per-IP
   limit, so export `GH_TOKEN`/`GITHUB_TOKEN` on busy shared runners (GitHub
   Actions passes `GH_TOKEN` automatically). A local `FULLSEND_DIR` manifest
   skips the fetch entirely.

Installs that only use stock agents **do not copy these files**. Local files
are for changing defaults, opting out, or scoring a custom agent.

Stock manifests in this directory use lowercase ids like `em-001` (an
agents-repo style convention). fullsend's `LoadRegistry` requires a non-empty
`id` and `scorer`, `version >= 1`, and rejects pipe/newline in `id` / `scorer`
/ optional `name`.

## What lives where

| Concern | Repo |
|---|---|
| Scorer **implementations** (Go), parser, CLI, job wiring | [`fullsend-ai/fullsend`](https://github.com/fullsend-ai/fullsend) (`internal/evalmeasure/`) |
| Default manifests (which `id` / `scorer` / `version` per agent) | **This directory** |
| Org/repo overrides and BYOA manifests | Consumer `FULLSEND_DIR` |

Executable logic stays in fullsend because `fullsend eval-measure` is the
released binary that reads `run-telemetry.jsonl` (produced by fullsend). This
repo is content/policy, not that binary. Platform checks like em-001
(`trace_fitness`) still get **enabled** here for each stock agent.

| Change | PR |
|---|---|
| New Go scorer or (future) new declarative `assert:` / thresholds | `fullsend` |
| New measurement id / enable / disable for a stock agent using an existing scorer | **agents** (this repo) |
| Custom policy for one org or a BYOA agent | Local override in the consumer repo |

Companion platform PR: [fullsend-ai/fullsend#6036](https://github.com/fullsend-ai/fullsend/pull/6036)
(ADR 0087 lands with that PR; the `docs/ADRs/0087-*.md` path is not on
`fullsend` main until #6036 merges).

## First ship

Six agents enable `trace_fitness` (em-001): code, fix, prioritize, retro,
review, and triage. Omit a file to leave an agent without defaults (e.g.
scribe has no forge work-item identity today). A file under this directory
only takes effect for agents in fullsend's first-party fetch allow-list
(`defaultAgentsRepoKnownAgents` in `internal/cli/run.go` — currently those
six). Adding a stock manifest for a new agent (or scribe) needs a fullsend
change first; `agents/<name>.md` alone is not enough.

```yaml
agent: code
measurements:
  - id: em-001
    scorer: trace_fitness
    version: 1
```
