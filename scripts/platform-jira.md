# Platform Context: Jira

Forge background (prefer these over inventing process):

- [What are work types?](https://support.atlassian.com/jira-cloud-administration/docs/what-are-issue-types/)
- [Configure the work type hierarchy](https://support.atlassian.com/jira-cloud-administration/docs/configure-the-issue-type-hierarchy/)
- [Custom hierarchy levels in plans](https://support.atlassian.com/jira-software-cloud/docs/configure-custom-hierarchy-levels-in-advanced-roadmaps/)
- [ADF overview](https://developer.atlassian.com/cloud/jira/platform/apis/document/structure/) (descriptions are markdown → ADF at write time)

These are Atlassian defaults. **Per-project schemes differ** — always prefer live issue context (`project.available_issue_types`, `routable_projects[].usable_issue_types`, field allowlists) over inventing types from the docs above.

## Org / program process

Do **not** invent ownership, DoD, writing standards, or which teams own which domains.

- If `ORG_KNOWLEDGE` is present, prefer it for process and ownership.
- If `PROJECT_ROUTING` / `routable_projects` is present, use it for createable `target_project` (and allowlisted custom fields).
- If those are absent: stay in the parent issue’s project; omit `target_project`.

## Fullsend refine contract (this product)

Emit children that `create-children` can parent by **title**:

| Parent work item | Typical children | `parent_title` |
|---|---|---|
| Feature-level | Epics (then stories under epics) | `null` for top epics; epic title for stories |
| Epic-level | Stories (then tasks under stories) | `null` for top stories; story title for tasks |
| Story-level | Tasks / sub-tasks | `null` or story title per platform rules |

Rules:

- `type` must be an **available** / **usable** issue type for the target project (`project.available_issue_types`, or `routable_projects[<key>].usable_issue_types` when present). Use lowercase names the project actually has.
- Same-project parent links follow that project’s hierarchy (e.g. Task is often not a direct child of Feature). See hierarchy docs above for the platform model; live types win.
- Cross-project: Jira cannot enforce parent-child across projects. If `target_project` differs from the parent, create-children skips hierarchy and links with the site’s related-link type (often “Related” / “Relates”).
- Descriptions: markdown. Optional two-tier shape — scannable summary, then `---` then detail (posting may collapse detail into a Jira expand on Cloud).

Do not require spikes, docs tasks, or labels unless `ORG_KNOWLEDGE` / issue context calls for them.
