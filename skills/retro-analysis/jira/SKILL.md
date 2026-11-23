---
name: retro-analysis-jira
description: >
  Jira-specific recipes for the retro-analysis skill. Use the host-fetched
  issue context when ORIGINATING_URL is a Jira issue, and trace the agent
  side on the originating forge, which is the only system the sandbox can
  reach.
---

# Retro Analysis — Jira-Originated Work

A retro whose `ORIGINATING_URL` is a Jira issue URL
(`https://<site>.atlassian.net/browse/<issue-key>`) analyzes a work item that
lives in Jira but was actioned on the forge. This skill covers both halves.

## Reading the originating issue

The sandbox has **no route to Atlassian and no Jira credential**, so the host
pre-script fetched the issue and its comments before the sandbox started. Read
`RETRO_JIRA_CONTEXT` (default `/sandbox/workspace/jira-origin.json`):

```bash
jq -r '.issue | "\(.key) [\(.status)] \(.summary)\n\n\(.description)"' "$RETRO_JIRA_CONTEXT"
jq -r '.comments[] | "--- \(.author) at \(.created)\n\(.body)"' "$RETRO_JIRA_CONTEXT"
```

Do **not** run `curl` against Jira, `fullsend issues`, or anything else that
expects a Jira API. There is no token and no network path; the attempt fails
and burns the run. The file is the only Jira data available.

The file contains:

| Field | Meaning |
|---|---|
| `issue.key`, `issue.url` | Issue key and browse URL. Link proposals and the summary to `issue.url`, not to a guessed host. |
| `issue.summary`, `issue.description` | Requirement text, converted from Jira's rich text (ADF) to plain text. |
| `issue.project`, `issue.issue_type`, `issue.status`, `issue.labels` | Where the work item sits and what state it reached. |
| `issue.parent`, `issue.links` | Related and parent work items, as `{type, key}` pairs. |
| `comments[]` | `id`, `author`, `created`, `body` for each comment, oldest first. |
| `comments_truncated`, `issue.description_truncated` | `true` when the host capped the payload. Say so in `summary` rather than treating the text as complete. |

If `RETRO_JIRA_CONTEXT` is missing or empty while `ORIGINATING_URL` is a Jira
URL, the host fetch did not run. Record that gap in `summary` and analyze only
what the forge shows. Never invent issue text, comments, or status.

## Tracing the agent side on the forge

The workflow graph — triage, code, review, fix, human interventions — lives on
the forge that actioned the work item, so use the GitHub or GitLab recipes for
it. Start from the issue key:

```bash
# PRs and commits that mention the key
gh search prs --owner <org> "<issue-key>" --limit 20
gh search commits "<issue-key>" --limit 20

# The dispatch runs that produced them
gh run list --repo "$REPO_FULL_NAME" --workflow=fullsend.yaml --limit 20 \
  --json databaseId,event,status,conclusion,createdAt
```

Match the key exactly (`<project>-123`, not `<project>-1234`). A work item can be
actioned by more than one PR; treat each as a branch of the same workflow.

## Proposals

- Jira is the tracker destination for this run: unless the run is summary-only,
  validated proposals are filed as Jira issues in the configured project, not as
  forge issues. Describe the proposed change so it stands alone in Jira.
- The dedup receipt (`related_issues`) still records searches. Include the
  issue-key search you ran on the forge, and note the originating key as a
  related item where the proposal stems from it.
- Cite evidence by issue key and comment author/date so a reader can open the
  Jira issue and follow it.
