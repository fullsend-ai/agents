# Scribe Agent

Reads meeting notes that Gemini saves to Google Drive after a
Google Meet call, maps discussion topics to the issue backlog,
and adds comments to relevant issues or creates new ones.

## Setup

If you want to give autonomous agents access to your meeting notes, you
immediately face a trust problem: how do you prevent the agent from reading
notes it shouldn't have access to and then happily exposing that information
in public issues?

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
search Drive for matching notes, and processes them: it files new issues
on your repo or comments on existing ones, noting that the team
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
  content from reaching the issue tracker.
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
| `SCRIBE_REPO` | yes | Target repository (`owner/name` on GitHub, `group/project` on GitLab) |
| `SCRIBE_SEARCH_QUERY` | yes | Drive search term for meeting note doc names |
| `SCRIBE_LOOKBACK_HOURS` | no | How far back to search Drive (default: 3) |
| `SCRIBE_DRY_RUN` | yes | `true` to preview; `false` for live writes |
| `SCRIBE_MIN_CONFIDENCE` | no | Minimum confidence threshold (default: 0.6) |
| `SCRIBE_MODE` | no | `all`, `comments_only`, or `new_issues_only` |
| `FULLSEND_FORGE` | yes | `github` or `gitlab` |
| `GH_TOKEN` | yes (GitHub) | GitHub token with issues read/write |
| `CONTENTS_TOKEN` | no (GitHub) | Optional separate token for repo content reads; falls back to `GH_TOKEN` |
| `GITLAB_TOKEN` | yes (GitLab) | GitLab personal/project access token |
| `GOOGLE_APPLICATION_CREDENTIALS` | yes | GCP service account key for Drive read |
| `SCRIBE_DRIVE_CREDENTIALS` | no | Override path to a Drive-scoped SA key (defaults to `GOOGLE_APPLICATION_CREDENTIALS`) |
| `SCRIBE_SLACK_WEBHOOK_URL` | no | Optional Slack notification after run |

### Modes

| Mode | Effect |
|------|--------|
| `all` | Post comments on existing issues and create new issues |
| `comments_only` | Skip new issue creation |
| `new_issues_only` | Skip comments on existing issues |

### Jira issue creation

Scribe can create new issues in one Jira Cloud project instead of the
forge's issue tracker. The forge (`FULLSEND_FORGE`) still provides repo
context (closed issues, open PRs, doc index). The Jira project provides
the backlog the agent matches against and receives new issues.

Set `FULLSEND_TRACKER=jira` and the Jira variables in the runner env by
extending the harness with `base:` composition. Then update the agent's
registered source to point to your local harness so fullsend resolves it
instead of the remote pinned source:

```yaml
# .fullsend/scribe.yaml
base: https://raw.githubusercontent.com/fullsend-ai/agents/<SHA>/harness/scribe.yaml#sha256=<sha256sum>
env:
  runner:
    FULLSEND_TRACKER: jira
    SCRIBE_JIRA_PROJECT: PROJ
    SCRIBE_JIRA_ISSUE_TYPE: Task
    JIRA_BASE_URL: ${JIRA_BASE_URL}
    JIRA_USER_EMAIL: ${JIRA_USER_EMAIL}
    JIRA_TOKEN: ${JIRA_TOKEN}
```

After creating the local harness, re-register the agent to use it:

```bash
fullsend agent add .fullsend/scribe.yaml --name scribe --fullsend-dir .
```

| Variable | Required | Description |
|----------|----------|-------------|
| `FULLSEND_TRACKER` | yes (Jira) | `jira`. Defaults to `FULLSEND_FORGE` |
| `SCRIBE_JIRA_PROJECT` | yes (Jira) | Project key for backlog reads and new issues |
| `SCRIBE_JIRA_ISSUE_TYPE` | no | Issue type for new issues (default: `Task`) |
| `JIRA_BASE_URL` | yes (Jira) | `https://<site>.atlassian.net` (Jira Cloud only) |
| `JIRA_USER_EMAIL` | yes (Jira) | Account email for the operator-provided API token |
| `JIRA_TOKEN` | yes (Jira) | Jira Cloud API token |

Behavior:

- Jira credentials stay on the runner. Only the pre- and post-scripts
  use them; the sandbox never receives them.
- Only new issues are written. Comments on Jira issues are not supported:
  `all` behaves as `new_issues_only`, and `comments_only` is rejected.
- The backlog is the project's issues that are not Done, fetched with
  JQL `nextPageToken` pagination. Fetching stops after 50 pages (about
  5,000 issues); a larger backlog is silently truncated to the most
  recently created issues.
- Before creating anything (including in dry-run), the post-script checks
  Jira create metadata. It fails if the issue type is missing or the
  project requires fields scribe does not set, or the create screen has no
  Description field. If the screen has no Labels field, labels are omitted
  from created issues with a warning.
- On live runs, an issue whose summary exactly matches an existing issue
  in the project is skipped, so rerunning on the same notes does not
  create duplicates. If the lookup cannot prove absence (the title has no
  letters or digits to search on, the search fails or returns a malformed
  response, or results are truncated by the page cap without an exact
  match), the post-script refuses to create the issue.
- The same content gates and `SCRIBE_DRY_RUN` safety gate apply. The
  sensitive-content and suspicious-Unicode gates cover labels as well as
  the title and body.

Issue creation delegates to `fullsend issues create --tracker jira`
([#7083](https://github.com/fullsend-ai/fullsend/issues/7083)), which
handles Markdown-to-ADF conversion and the Jira REST call. **This
requires a fullsend release that includes `issues create --tracker jira`
([#8499](https://github.com/fullsend-ai/fullsend/pull/8499)).** The
post-script validates CLI availability at preflight time (including
dry-run) and fails with a clear error if the subcommand is missing.
Labels are applied in a follow-up REST `PUT /issue/{key}` call because
the CLI does not yet support a `--labels` flag; a label PUT failure is
recorded in the run summary and Slack notification so operators can fix
labels manually. The surrounding validation (createmeta checks, duplicate
detection, content gates) remains in the post-script. This is not an
adoption or fork of
[konflux-ci/scribe4jira](https://github.com/konflux-ci/scribe4jira). It
keeps all writes host-side with the same content gates as the GitHub and
GitLab paths. It covers only new issues in one project and issue type, so
scribe4jira behaviors such as custom field mappings are left out. Maintainers
can revisit convergence with scribe4jira under #1676.

Meeting-derived content is sensitive. Run Jira-backed scribe in a private
deployment and keep CI logs and artifacts private, including on dry-runs.

#### Supplying Jira credentials in CI

Scribe resolves `${JIRA_BASE_URL}`, `${JIRA_TOKEN}`, and `${JIRA_USER_EMAIL}` host-side on the CI
runner via `env.runner`. The token is never passed into the sandboxed agent
container. Configure these credentials in your CI platform as follows:

**GitHub Actions:**

1. Navigate to **Settings** → **Secrets and variables** → **Actions** in your
   repository or organization.
2. Under **Repository secrets**, add `JIRA_TOKEN` with your Atlassian Cloud API
   token ([generated from your Atlassian account](https://id.atlassian.com/manage-profile/security/api-tokens)).
3. Under the **Variables** tab, add `JIRA_BASE_URL` with your Jira Cloud instance
   URL (`https://<site>.atlassian.net`).
4. Add `JIRA_USER_EMAIL` as a secret (or under the **Variables** tab).
5. In your workflow YAML (e.g. `.github/workflows/scribe.yml`), pass them into
   the job step's `env`:

```yaml
- name: Run scribe
  env:
    JIRA_BASE_URL: ${{ vars.JIRA_BASE_URL }}
    JIRA_TOKEN: ${{ secrets.JIRA_TOKEN }}
    JIRA_USER_EMAIL: ${{ secrets.JIRA_USER_EMAIL }}
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    # ... other required inputs (SCRIBE_REPO, SCRIBE_SEARCH_QUERY, etc.)
  run: |
    fullsend run scribe --fullsend-dir . --target-repo "${GITHUB_WORKSPACE}"
```

**GitLab CI/CD:**

1. Navigate to **Settings** → **CI/CD** → **Variables** in your project or group.
2. Add `JIRA_BASE_URL`:
   - **Type:** `Variable`
   - **Value:** `https://<site>.atlassian.net`
3. Add `JIRA_TOKEN`:
   - **Type:** `Variable`
   - **Mask variable:** checked (ensures the token is masked in job logs)
   - **Protect variable:** leave unchecked unless the Scribe job runs
     exclusively on protected branches
   - **Expand variable reference:** unchecked (raw string)
4. Add `JIRA_USER_EMAIL` with the associated account email.
5. GitLab CI automatically injects project variables into the runner
   environment, so no extra workflow mapping is required.

### GitLab host validation

`gitlab-scribe-ops.lib.sh` uses `CI_SERVER_URL`, a GitLab CI predefined
variable set automatically by the runner, as the origin for API requests and
generated issue/run links, so a non-default HTTPS port is preserved. It falls
back to `https://${CI_SERVER_HOST}` when `CI_SERVER_URL` is unset. Validation
fails closed when `CI_SERVER_HOST` is not set, when `CI_SERVER_URL` is not an
HTTPS origin, or when its host does not match `CI_SERVER_HOST`.

## How the agent works

A **pre-script** on the host fetches open issues, recently closed issues, open PRs, and a docs index for context, then queries Google Drive for recent meeting notes. Notes are structurally scrubbed (transcript sections removed), PII patterns redacted, and packaged into the sandbox workspace.

The **sandboxed agent** reads the cleaned notes and repo context, extracts actionable topics, and writes validated JSON mapping topics to existing issues or new issue proposals. The agent cannot reach the forge or Drive directly — it only produces structured output.

The **post-script** deduplicates topics, applies confidence and public-safety gates, checks for sensitive content, and writes approved comments and issues via forge-specific API calls (`gh` on GitHub, `curl` on GitLab). Dry-run mode previews all actions without mutating the repository.

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

## Runtime support

Supported runtimes: **claude** (stable default), **pi** (experimental). No single-context fallback — full meeting-notes processing runs on both runtimes.

Effort: `high` (explicit in the harness; override per run with `fullsend run --effort` or `FULLSEND_EFFORT`, values `low`–`max`).

## Source

[`harness/scribe.yaml`](https://github.com/fullsend-ai/agents/blob/main/harness/scribe.yaml)
