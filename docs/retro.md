# Retro Agent

![Retro agent icon](icons/retro.png)

Performs retrospectives on agent workflows — analyzes what happened, identifies improvement opportunities, and proposes changes as GitHub issues.

## How it helps

- Every workflow gets a post-mortem, not just the ones that failed badly enough for someone to notice.
- Improvement proposals are filed as issues with context, so they enter the normal triage/prioritize pipeline.
- Patterns across multiple retros surface systemic issues (e.g., a skill that consistently underperforms).

## Triggers

The retro agent runs automatically when a PR is closed (merged or not).

It can also be triggered manually with the `/fs-retro` command.

## Commands

| Command | Where | Effect |
|---------|-------|--------|
| `/fs-retro` | PR or issue comment | Triggers a retrospective analysis |

Requires write-level repository permission (admin, maintain, or write).

The `/fs-retro` command accepts optional free-text instructions after the
command. The text is passed to the agent as high-signal direction about what
to focus on:

- `/fs-retro` — general retrospective on the workflow
- `/fs-retro figure out why the review agent approved this and make sure it never happens again`
- `/fs-retro the code agent spent 30 minutes on a 2-line fix, what went wrong`

## Control labels

| Label | Meaning |
|-------|---------|
| `ready-for-triage` | Applied to proposal issues so they enter the [triage](triage.md) pipeline automatically. |

## Configuration

See [Customizing with AGENTS.md](https://fullsend.sh/docs/guides/user/customizing-with-agents-md) and
[Customizing with Skills](https://fullsend.sh/docs/guides/user/customizing-with-skills).

### Variables

None.

## How the agent works

The retro agent reconstructs the full workflow graph — [triage](triage.md), [code](code.md), [review](review.md), [fix](fix.md), and human interactions — by fetching issue and PR timelines, agent run logs, and review threads.

1. **Pre-script** gathers metadata about the originating PR or issue.
2. **Sandbox** — the agent reads the full workflow history, identifies patterns (wasted cycles, missed context, repeated failures), and writes structured proposals. It uses the retro-analysis and finding-agent-runs skills. The agent cannot write files or edit code in the target repo.
3. **Validation loop** — output is checked against a schema, with up to 2 retries.
4. **Post-script** creates GitHub issues from the agent's proposals. Proposals whose titles match evidence-for patterns (e.g. "Evidence for #1234: ...") are filtered out and folded into the summary comment as evidence notes instead of being filed as issues.

When triggered via `/fs-retro`, the human's comment is passed to the agent as high-signal direction about what to focus on.

## Source

[`harness/retro.yaml`](../harness/retro.yaml)
