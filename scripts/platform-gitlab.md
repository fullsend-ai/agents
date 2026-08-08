# Platform Context: GitLab Issues

> Child creation via GitLab API is **not fully wired** in Fullsend `create-children` yet.
> Use this for planning guidance; do not assume create will succeed on GitLab.

Forge background (prefer these over inventing process):

- [Epics](https://docs.gitlab.com/user/group/epics/) (Premium+ for many epic features)
- [Issues](https://docs.gitlab.com/user/project/issues/)
- [Issue relations](https://docs.gitlab.com/user/project/issues/related_issues/)

## Org / program process

Do **not** invent ownership, DoD, writing standards, or tier-specific process.

- If `ORG_KNOWLEDGE` is present, prefer it for process and ownership.
- Children stay in the same GitLab project/group as the parent unless install routing says otherwise.
- Hierarchy capabilities vary by GitLab tier — see the docs above; fall back to labels/milestones when epics/parent links are unavailable.

## Fullsend refine contract (this product)

Emit the same child shape as other forges (`type`, `title`, `parent_title`, description) so plans stay portable:

| Logical parent | Typical children | `parent_title` |
|---|---|---|
| Epic / feature-level | Issues or sub-epics, then child issues | `null` at top; parent title for nested items |
| Issue | Child issues or task-like items | `null` or parent issue title |

Rules:

- `type`: logical type (often applied as a label).
- `target_platform`: `"gitlab"` or omit to inherit.
- Descriptions: markdown. Optional `---` between summary and detail; `<details>` is fine where GitLab renders it.

Do not require spikes, docs tasks, or labels unless `ORG_KNOWLEDGE` / issue context calls for them.
