# Refine Agent

Decomposes a work item — feature, epic, story, or issue — into implementable child work items with testable acceptance criteria, dependency analysis, and confidence scoring. Always produces a plan, even when information is incomplete.

## How the agent works

The refine agent runs after the explore agent has gathered technical context. It reads the issue description, exploration context (codebase analysis, related work, competitive landscape), and any prior critique feedback. It then decomposes the work item into a hierarchy of child issues sized for engineering teams and sprints.

The agent runs in a read-only sandbox. It cannot modify issues, push code, or create child issues. Its only output is a structured JSON refinement plan consumed by the post-script, which posts a summary comment, attaches the plan to the issue, updates the issue description when the agent proposes a revised one, and adds a `ready-to-critique` label to signal the [critique agent](critique.md).

## How it helps

- Features get decomposed into actionable work items within minutes instead of waiting for a refinement meeting.
- Vague requirements are flagged as open questions with explicit assumptions, preventing silent scope gaps.
- Cross-cutting dependencies are identified early, before teams start implementation in silos.
- Each child issue includes testable acceptance criteria, making "done" unambiguous.

## Commands

| Command | Where | Effect |
|---------|-------|--------|
| `/fs-refine` | Issue comment | Runs refinement on the issue |

The `/fs-refine` command accepts an optional human directive after the command (e.g., `/fs-refine focus on the API layer first`) that guides the agent's decomposition priorities.

## Pipeline integration

The refine agent is part of a three-stage refinement pipeline:

1. **Explore** — gathers technical context from the codebase, GitHub, Jira, and web
2. **Refine** — decomposes the work item into implementable children (this agent)
3. **Critique** — reviews the decomposition and approves, requests revisions, or escalates

> **Note**: The explore and critique agents are added in separate PRs. Cross-references to their docs pages will resolve once all three PRs merge.

Agents communicate through issue labels and attachments. No direct workflow chaining.

### Revision rounds

When the critique agent requests revisions, the refine agent re-runs with the critique feedback. Each round addresses specific revision requests (remove, merge, split, revise, add). The pipeline iterates up to `MAX_REVIEW_ROUNDS` (default: 3) before escalating to a human.

## Control labels

These labels are managed by the refinement pipeline:

| Label | Meaning |
|-------|---------|
| `ready-to-critique` | Refine posted a plan; critique agent should review it |
| `ready-to-refine` | Critique requested revisions; refine should re-run |
| `refine-revision-round-N` | Tracks which revision round the pipeline is on |
| `refine-approved` | Critique approved the plan; ready for human review or auto-creation |
| `refine-needs-input` | Critique determined a human must answer a question before proceeding |
| `refine-needs-human` | Max review rounds reached; human decision needed |

## Platform support

The refine agent supports work items from multiple platforms:

- **GitHub Issues** — uses labels and sub-issues for hierarchy
- **Jira** — uses typed issue hierarchy (Feature → Epic → Story → Task)
- **GitLab** — uses epics, issues, and labels (planned)

Platform-specific hierarchy rules and description formats are injected via `PLATFORM_CONTEXT`.

## Configuration and extension

### Routing skill

To route child issues to different Jira projects based on team ownership, provide a routing skill at `.fullsend/skills/jira-routing/SKILL.md` or `.agents/skills/project-routing/SKILL.md`. The routing skill maps team ownership domains to projects so child issues are created in the right project. Without a routing skill, all children are created in the parent issue's project.

### Platform context

Platform context files (`platform-jira.md`, `platform-github.md`, `platform-gitlab.md`) define the hierarchy model, description format, and parent-child constraints for each platform. The pre-script selects the appropriate one based on `ISSUE_SOURCE`.

## Source

[`harness/refine.yaml`](../harness/refine.yaml)
