# Platform Context: GitHub Issues

Forge background (prefer these over inventing process):

- [About issues](https://docs.github.com/en/issues/tracking-your-work-with-issues/about-issues)
- [Adding sub-issues](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/adding-sub-issues)
- [Managing labels](https://docs.github.com/en/issues/using-labels-and-milestones-to-track-work/managing-labels)

## Org / program process

Do **not** invent ownership, DoD, writing standards, or team conventions.

- If `ORG_KNOWLEDGE` is present, prefer it for process and ownership.
- GitHub children stay in the **same repository** as the parent. Do not set `target_project`.
- Cross-repo work: note as dependencies; do not auto-create in other repos.

## Fullsend refine contract (this product)

GitHub has no native Feature/Epic/Story types. Express level with **`type`** (applied as a label) and parent/child via **sub-issues** using `parent_title` chains:

| Logical parent | Typical children | `parent_title` |
|---|---|---|
| Feature-labeled issue | Epic-labeled children, then stories under epics | `null` for top epics; epic title for stories |
| Epic-labeled issue | Story-labeled children, then tasks | `null` for top stories; story title for tasks |
| Story-labeled issue | Task-labeled children | `null` or story title |

Rules:

- `type`: logical type (`epic`, `story`, `task`, `spike`, `bug`, …) — used as a label.
- `labels`: optional extras beyond the type label.
- `target_platform`: `"github"` or omit to inherit.
- Descriptions: markdown. Optional `---` between summary and detail; `<details>` works in GitHub for collapse if needed.
- If sub-issue linking fails, create-children still creates the issue in-repo.

Do not require spikes, docs tasks, or specific label sets unless `ORG_KNOWLEDGE` / issue context calls for them.
