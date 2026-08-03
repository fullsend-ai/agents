# GitHub Issue Classify Agent

Classifies GitHub issues into project categories and sets the matching
single-select field on a GitHub Project board.

## How it helps

- New and backlog issues get a workstream category without manual triage.
- Categories come from your org's markdown document — the agent never invents names.
- Confidence gating leaves ambiguous issues unclassified for humans.
- Dry-run mode previews decisions without writing to the project board.

## Triggers

Runs via workflow dispatch (single issue, unclassified batch, or all) or from
an enrolled-repo shim on `issues.opened`. Enrollment means the target repo is
listed under `repos:` with `enabled: true` in your org `.fullsend` config
([fullsend agent registration](https://fullsend.sh/docs)). The shim workflow
in the enrolled repo dispatches `gh-classify` in `.fullsend` for new issues.

## Configuration

Register the agent in your `.fullsend` config (ADR 0058):

```bash
fullsend agent add \
  https://github.com/fullsend-ai/agents/blob/main/harness/gh-classify.yaml \
  --name gh-classify \
  --fullsend-dir .
```

### Categories document

`CLASSIFY_CATEGORIES_PATH` must point to a Markdown file whose `##` headings
are the **exact** category names (matching your GitHub Project single-select
options). Each section should describe what belongs, what does not, and any
tiebreakers. Example:

```markdown
# Workstream Categories

## Bug fixes
Issues reporting broken functionality in existing features.

**What belongs here:** crashes, regressions, incorrect output.

**What does NOT belong:** feature requests (see New features).

## New features
Proposals for capabilities that do not exist yet.
```

Keep this file in the `.fullsend` repo (org-specific taxonomy). It is not
shipped with the shared agent.

### Environment variables

Per ADR 0049, classify configuration uses the `CLASSIFY_` prefix.

| Variable | Required | Description |
|----------|----------|-------------|
| `CLASSIFY_SOURCE_REPO` | yes | Target GitHub repository (`owner/name`) |
| `CLASSIFY_MODE` | yes | `single`, `unclassified`, or `all` |
| `CLASSIFY_ISSUE_NUMBER` | single mode | Issue number to classify |
| `CLASSIFY_CATEGORIES_PATH` | yes | Path to categories markdown (relative to `.fullsend` or target repo) |
| `CLASSIFY_PROJECT_NUMBER` | no | GitHub Project V2 number (default: `1`) |
| `CLASSIFY_FIELD_NAME` | no | Project single-select field name (default: `Workstream Category`) |
| `CLASSIFY_MIN_CONFIDENCE` | no | Minimum confidence to apply (default: `0.7`) |
| `CLASSIFY_DRY_RUN` | yes | `true` to preview; `false` for live writes |
| `CLASSIFY_FILTER_CATEGORY` | no | Restrict assignments to one category name |
| `CLASSIFY_SCREEN_ISSUES` | no | Pre-filter by title/labels in batch modes (default: `true`) |
| `CLASSIFY_PROJECT_TOKEN` | cross-org | PAT for project access when app token cannot reach the board |
| `GH_TOKEN` | yes | GitHub token with issues read and project write |

### Modes

| Mode | Effect |
|------|--------|
| `single` | Classify one issue (`CLASSIFY_ISSUE_NUMBER`) |
| `unclassified` | Batch: skip issues that already have a category on the project |
| `all` | Re-evaluate all open issues (overwrites existing field values) |

## How the agent works

A **pre-script** on the host fetches open issues, builds the candidate set
for the selected mode, and discovers project field option IDs.

The **sandboxed agent** loads the categories document (via the
`issue-classification` skill), screens and evaluates candidates, and writes
validated JSON. Project writes never happen inside the sandbox.

The **post-script** applies confidence and filter gates, adds issues to the
project when needed, sets the category field, and writes a report plus
GitHub Actions step summary. Dry-run mode skips all writes.

### Security model

- **Sandbox network policy** allows GitHub API (`gh`) and Vertex AI only —
  `curl` is excluded so the injected token cannot be used via raw HTTP.
- **Repo scoping** — all `gh` calls must use `--repo "$CLASSIFY_SOURCE_REPO"`.
- **No verbatim issue text** in `reasoning` — summaries only, to limit log leakage.
- **Project token** (`CLASSIFY_PROJECT_TOKEN`) stays on the runner for host
  pre/post scripts only — it is not exported into the sandbox env file or
  `env.sandbox`. The agent uses `GH_TOKEN` for sandbox project reads.

### Output

The agent produces JSON validated against `schemas/gh-classify-result.schema.json`:

- `classifications[]` — per-issue category (or `null`), reasoning, and confidence

## Source

[`harness/gh-classify.yaml`](../harness/gh-classify.yaml)
