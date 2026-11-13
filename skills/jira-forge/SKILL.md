---
name: jira
description: >-
  Use when reading Jira issue content, comments, or searching for duplicate or
  related issues via curl against the Jira Cloud REST API. Shared by all agents
  running on the Jira forge.
---

# Jira Cloud API

Use `curl` with the Jira Cloud REST API (v3). The environment provides
`JIRA_TOKEN`, `JIRA_BASE_URL`, and, when set, `JIRA_USER_EMAIL` and
`JIRA_API_URL`. `JIRA_TOKEN` inside
the sandbox is the opaque placeholder supplied by the `jira-ro` provider —
the real API token never enters the sandbox. Send API requests to
`JIRA_API_URL` (the Atlassian API gateway for the site), falling back to
`JIRA_BASE_URL` when it is empty; build browse links for humans from
`JIRA_BASE_URL`.

The auth mode depends on the account. A bot user has an email and uses
Basic auth with `email:token`. A service account has no email
(`JIRA_USER_EMAIL` is unset, empty, or only whitespace) and uses Bearer auth with the token.
Never send Basic auth with an empty email. Shell variables do not carry over
between commands, so start every command that calls Jira with the line that
sets `JIRA_AUTH_FLAG` and `JIRA_AUTH`:

```bash
JIRA_EMAIL="${JIRA_USER_EMAIL:-}"; JIRA_EMAIL="${JIRA_EMAIL//[[:space:]]/}"
JIRA_AUTH_FLAG=--oauth2-bearer; test -n "${JIRA_EMAIL}" && JIRA_AUTH_FLAG=--user
JIRA_AUTH="${JIRA_EMAIL:+${JIRA_EMAIL}:}${JIRA_TOKEN}"
curl --silent "${JIRA_AUTH_FLAG}" "${JIRA_AUTH}" \
  --header "Content-Type: application/json" \
  "${JIRA_API_URL:-${JIRA_BASE_URL}}/rest/api/3/..."
```

Extract the issue key and project key from the issue URL:
```bash
ISSUE_KEY="${ISSUE_URL##*/browse/}"
PROJECT_KEY="${ISSUE_KEY%-*}"
echo "issue ${ISSUE_KEY}, project ${PROJECT_KEY}"
```

Shell variables do not carry over between commands either, so the blocks
below derive `ISSUE_KEY` again where they use it. In JQL, replace
`<PROJECT_KEY>` with the project key printed above (the issue key up to
its last `-`). The sandbox command check blocks a shell variable inside
`--data-urlencode`.

Jira Cloud only (v1) — the issue host must be `*.atlassian.net`. Jira
Server/Data Center is not supported.

## Issues

```bash
JIRA_EMAIL="${JIRA_USER_EMAIL:-}"; JIRA_EMAIL="${JIRA_EMAIL//[[:space:]]/}"
JIRA_AUTH_FLAG=--oauth2-bearer; test -n "${JIRA_EMAIL}" && JIRA_AUTH_FLAG=--user
JIRA_AUTH="${JIRA_EMAIL:+${JIRA_EMAIL}:}${JIRA_TOKEN}"
ISSUE_KEY="${ISSUE_URL##*/browse/}"

# View an issue with full details
curl --fail-with-body --silent "${JIRA_AUTH_FLAG}" "${JIRA_AUTH}" \
  "${JIRA_API_URL:-${JIRA_BASE_URL}}/rest/api/3/issue/${ISSUE_KEY}"

# List issue comments (newest first, so the most recent reply is on page one)
curl --fail-with-body --silent "${JIRA_AUTH_FLAG}" "${JIRA_AUTH}" \
  "${JIRA_API_URL:-${JIRA_BASE_URL}}/rest/api/3/issue/${ISSUE_KEY}/comment?orderBy=-created&maxResults=50"

# List open issues in the project
curl --fail-with-body --silent "${JIRA_AUTH_FLAG}" "${JIRA_AUTH}" \
  --header "Content-Type: application/json" \
  --get --data-urlencode "jql=project = <PROJECT_KEY> AND statusCategory != Done" \
  --data-urlencode "fields=summary,status,labels" \
  "${JIRA_API_URL:-${JIRA_BASE_URL}}/rest/api/3/search/jql"
```

**Requesting fields:** `/rest/api/3/search/jql` returns only `id` and `key`
unless you pass `fields`. Always request the fields you need (e.g.
`fields=summary,status,labels`) — otherwise every result is an opaque issue
key with nothing to compare against, and duplicate detection silently finds
nothing.

**Pagination:** The `/rest/api/3/search/jql` endpoint uses `nextPageToken`
(not `startAt`). To page through results, pass `&nextPageToken=<token>` from
the previous response's `nextPageToken` field. Stop when the field is absent
or null. Comment listing is a separate endpoint and still uses
`startAt`/`maxResults`; a single page returns at most `maxResults` comments,
so use `orderBy=-created` when you only need the latest replies.

**Error handling:** Always use `--fail-with-body` so HTTP errors (e.g. 410
Gone) cause curl to exit non-zero instead of silently returning an error body
that could be mistaken for an empty result set.

## Searching for Duplicates and Related Issues

```bash
JIRA_EMAIL="${JIRA_USER_EMAIL:-}"; JIRA_EMAIL="${JIRA_EMAIL//[[:space:]]/}"
JIRA_AUTH_FLAG=--oauth2-bearer; test -n "${JIRA_EMAIL}" && JIRA_AUTH_FLAG=--user
JIRA_AUTH="${JIRA_EMAIL:+${JIRA_EMAIL}:}${JIRA_TOKEN}"

# Search issues by keyword (JQL text search)
curl --fail-with-body --silent "${JIRA_AUTH_FLAG}" "${JIRA_AUTH}" \
  --header "Content-Type: application/json" \
  --get --data-urlencode "jql=project = <PROJECT_KEY> AND text ~ \"keyword\"" \
  --data-urlencode "fields=summary,status,labels" \
  "${JIRA_API_URL:-${JIRA_BASE_URL}}/rest/api/3/search/jql"

# Search across all projects visible to the account
curl --fail-with-body --silent "${JIRA_AUTH_FLAG}" "${JIRA_AUTH}" \
  --header "Content-Type: application/json" \
  --get --data-urlencode "jql=text ~ \"keyword\" ORDER BY updated DESC" \
  --data-urlencode "fields=summary,status,labels" \
  "${JIRA_API_URL:-${JIRA_BASE_URL}}/rest/api/3/search/jql"
```

## Cross-Project Searches

```bash
JIRA_EMAIL="${JIRA_USER_EMAIL:-}"; JIRA_EMAIL="${JIRA_EMAIL//[[:space:]]/}"
JIRA_AUTH_FLAG=--oauth2-bearer; test -n "${JIRA_EMAIL}" && JIRA_AUTH_FLAG=--user
JIRA_AUTH="${JIRA_EMAIL:+${JIRA_EMAIL}:}${JIRA_TOKEN}"

# Search issues in another project (use its project key)
curl --fail-with-body --silent "${JIRA_AUTH_FLAG}" "${JIRA_AUTH}" \
  --header "Content-Type: application/json" \
  --get --data-urlencode "jql=project = OTHERPROJ AND text ~ \"keyword\"" \
  --data-urlencode "fields=summary,status,labels" \
  "${JIRA_API_URL:-${JIRA_BASE_URL}}/rest/api/3/search/jql"
```

## Linked Code Changes

Jira has no pull/merge requests of its own. A PR that someone attached to the
issue as a web link shows up as a remote link:

```bash
JIRA_EMAIL="${JIRA_USER_EMAIL:-}"; JIRA_EMAIL="${JIRA_EMAIL//[[:space:]]/}"
JIRA_AUTH_FLAG=--oauth2-bearer; test -n "${JIRA_EMAIL}" && JIRA_AUTH_FLAG=--user
JIRA_AUTH="${JIRA_EMAIL:+${JIRA_EMAIL}:}${JIRA_TOKEN}"
ISSUE_KEY="${ISSUE_URL##*/browse/}"

# List remote links on an issue (may include manually linked PRs/MRs)
curl --fail-with-body --silent "${JIRA_AUTH_FLAG}" "${JIRA_AUTH}" \
  "${JIRA_API_URL:-${JIRA_BASE_URL}}/rest/api/3/issue/${ISSUE_KEY}/remotelink"
```

This is strictly best-effort discovery for the Existing PR/MR gate, and it
does **not** cover the common case: integrations such as GitHub for Jira
record linked branches and pull requests as *development information* behind
the issue's development panel, not as remote links, and that data is not
exposed by the REST v3 issue API. The PR host itself is also unreachable from
this sandbox.

So an empty remote-link list is not evidence that no PR exists. Treat the
Existing PR/MR gate as unverifiable on Jira unless a remote link happens to
show one: state in your reasoning that PR/MR status could not be checked, and
weigh that gap before emitting `sufficient`.

## Repository Contents

Jira is an issue tracker, not a code host — there is no repository browsing
API here, and no equivalent of the GitHub/GitLab skills' repository-contents
commands. When the triage steps call for repository context (README,
AGENTS.md, CONTRIBUTING.md, ADRs), take it from the issue text and its
comments alone, and record the missing repository context as an information
gap in your reasoning.

## Key Differences from GitHub/GitLab

- Jira has no pull/merge requests — it is a pure issue tracker. There is no
  equivalent "code change" search; see Linked Code Changes above for the
  remote-link fallback.
- Issue descriptions and comment bodies are Atlassian Document Format (ADF)
  JSON, not plain text/markdown. ADF nests text below headings, bullet lists,
  tables and panels, so extract it recursively — e.g.
  `jq -r '[.fields.description | .. | .text? // empty] | join(" ")'` — rather
  than reading only `.content[].content[].text`, which sees top-level
  paragraphs only and silently truncates the rest.
- Search uses JQL (Jira Query Language) via the `jql` query parameter, not a
  free-text `search` parameter.
- Labels are a flat string array on `.fields.labels` — there is no separate
  per-project label registry to query.
