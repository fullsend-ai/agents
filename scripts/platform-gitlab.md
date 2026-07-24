# Platform Context: GitLab Issues

> **Note**: GitLab support is planned but not yet fully implemented.
> This template provides the hierarchy model for agent guidance.
> Child issue creation via GitLab API is not yet wired up in create-children.sh.

## Work Item Hierarchy

GitLab uses a multi-level hierarchy:
- **Epics** (group-level) — strategic work items, can contain sub-epics and issues
- **Issues** — the primary work unit at the project level
- **Tasks** — checklist items within issues (lightweight, no separate tracking)
- **Labels** — used for categorization, scoping, and workflow state

**Hierarchy rules:**
- A feature-level epic produces: sub-epics or issues (parent_title=null) → child issues (parent_title=epic/issue title)
- An issue produces: tasks or child issues (parent_title=null)
- Epics live at the group level; issues live at the project level
- Parent-child relationships between issues use the "related issues" feature with "parent/child" type

**Important**: GitLab's hierarchy model varies by tier (Free vs Premium vs Ultimate). Epics require Premium+. Use labels and milestones as fallback grouping for Free tier.

## Decomposition Output

Each child must include:
- `type`: the logical type (used as a label). Common: epic, story, task, spike, bug
- `labels`: additional labels for categorization
- `target_platform`: "gitlab" (or omit to inherit parent's platform)
- `target_project` is NOT used for GitLab — all children are created in the same project/group

## Description Format

GitLab uses markdown natively. No conversion needed.

**Feature-level descriptions** use a two-tier structure:
- Visible top section (always shown)
- Content after `---` delimiter can use `<details><summary>Detailed Specification</summary>` for collapsible content

**Child-level descriptions** should be concise and focused on the specific deliverable.

## Parent-Child Constraints

- Epics can contain sub-epics and issues (Premium+ only)
- Issues can have related issues with parent/child relationship type
- If epic/parent features are unavailable, use labels and milestones for grouping
- Always include spikes (label "spike") for high-uncertainty areas
- Always include documentation tasks (label "documentation") for user-facing changes
