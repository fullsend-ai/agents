# Scribe Agent

Reads meeting notes that Gemini saves to Google Drive after a
Google Meet call, maps discussion topics to the GitHub issue
backlog, and adds comments to relevant issues or creates new
issues.

## Setup

If you want to give autonomous agents access to your meeting notes, you
immediately face a trust problem: how do you prevent the agent from reading
notes it shouldn't have access to and then happily exposing that information
in public GitHub issues?

The answer is a **dedicated GCP service account**. You create it in Google
Cloud, and by default it has access to *zero* Drive files. You then
**invite** the service account's email address to the Google Calendar events
you want it to scribe. (In the calendar event settings you also need to
enable Gemini notes and grant read access to attendees outside your
organization.) In our experience, this calendar invite is how the resulting
notes document becomes visible to the service account's Drive access — but
the exact behavior may depend on your Workspace edition and admin policies
(domain-wide delegation settings, external-guest sharing restrictions, etc.).
Consult your Workspace admin if the service account cannot see expected
notes.

At runtime, the pre-script queries the Drive API using a keyword search
(`SCRIBE_SEARCH_QUERY`) over a rolling time window (`SCRIBE_LOOKBACK_HOURS`,
default 3 hours) across everything the service account can see — including
Shared Drives if the account has been added to any. This means the service
account can read notes from *any* meeting it has been invited to, not just a
single event. To keep the blast radius small, use a distinctive search query
and avoid adding the service account to unrelated Shared Drives.

Scribe wakes up on a schedule, uses the service account credentials to
search Drive for matching notes, and processes them: it files new GitHub
issues on your repo or comments on existing ones, noting that the team
discussed the topic in their meeting. This is an important bridge between
the team's life of human interaction and the fullsend agentic system — the
filed and commented-on issues serve as fodder for the triage agent, coding
agent, and others.

## How it helps

- Meeting decisions and action items reach the issue backlog
  without manual copy-paste.
- Topics are matched to existing issues by title and body
  content, not just keywords.
- Public-safety and PII gates prevent confidential meeting
  content from reaching GitHub.
- Idempotency checks avoid duplicate comments when the same
  notes URL was already posted.

## Triggers

The scribe agent runs on a schedule or via manual trigger.

## Commands

The scribe agent does not accept slash commands.

## Control labels

Scribe does not consume or apply labels that gate agent behavior. It does
apply a `meeting-notes` label (or agent-specified labels) to issues it
creates, for categorization only.

## Configuration

Register the agent in your `.fullsend` config (ADR 0058):

```bash
fullsend agent add \
  https://github.com/fullsend-ai/agents/blob/main/harness/scribe.yaml \
  --name scribe \
  --fullsend-dir .
```

### Variables

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

## Custom network policy

If this agent needs to reach hosts beyond the defaults, see the
[custom network policy guide](network-policy.md).

## Source

[`harness/scribe.yaml`](../harness/scribe.yaml)
