---
description: Reference for the agents fullsend ships and how to register custom agents — resolved at runtime from the fullsend-ai/agents repository or your repository-local config.
---

# Agents

Reference documentation for the default agents shipped by fullsend.
The default agents are defined in this repository
([`fullsend-ai/agents`](https://github.com/fullsend-ai/agents))
and resolved at runtime via config entries or agents-repo fallback.
Custom agents can be registered via the `agents:` field in the repository-local
`.fullsend/config.yaml`.

| Agent | Summary |
|-------|---------|
| [Triage](triage.md) | Inspects new issues and produces structured triage decisions |
| [Prioritize](prioritize.md) | Scores issues using the RICE framework for project board ranking |
| [Code](code.md) | Implements fixes and features from triaged issues |
| [Review](review.md) | Reviews pull requests for correctness, security, and intent alignment |
| [Fix](fix.md) | Addresses review feedback on open PRs |
| [Retro](retro.md) | Analyzes completed workflows and proposes system improvements |
| [Scribe](scribe.md) | Maps meeting notes to issue backlog updates and new issues |

### Guides

| Guide | Summary |
|-------|---------|
| [Behaviour testing](behaviour-testing.md) | Live behaviour test suite for agents |
| [Custom network policy](network-policy.md) | Configure sandbox network access for hosts beyond the default allowlist |

## Configuration

All agents can be configured by adding instructions and skills to your
repository. Changes to `AGENTS.md` affect every agent; skills let you tune how
a specific agent performs a specific task. See
[Configuring with AGENTS.md](https://fullsend.sh/docs/guides/user/customizing-with-agents-md) and
[Configuring with Skills](https://fullsend.sh/docs/guides/user/customizing-with-skills).

At some point, enough configuration turns a configured default agent into a
derived agent. See
[Default, derived, and custom agents](https://fullsend.sh/docs/guides/user/default-vs-custom)
for where that line is and why it matters.

## Custom Agents

Custom agents can be added to the fullsend pipeline via the `agents:` field in
the target repository's `.fullsend/config.yaml`, optionally layered over
`.fullsend/config.base.yaml`. Each entry is either a local path
(relative to the fullsend directory) or a pinned HTTPS URL with an integrity
hash. Config entries are looked up directly by name; when absent, a runtime
fallback resolves known first-party agents from `fullsend-ai/agents`.
See [Bring Your Own Agent](https://fullsend.sh/docs/guides/user/bring-your-own-agent)
for the complete guide to building and registering custom agents.

For configuration, customization, and building your own agents, see the
[fullsend docs](https://fullsend.sh/docs). To build one, run
[`fullsend agent new`](https://github.com/fullsend-ai/fullsend/blob/main/docs/cli/agent.md#agent-new)
and then follow the [`authoring-custom-agents`](../skills/authoring-custom-agents/SKILL.md)
skill to complete the generated prompt; [`examples/link-check/`](../examples/link-check/)
is a finished one.
