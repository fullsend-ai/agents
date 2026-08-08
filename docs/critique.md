# Critique Agent

Adversarial reviewer and quality gate for refinement plans. Evaluates a proposed decomposition from the refine agent and decides: approve (ready for issue creation), revise (send back to refine), or needs_input (escalate to a human for clarification).

> **Note**: The explore and refine agents are added in separate PRs. Cross-references to their docs pages will resolve once all three PRs merge.

## How the agent works

The critique agent runs after the refine agent has produced a decomposition plan. It reads the original work item, exploration context, the proposed plan, and any prior critique history (for revision rounds). It evaluates the plan across seven dimensions — coverage, granularity, dependency coherence, implementability, scope accuracy, assumption grounding, and description clarity — and produces a structured verdict.

The agent runs in a read-only sandbox. It cannot modify issues or create children directly — those mutations are performed by the post-script on the runner. The sandbox policy permits read-only egress to GitHub and Jira APIs plus inference endpoints, but the agent's only output is a structured JSON critique result consumed by the post-script, which posts a summary comment, attaches feedback, and applies labels to signal the next pipeline step.

## How it helps

- Prevents over-decomposition (15 issues when 6 would suffice) and under-decomposition (one giant epic).
- Catches scope creep — children that exceed what the parent asked for.
- Validates that acceptance criteria are testable, not vague ("should be fast").
- Detects assumption laundering — plans that look confident but are built on unverified guesses.
- Creates child issues automatically on approval when `AUTO_CREATE=true`.

## Commands

| Command | Where | Effect |
|---------|-------|--------|
| `/fs-create` | Issue comment | Creates child issues from an approved plan |
| `/fs-refine` | Issue comment | Restarts the refinement pipeline |

## Pipeline integration

The critique agent is the third stage of a three-stage refinement pipeline:

1. **Explore** — gathers technical context
2. **Refine** — decomposes the work item
3. **Critique** — reviews and approves/revises the decomposition (this agent)

### Verdict outcomes

| Verdict | Post-script action |
|---------|-------------------|
| `approved` + `AUTO_CREATE=true` | Creates child issues immediately via `create-children.sh` |
| `approved` + `AUTO_CREATE=false` | Posts approval, adds `refine-approved` label for human gate |
| `revise` + under round limit | Posts feedback, adds `ready-to-refine` label for revision |
| `revise` + at round limit | Escalates to human, adds `refine-needs-human` and `refine-escalated` labels |
| `needs_input` | Posts question, adds `refine-needs-input` label |

## Control labels

These labels are managed by the critique pipeline:

| Label | Meaning |
|-------|---------|
| `refine-approved` | Plan approved; ready for human review or auto-creation |
| `ready-to-refine` | Revisions requested; refine agent should re-run |
| `refine-revision-round-N` | Tracks which revision round the pipeline is on |
| `refine-needs-input` | Human must answer a question before proceeding |
| `refine-needs-human` | Max review rounds reached; human decision needed |
| `refine-escalated` | Distinguishes max-rounds escalation from genuine approval |

## Child issue creation

When the critique agent approves a plan and `AUTO_CREATE=true`, the post-script sources `create-children.sh` to create child issues. This script:

- Creates issues in topological order (parents before children)
- Supports both GitHub (sub-issues API) and Jira (parent-child hierarchy with fallback to "Relates" links)
- Deduplicates against existing children to prevent double-creation on re-runs
- Resolves Jira issue types against the project's available types
- Handles cross-project creation when a routing skill provides `target_project`

## Source

[`harness/critique.yaml`](../harness/critique.yaml)
