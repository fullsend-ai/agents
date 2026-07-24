# Platform Context: Jira

## Work Item Hierarchy

Jira uses typed issue hierarchy with levels:
- **Feature** (hierarchyLevel 2) — top-level strategic work item
- **Epic** (hierarchyLevel 1) — team-sized deliverable
- **Story** (hierarchyLevel 0) — engineer-sized work
- **Task** (hierarchyLevel 0) — small discrete work item
- **Sub-task** (hierarchyLevel -1) — child of a story/task

**Hierarchy rules:**
- A Feature produces: epics (parent_title=null) → stories (parent_title=epic title) → tasks (parent_title=story title)
- An Epic produces: stories (parent_title=null) → tasks (parent_title=story title)
- A Story produces: tasks (parent_title=null)
- Tasks cannot be direct children of Features in Jira's hierarchy model
- Children must have valid parent_title chains respecting hierarchy levels

**Important**: Check `project.available_issue_types` in the issue context to see which types THIS project actually supports. Only use types that appear in that list. If the project lacks a type (e.g., no "Epic"), use the closest available type and add labels to indicate intent.

## Decomposition Output

Each child must include:
- `type`: matching an available Jira issue type (lowercase). Common: epic, story, task, spike, bug
- `target_project`: (optional, only when PROJECT_ROUTING is set) which Jira project to create in
- `target_platform`: "jira" (or omit to inherit parent's platform)

**Project routing** (if `PROJECT_ROUTING` is set):
- The routing skill maps team ownership domains to Jira projects
- Assign `target_project` by matching a child's scope to a team's domain
- Cross-project hierarchy: Jira cannot enforce parent-child links across projects. The create script handles this by falling back to "Relates" links.
- If `PROJECT_ROUTING` is NOT set: do NOT include `target_project`

**Team conventions**: Check `project.team_usage` in the issue context for the team's type distribution and common labels. Mirror their patterns.

## Description Format

Jira supports rich text via ADF (Atlassian Document Format). Descriptions written in markdown will be converted to ADF automatically.

**Feature-level descriptions** use a two-tier structure:
- Visible top section (always shown in Jira)
- Content after `---` delimiter is wrapped in a collapsible "Detailed Specification" expand section (Jira Cloud) or rendered with a bold heading separator (Jira Data Center)

**Child-level descriptions** (epics, stories) also use the `---` delimiter for the same collapsible behavior.

## Parent-Child Constraints

- Jira enforces issue type hierarchy — a Task cannot be a direct child of a Feature
- When a child's `target_project` differs from its parent's project, the create script skips the parent link and creates it standalone, then adds a "Relates" link
- Within the same project, parent-child links work for: Feature→Epic, Epic→Story, Story→Task, Story→Sub-task
- Always include spikes (type="task", label "spike") for high-uncertainty areas
- Always include documentation tasks for user-facing changes
