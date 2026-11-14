---
name: finding-agent-runs-gitlab
description: >
  GitLab-specific CLI recipes for finding agent workflow runs using
  curl against the GitLab REST API. Use when tracing agent dispatches
  on GitLab.
---

# Finding Agent Runs — GitLab CLI Recipes

## Request values

Run this first, in its own Bash tool call, before any other GitLab command.
It derives the host and the encoded dispatch project path and prints them:

```bash
GITLAB_HOST=$(printf '%s\n' "$ORIGINATING_URL" | sed -nE 's|^https://([^/]+)/.*|\1|p')
ORG="${REPO_FULL_NAME%%/*}"
DISPATCH_REPO="${ORG}/.fullsend"
DISPATCH_ENCODED=$(printf '%s' "$DISPATCH_REPO" | jq -sRr @uri)
test -n "${GITLAB_HOST}" || echo "GITLAB_HOST is empty: ORIGINATING_URL is unset or not an https URL" >&2
if test -n "${ORG}" && printf '%s' "${GITLAB_HOST}" | grep -Eqz '^[A-Za-z0-9.-]+$'; then
  printf 'GITLAB_HOST=%s\nDISPATCH_ENCODED=%s\n' "${GITLAB_HOST}" "${DISPATCH_ENCODED}"
else
  echo "REPO_FULL_NAME is empty or GITLAB_HOST is not a plain hostname" >&2
fi
```

If it printed no values, make no request and report that the GitLab request
values could not be derived. Otherwise, write the printed values literally into
every request URL below in place of `<GITLAB_HOST>` and `<DISPATCH_ENCODED>`.
Never write `${GITLAB_HOST}` in a request URL: the sandbox's SSRF check reads
the URL before shell expansion and blocks it (see the `gitlab` forge skill).

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

## Pipeline listing

```bash
# List recent pipelines in the dispatch repo
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<DISPATCH_ENCODED>/pipelines?ref=main&per_page=10" \
  | jq '.[] | {id: .id, status: .status, ref: .ref, created_at: .created_at}'
```

## Job listing

```bash
# List jobs in a pipeline
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<DISPATCH_ENCODED>/pipelines/<PIPELINE_ID>/jobs" \
  | jq '.[] | {id: .id, name: .name, status: .status, stage: .stage}'
```

## Job logs

```bash
# Read job log output
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<DISPATCH_ENCODED>/jobs/<JOB_ID>/trace" \
  | grep -i "error\|fail\|exit code"
```

## Artifact download

```bash
# Download job artifacts
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  --output artifacts.zip \
  "https://<GITLAB_HOST>/api/v4/projects/<DISPATCH_ENCODED>/jobs/<JOB_ID>/artifacts"
```
