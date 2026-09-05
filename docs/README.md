# Agents

Reference documentation for the default agents shipped by fullsend.

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
| [Custom network policy](network-policy.md) | Configure sandbox network access for hosts beyond the default allowlist |

For configuration, customization, and building your own agents, see the
[fullsend docs](https://fullsend.sh/docs). To build one, run
[`fullsend agent new`](https://github.com/fullsend-ai/fullsend/blob/main/docs/cli/agent.md#agent-new)
and then follow the [`authoring-custom-agents`](../skills/authoring-custom-agents/SKILL.md)
skill to complete the generated prompt; [`examples/link-check/`](../examples/link-check/)
is a finished one.
