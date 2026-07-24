# Explore Agent

Inspects a work item (GitHub issue or Jira ticket), gathers technical context from the target codebase, referenced repos, related work, and public web sources, then produces a structured exploration result for downstream agents.

## How the agent works

The explore agent runs after a work item enters the refinement pipeline. A host pre-script fetches issue context and optionally shallow-clones public GitHub repos referenced in the issue. The agent researches inside a sandbox with read-only GitHub/Jira/web access, writes a schema-validated JSON result, and a post-script attaches the result, posts a sticky summary comment, and optionally applies pipeline labels.

Credentials (Jira tokens, GitHub tokens) stay on the runner — they never enter the sandbox.

## How it helps

- Downstream agents receive structured technical landscape, related work, and definition gaps instead of raw issue text.
- Referenced repos are pre-cloned so the agent can grep and inspect code without live git credentials in the sandbox.
- Confidence scoring and optional pipeline labels signal when a work item is ready for the next stage.

## Platform support

| Source | Pre-script | Post-script |
|--------|------------|-------------|
| GitHub | `gh issue view`, sub-issues | Sticky comment via `fullsend post-comment`, optional labels |
| Jira | REST API + ADF conversion, hierarchy | Attachment + sticky ADF comment, optional labels |

Set `ISSUE_SOURCE` to `jira` or `github`. The agent prompt also accepts `text` and `web` as input source values in the output JSON when the work item did not originate from a tracker.

## Optional pipeline labels

Labels are opt-in via runner env vars — the generic agent does not hardcode team-specific label names:

| Env var | Purpose |
|---------|---------|
| `EXPLORE_READY_LABEL` | Applied when confidence ≥ threshold |
| `EXPLORE_NEEDS_INFO_LABEL` | Applied when confidence < threshold |
| `EXPLORE_CONFIDENCE_THRESHOLD` | Minimum confidence for ready label (default: 50) |

GitHub labels must already exist in the repo; the post-script will not auto-create them.

## Configuration and extension

Register the agent via harness `base:` composition. Downstream configs (e.g. team refinement hubs) add skills and env overrides:

```yaml
base: https://raw.githubusercontent.com/fullsend-ai/agents/main/harness/explore.yaml
skills:
  - skills/jira-routing   # team-specific
env:
  runner:
    EXPLORE_READY_LABEL: ready-to-refine
    EXPLORE_NEEDS_INFO_LABEL: needs-info
```

Built-in skills: `public-research`, `jira-read`.

## Output

The agent writes `agent-result.json` validated against `schemas/explore-result.schema.json`. The post-script copies it to `exploration_context.json` and attaches it to Jira issues for re-runs.
