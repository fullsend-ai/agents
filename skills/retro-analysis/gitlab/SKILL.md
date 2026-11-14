---
name: retro-analysis-gitlab
description: >
  GitLab-specific CLI recipes for the retro-analysis skill. Use curl
  against the GitLab REST API to trace pipelines, read job logs,
  download artifacts, and search for duplicate issues on GitLab.
---

# Retro Analysis — GitLab CLI Recipes

## Request values

Run this first, in its own Bash tool call, before any other GitLab command.
It derives the host and the encoded source and dispatch project paths and
prints them:

```bash
GITLAB_HOST=$(printf '%s\n' "$ORIGINATING_URL" | sed -nE 's|^https://([^/]+)/.*|\1|p')
REPO_ENCODED=$(printf '%s' "$REPO_FULL_NAME" | jq -sRr @uri)
ORG="${REPO_FULL_NAME%%/*}"
DISPATCH_REPO="${ORG}/.fullsend"
DISPATCH_REPO_ENCODED=$(printf '%s' "$DISPATCH_REPO" | jq -sRr @uri)
test -n "${GITLAB_HOST}" || echo "GITLAB_HOST is empty: ORIGINATING_URL is unset or not an https URL" >&2
if test -n "${ORG}" && printf '%s' "${GITLAB_HOST}" | grep -Eqz '^[A-Za-z0-9.-]+$'; then
  printf 'GITLAB_HOST=%s\nREPO_ENCODED=%s\nDISPATCH_REPO_ENCODED=%s\n' "${GITLAB_HOST}" "${REPO_ENCODED}" "${DISPATCH_REPO_ENCODED}"
else
  echo "REPO_FULL_NAME is empty or GITLAB_HOST is not a plain hostname" >&2
fi
```

If it printed no values, make no request and report that the GitLab request
values could not be derived. Otherwise, write the printed values literally into
every request URL below in place of `<GITLAB_HOST>` and
`<DISPATCH_REPO_ENCODED>`; `REPO_ENCODED` is the source project for
`<layer-project-encoded>`. Never write `${GITLAB_HOST}` in a request URL: the
sandbox's SSRF check reads the URL before shell expansion and blocks it (see
the `gitlab` forge skill).

The sandbox's command scanner blocks a `--header "PRIVATE-TOKEN: …"` argument.
Requests read the token from a curl config file instead. This is the same file
as the `gitlab` forge skill's. Write it before the first request, in its own
Bash tool call. Do not combine this setup with any GitLab fetch or other
command in the same call; the scanner blocks a call that mixes token-config
setup with a request.

```bash
(umask 077; set -C; rm -f /tmp/gitlab-api.curlrc; printf 'header = "PRIVATE-TOKEN: %s"\nsilent\n' "$GITLAB_TOKEN" > /tmp/gitlab-api.curlrc)
```

Make the requests in later Bash tool calls, never in the token setup call,
with the printed request values pasted in. Requests in the same block below
may share one call. When you have made your last GitLab request, scrub the
token in its own Bash call: `: > /tmp/gitlab-api.curlrc`. Run the token setup
command again before any later GitLab request, or if the file may already have
been scrubbed.

All API calls use:
```bash
curl --fail --silent --show-error \
  --connect-timeout 10 --max-time 30 \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4<ENDPOINT>"
```

`<ENDPOINT>` is a path from the recipes below.

## Pipeline tracing

### List recent pipelines in the dispatch project

Agent workflows run in the dispatch project (`<org>/.fullsend`, the printed
`DISPATCH_REPO_ENCODED`), not the source project.

```bash
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<DISPATCH_REPO_ENCODED>/pipelines?per_page=20" \
  | jq '.[] | {id: .id, status: .status, ref: .ref, created_at: .created_at}'
```

### List jobs in a pipeline

```bash
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<DISPATCH_REPO_ENCODED>/pipelines/<PIPELINE_ID>/jobs" \
  | jq '.[] | {id: .id, name: .name, status: .status, stage: .stage}'
```

## Reading job logs

```bash
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<DISPATCH_REPO_ENCODED>/jobs/<JOB_ID>/trace" \
  | grep -i "error\|fail\|exit code"
```

## Downloading artifacts

```bash
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  --output artifacts.zip \
  "https://<GITLAB_HOST>/api/v4/projects/<DISPATCH_REPO_ENCODED>/jobs/<JOB_ID>/artifacts"
```

## Duplicate search

Run both passes for every proposal — fix-keyed and root-cause-keyed (see the
retro-analysis skill's "Before proposing" section). The fix-keyed pass searches
the proposal's `target_repo`; the root-cause pass must also search the other
layer projects the localization rules can route a proposal to (platform, the
agents project, the source project), because a symptom fix and its root cause
can land in different layers. GitLab's issue search is per-project, so run the
root-cause query once per layer project and merge the results. Do not use a
group-wide search — it reaches private/unrelated sibling projects.

First, in its own Bash call, encode the target project and print it:

```bash
TARGET_ENCODED=$(printf '%s' "<target_repo>" | jq -sRr @uri)
printf 'TARGET_ENCODED=%s\n' "${TARGET_ENCODED}"
```

Paste the printed value into `<TARGET_ENCODED>` below.

```bash
# Fix-keyed: keywords drawn from the proposed change, open issues
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<TARGET_ENCODED>/issues?search=<fix+keywords>&state=opened&per_page=20" \
  | jq '.[] | {iid: .iid, title: .title, state: .state, web_url: .web_url, description: .description}'

# Root-cause-keyed: run once per layer project (platform, agents, source),
# encoding each path, and merge. Do not use a group-wide search. No state=opened
# — the close-reason rules must apply across layers, so this returns closed
# issues too, projecting closed_at, labels and _links.closed_as_duplicate_of
# (GitLab has no close-reason API; see the close-reason note below).
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<layer-project-encoded>/issues?search=<subsystem+or+root-cause+keywords>&per_page=20" \
  | jq '.[] | {iid: .iid, title: .title, state: .state, closed_at: .closed_at, labels: .labels, closed_as_duplicate_of: ._links.closed_as_duplicate_of, web_url: .web_url, description: .description}'

# Include closed issues to apply the close-reason rules. GitLab has NO
# close-reason API, so unlike GitHub's state_reason the reason must be inferred:
#   - _links.closed_as_duplicate_of present  -> duplicate (structured link)
#   - a `duplicate` / `not-planned` / `completed` label (applied by fullsend
#     triage)                                 -> that reason
#   - otherwise                               -> unknown; the not-planned
#     (30-day) and completed rules are best-effort and should be skipped rather
#     than guessed. closed_at is still available for the 30-day window.
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<TARGET_ENCODED>/issues?search=<keywords>&per_page=20" \
  | jq '.[] | {iid: .iid, title: .title, state: .state, closed_at: .closed_at, labels: .labels, closed_as_duplicate_of: ._links.closed_as_duplicate_of, web_url: .web_url, description: .description}'

# Follow a duplicate chain to its canonical. Prefer the structured link
# (_links.closed_as_duplicate_of, added in gitlab!89375) from the projection
# above; fall back to the candidate's own description and notes for a
# "duplicate of #X" reference only when it is absent. (The duplicate points to
# the canonical, not the reverse — a search mentioning the candidate's number
# does not find its canonical.)
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<TARGET_ENCODED>/issues/<candidate-iid>" \
  | jq '{iid: .iid, title: .title, state: .state, description: .description, closed_as_duplicate_of: ._links.closed_as_duplicate_of}'
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<TARGET_ENCODED>/issues/<candidate-iid>/notes?per_page=50" \
  | jq '.[] | {body: .body}'
# Then fetch the referenced canonical directly (follow further links if it is
# itself a duplicate). Note its project: the canonical may live in another layer.
```

Use multiple searches with different keyword combinations if the first returns no results — the same idea can be filed under different titles.
