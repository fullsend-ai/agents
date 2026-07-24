# Platform Context: GitHub Issues

## Work Item Hierarchy

GitHub uses a flat issue model with labels and sub-issues for hierarchy:
- **Issues** — the base unit (no built-in types beyond issue/PR)
- **Labels** — used to indicate level/type (feature, epic, story, task, bug, spike)
- **Sub-issues** — GitHub's native parent-child relationship
- **Milestones** — optional grouping mechanism

**Hierarchy rules:**
- A feature-labeled issue produces: child issues labeled "epic" (parent_title=null) → child issues labeled "story" (parent_title=epic title) → child issues labeled "task" (parent_title=story title)
- An epic-labeled issue produces: child issues labeled "story" (parent_title=null) → child issues labeled "task" (parent_title=story title)
- A story-labeled issue produces: child issues labeled "task" (parent_title=null)
- All hierarchy is expressed via GitHub's sub-issue feature
- Labels differentiate the logical type of each issue

**Important**: GitHub has no type restrictions — any issue can be a child of any other issue. Use labels consistently to communicate intent.

## Decomposition Output

Each child must include:
- `type`: the logical type (used as a label). Common: epic, story, task, spike, bug
- `labels`: additional labels beyond the type label
- `target_platform`: "github" (or omit to inherit parent's platform)
- `target_project` is NOT used for GitHub — all children are created in the same repository as the parent

**Repository targeting**: Children are always created in the same repo as the parent issue. Cross-repo work should be noted in dependencies but not created automatically.

## Description Format

GitHub uses markdown natively. No conversion needed.

**Feature-level descriptions** use a two-tier structure:
- Visible top section (always shown)
- Content after `---` delimiter is rendered as-is (GitHub doesn't have collapsible sections in issue descriptions, but the `---` creates a visual separator). If you want collapsible content, use `<details><summary>Detailed Specification</summary>` HTML.

**Child-level descriptions** can be more concise since GitHub issues are inherently lighter weight.

## Parent-Child Constraints

- Any issue can be a sub-issue of any other issue (no type restrictions)
- Sub-issues are created via GitHub's sub-issues API
- If sub-issue creation fails, the child is still created as a standalone issue in the same repo
- Labels are automatically created if they don't exist
- Always include spikes (label "spike") for high-uncertainty areas
- Always include documentation tasks (label "documentation") for user-facing changes
