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
context (open PRs, doc index). The Jira project provides the open backlog
and recently resolved issues the agent matches against and receives new
issues.

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
    JIRA_TOKEN: ${FULLSEND_JIRA_TOKEN}
    # Bot user only. Omit this line for a service-account token, which
    # uses Bearer auth.
    JIRA_USER_EMAIL: ${FULLSEND_JIRA_EMAIL}
    FULLSEND_DIR: ${FULLSEND_DIR}
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
| `SCRIBE_JIRA_LABELS` | no | Comma-separated allowlist of labels scribe may apply to Jira issues (default: `meeting-notes`) |
| `JIRA_BASE_URL` | yes (Jira) | `https://<site>.atlassian.net` (Jira Cloud only); used for links |
| `JIRA_API_URL` | yes (OAuth mode) | Where REST calls go: the Atlassian API gateway for the site. `fullsend run` does not set it for scribe, because scribe runs are not Jira-sourced. In token mode it falls back to `JIRA_BASE_URL` when unset |
| `FULLSEND_JIRA_TOKEN` | yes (token mode) | Jira API token, set as a repository secret. The harness above maps it to `JIRA_TOKEN` for the scripts |
| `FULLSEND_JIRA_EMAIL` | no | Bot-user email, set as a repository secret. When set, requests use Basic auth with email and token; when unset or empty (a service account), Bearer auth with the token. The harness above maps it to `JIRA_USER_EMAIL` for the scripts |
| `FULLSEND_JIRA_CLIENT_ID`, `FULLSEND_JIRA_CLIENT_SECRET` | yes (OAuth mode) | A service account's OAuth 2.0 client credentials, set as repository secrets, instead of `FULLSEND_JIRA_TOKEN`. See [OAuth 2.0 client credentials](#oauth-20-client-credentials) |
| `FULLSEND_DIR` | yes (Jira) | The `.fullsend` directory. `fullsend issues create` reads the Jira site and API gateway from `tracker.jira` in its `config.yaml` |

#### OAuth 2.0 client credentials

A service account can authenticate with its OAuth 2.0 client credentials
instead of a token. Map them in `env.runner` in place of `JIRA_TOKEN`:

```yaml
    FULLSEND_JIRA_CLIENT_ID: ${FULLSEND_JIRA_CLIENT_ID}
    FULLSEND_JIRA_CLIENT_SECRET: ${FULLSEND_JIRA_CLIENT_SECRET}
    JIRA_API_URL: https://api.atlassian.com/ex/jira/<cloudId>
```

Get `<cloudId>` from Atlassian's public tenant-info endpoint for your site,
and leave `FULLSEND_JIRA_EMAIL` unset in this mode:

```bash
curl -fsS https://<site>.atlassian.net/_edge/tenant_info | jq -er .cloudId
```

- The scripts mint a short-lived access token on the runner for their REST
  calls, and `fullsend issues create` mints its own from the client
  credentials. The client secret is never printed or passed on a command line.
- `JIRA_API_URL` is required in this mode. The access token works only
  through the Atlassian API gateway, and scribe runs are not Jira-sourced,
  so `fullsend run` does not set `JIRA_API_URL` for them. Without it,
  `pre-scribe.sh` and `post-scribe.sh` fail with an error naming
  `JIRA_API_URL` instead of falling back to `JIRA_BASE_URL`.
- Setting `JIRA_TOKEN` together with the client credentials, or only one of
  the two client variables, fails the run.

Behavior:

- Jira credentials stay on the runner. Only the pre- and post-scripts
  use them; the sandbox never receives them.
- Only new issues are written. Comments on Jira issues are not supported:
  `all` behaves as `new_issues_only`, and `comments_only` is rejected.
- The backlog is the project's issues that are not Done, fetched with
  JQL `nextPageToken` pagination. Fetching stops after 50 pages (about
  5,000 issues); a larger backlog is silently truncated to the most
  recently created issues.
- Recently closed issues: in Jira mode, up to 50 Done issues resolved in
  the last 30 days are fetched from the Jira project so the agent does
  not re-propose work that was recently completed.
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
  the title and body. In Jira mode, agent-proposed labels are intersected with
  an operator allowlist (`SCRIBE_JIRA_LABELS`, default `meeting-notes`),
  validated against `^[A-Za-z0-9._-]{1,64}$`, and capped at 10 labels before
  being added to created issues.

Issue creation delegates to `fullsend issues create --tracker jira`
([#7083](https://github.com/fullsend-ai/fullsend/issues/7083)), which
handles Markdown-to-ADF conversion and the Jira REST call. **This
requires a fullsend release that includes the config-backed Jira commands
([#9078](https://github.com/fullsend-ai/fullsend/pull/9078)), which read
the Jira site and API gateway from `tracker.jira` in the `.fullsend`
directory's `config.yaml` (`FULLSEND_DIR`).** `pre-scribe.sh` fails before
the agent runs when `FULLSEND_DIR` is unset. The post-script validates CLI
availability at preflight time (including dry-run) and fails with a clear
error if the subcommand is missing.
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

Scribe resolves the Jira variables and `${FULLSEND_DIR}` host-side on the CI
runner via `env.runner`; the credentials never reach the sandboxed agent
container. Set exactly one credential mode, as secrets:

- **Token mode:** `FULLSEND_JIRA_TOKEN` and, for a bot user,
  `FULLSEND_JIRA_EMAIL`.
- **OAuth mode:** `FULLSEND_JIRA_CLIENT_ID` and `FULLSEND_JIRA_CLIENT_SECRET`,
  with `JIRA_API_URL` set in the harness (see
  [OAuth 2.0 client credentials](#oauth-20-client-credentials)).

No `JIRA_TOKEN` or `JIRA_USER_EMAIL` secret is needed. Configure the
credentials in your CI platform as follows:

**GitHub Actions:**

1. Navigate to **Settings** → **Secrets and variables** → **Actions** in your
   repository or organization.
2. Under **Repository secrets**, add the secrets for your mode:
   - Token mode: `FULLSEND_JIRA_TOKEN` with your Atlassian Cloud API token
     ([generated from your Atlassian account](https://id.atlassian.com/manage-profile/security/api-tokens)),
     and `FULLSEND_JIRA_EMAIL` for a bot-user token only.
   - OAuth mode: `FULLSEND_JIRA_CLIENT_ID` and `FULLSEND_JIRA_CLIENT_SECRET`.
3. Under the **Variables** tab, add `JIRA_BASE_URL` with your Jira Cloud instance
   URL (`https://<site>.atlassian.net`).
4. Map the variables in your harness `env.runner` as shown above.
5. Export `FULLSEND_DIR` as the path to your `.fullsend` directory. The
   workflow step below sets it. `pre-scribe.sh` fails when it is unset.
6. In your workflow YAML (e.g. `.github/workflows/scribe.yml`), pass them into
   the job step's `env`:

```yaml
- name: Run scribe
  env:
    JIRA_BASE_URL: ${{ vars.JIRA_BASE_URL }}
    # Token mode
    FULLSEND_JIRA_TOKEN: ${{ secrets.FULLSEND_JIRA_TOKEN }}
    FULLSEND_JIRA_EMAIL: ${{ secrets.FULLSEND_JIRA_EMAIL }}
    # OAuth mode, instead of the two lines above
    # FULLSEND_JIRA_CLIENT_ID: ${{ secrets.FULLSEND_JIRA_CLIENT_ID }}
    # FULLSEND_JIRA_CLIENT_SECRET: ${{ secrets.FULLSEND_JIRA_CLIENT_SECRET }}
    FULLSEND_DIR: ${{ github.workspace }}
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    # ... other required inputs (SCRIBE_REPO, SCRIBE_SEARCH_QUERY, etc.)
  run: |
    fullsend run scribe --fullsend-dir . --target-repo "${GITHUB_WORKSPACE}"
```

Step `env` works for this direct `fullsend run` step. If you run scribe
through the fullsend action instead, pass the secrets as action inputs; the
action ignores `FULLSEND_JIRA_*` set in step `env`:

```yaml
  with:
    jira-token: ${{ secrets.FULLSEND_JIRA_TOKEN }}
    jira-email: ${{ secrets.FULLSEND_JIRA_EMAIL }}  # bot user only
    # OAuth mode, instead of jira-token and jira-email:
    # jira-client-id: ${{ secrets.FULLSEND_JIRA_CLIENT_ID }}
    # jira-client-secret: ${{ secrets.FULLSEND_JIRA_CLIENT_SECRET }}
```

**GitLab CI/CD:**

1. Navigate to **Settings** → **CI/CD** → **Variables** in your project or group.
2. Add `JIRA_BASE_URL`:
   - **Type:** `Variable`
   - **Value:** `https://<site>.atlassian.net`
3. Add the credentials for your mode: `FULLSEND_JIRA_TOKEN` (token mode), or
   `FULLSEND_JIRA_CLIENT_ID` and `FULLSEND_JIRA_CLIENT_SECRET` (OAuth mode).
   Give each one these settings:
   - **Type:** `Variable`
   - **Mask variable:** checked (ensures the value is masked in job logs)
   - **Protect variable:** leave unchecked unless the Scribe job runs
     exclusively on protected branches
   - **Expand variable reference:** unchecked (raw string)
4. Token mode: for a bot-user token, add `FULLSEND_JIRA_EMAIL` with the
   associated account email.
5. Set `FULLSEND_DIR` to the path of your `.fullsend` directory, for example
   `variables: FULLSEND_DIR: "${CI_PROJECT_DIR}"` in `.gitlab-ci.yml`.
   `pre-scribe.sh` fails when it is unset.
6. GitLab CI automatically injects project variables into the runner
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

- `topics[]` — discussion topics mapped to existing issues (comment body in `summary`; `null` for omitted or `public_safe: false` topics, which are never posted)
- `new_issues[]` — proposals for issues not yet in the backlog
- `stats` — counts for observability

### Notifications

The post-script produces two independent outputs after each run:

- a **step summary**, written whenever `GITHUB_STEP_SUMMARY` is available (i.e.
  on any GitHub Actions run), regardless of whether a Slack webhook is set; and
- a **Slack message**, sent only when `SCRIBE_SLACK_WEBHOOK_URL` is set, which
  keeps the run-mode label (`LIVE` or `DRY RUN`) and a `View run` link.

When the run processed one or more meeting documents, **both** outputs include a
**`Meeting:`** line naming the processed document(s) — a single
`Meeting: <title>` for one doc, or a `Meetings (N):` list for several — so
operators can tell which meeting produced the results without opening the Actions
run. The titles come from the Drive document names that `pre-scribe` records in a
runner-only `scribe-titles.json` (`doc_names`), which — unlike `scribe-meta.json`
— is **not** mounted into the agent sandbox, so untrusted titles never enter the
agent's context. Document names are **untrusted input** and are
sanitized before display: control characters, ANSI escapes, and dangerous
Unicode (line/paragraph separators, bidi overrides, zero-width and tag
characters) are stripped so a crafted title cannot inject extra lines or reorder
text. Titles are then rendered inside an inline code span (backticks) in
**both** the Slack message and the step summary. In the step summary this
suppresses Markdown links, raw HTML, and bare-URL autolinking. In Slack,
inline code is documented to suppress other mrkdwn formatting (`*bold*`,
`_italic_`, `~strike~`), so an unescaped title cannot use emphasis to alter
the notification's appearance; whether a bare URL remains clickable inside a
Slack code span is not relied on alone — the Slack payload also sets
`unfurl_links`/`unfurl_media` to `false`, independently preventing a
link-preview card for a URL in an untrusted title. Slack's own mrkdwn/link
metacharacters (`& < > |`) are also escaped beforehand as defense-in-depth.
Each title is also run through a sensitive-content redactor: the same patterns
that gate topics and new issues (emails, SSNs, keys/tokens, and similar), plus —
because titles are raw, never-scrubbed Drive names — the phone-number,
IPv4-address and card-number detection that `pre-scribe` applies to note bodies.
Only the **matching substring** is replaced with `[redacted]` (e.g. `Call
[redacted] re Q3`), so the rest of the title still identifies the meeting.
Card-like digit runs are Luhn-validated before redaction so version numbers and
meeting IDs (e.g. `OKR 1234567890123`) are not blanked; an IPv4-shaped version
such as `4.18.0.1` still has that span redacted, since a pattern cannot tell it
from an address. This redaction is **pattern-based only**: unlike topics and new
issues, titles skip the agent's `public_safe` gate, so free-text PII that does
not match one of these patterns — a person's name, for example — is published
as-is (`1:1 with Jane Doe - performance review` is not redacted).

The same stripping and redaction are applied to the document names `pre-scribe`
writes to the **job log** (the "Found …" and "Downloading: …" lines), so a
sensitive name is redacted there too — not shown in full on the same run page —
and a newline in a name cannot forge an extra log line.

If the metadata or
`doc_names` field is absent, the meeting line is omitted and the outputs are
otherwise unchanged.

The concise **"No meeting notes found for today."** message replaces the usual
activity counters only when **both** conditions hold: the runner-side
`scribe-meta.json` reports `docs_downloaded: 0` (a successful search that matched
no documents), **and** the agent produced nothing to act on (no topics and no
new-issue proposals in its result). This keeps an empty run from being mistaken
for one that processed notes but produced no topics, while still showing the
activity report — including any skipped or failed items — if a zero-document
search nonetheless returned proposals. A run that *found* notes but extracted
zero topics has `docs_downloaded > 0` and keeps the normal report. Missing,
malformed, or non-numeric metadata, and search or export failures, never produce
the no-notes message. An unset webhook skips the notification entirely.

## Custom network policy

If this agent needs to reach hosts beyond the defaults, see the
[custom network policy guide](network-policy.md).

## Runtime support

Supported runtimes: **claude** (stable default), **pi** (experimental). No single-context fallback — full meeting-notes processing runs on both runtimes.

Effort: `high` (explicit in the harness; override per run with `fullsend run --effort` or `FULLSEND_EFFORT`, values `low`–`max`).

## Source

[`harness/scribe.yaml`](https://github.com/fullsend-ai/agents/blob/main/harness/scribe.yaml)
