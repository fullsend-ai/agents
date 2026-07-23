# Scribe Agent

Reads Google Drive meeting notes, maps discussion topics to the GitHub issue backlog, and posts comments or new issues.

## How it helps

- Meeting decisions and action items reach the issue backlog without manual copy-paste.
- Topics are matched to existing issues by title and body content, not just keywords.
- Public-safety and PII gates prevent confidential meeting content from reaching GitHub.
- Idempotency checks avoid duplicate comments when the same notes URL was already posted.

## Triggers

The scribe agent runs on a schedule or via manual trigger.

## Configuration

Register the agent in your `.fullsend` config (ADR 0058):

```bash
fullsend agent add \
  https://github.com/fullsend-ai/agents/blob/main/harness/scribe.yaml \
  --name scribe \
  --fullsend-dir .
```

### Environment variables

Per ADR 0049, scribe configuration uses the `SCRIBE_` prefix.

| Variable | Required | Description |
|----------|----------|-------------|
| `SCRIBE_REPO` | yes | Target GitHub repository (`owner/name`) |
| `SCRIBE_SEARCH_QUERY` | yes | Drive search term for meeting note doc names |
| `SCRIBE_LOOKBACK_HOURS` | no | How far back to search Drive (default: 3) |
| `SCRIBE_DRY_RUN` | yes | `true` to preview; `false` for live writes |
| `SCRIBE_MIN_CONFIDENCE` | no | Minimum confidence threshold (default: 0.6) |
| `SCRIBE_MODE` | no | `all`, `comments_only`, or `new_issues_only` |
| `GH_TOKEN` | yes | GitHub token with issues read/write |
| `GOOGLE_APPLICATION_CREDENTIALS` | yes | GCP service account key for Drive read |
| `SCRIBE_DRIVE_CREDENTIALS` | no | Override path to a Drive-scoped SA key (defaults to `GOOGLE_APPLICATION_CREDENTIALS`) |
| `SCRIBE_SLACK_WEBHOOK_URL` | no | Optional Slack notification after run |

### Modes

| Mode | Effect |
|------|--------|
| `all` | Post comments on existing issues and create new issues |
| `comments_only` | Skip new issue creation |
| `new_issues_only` | Skip comments on existing issues |

## How the agent works

A **pre-script** on the host fetches open issues, recently closed issues, open PRs, and a docs index for context, then queries Google Drive for recent meeting notes. Notes are structurally scrubbed (transcript sections removed), PII patterns redacted, and packaged into the sandbox workspace.

The **sandboxed agent** reads the cleaned notes and repo context, extracts actionable topics, and writes validated JSON mapping topics to existing issues or new issue proposals. The agent cannot reach GitHub or Drive directly — it only produces structured output.

The **post-script** deduplicates topics, applies confidence and public-safety gates, checks for sensitive content, and writes approved comments and issues via `gh`. Dry-run mode previews all actions without mutating GitHub.

### Security model

- **Pre-script PII scrubbing** runs on the host before the agent sees notes. Bracketed Gemini attendee names (`[John Smith]`) and bullet attribution lines (`- Jane Doe: action`) are anonymized; transcript sections are dropped. Other unbracketed names in prose rely on the agent's `public_safe` gate as defense-in-depth.
- **Sandbox network policy** allows Vertex AI only — `curl` is excluded to prevent exfiltration of the mapped GCP service account key.
- **Post-script gates** reject topics below confidence threshold, with sensitive patterns, suspicious Unicode, or `public_safe: false`.
- **Dry-run gate** — the post-script refuses to run unless `SCRIBE_DRY_RUN` is explicitly set.

### Output

The agent produces JSON validated against `schemas/scribe-result.schema.json`:

- `topics[]` — discussion topics mapped to existing issues (comment body in `summary`)
- `new_issues[]` — proposals for issues not yet in the backlog
- `stats` — counts for observability

## Source

[`harness/scribe.yaml`](../harness/scribe.yaml)
