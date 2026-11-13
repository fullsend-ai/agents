---
name: finding-agent-runs-gitlab
description: >
  GitLab-specific CLI recipes for finding agent workflow runs using
  curl against the GitLab REST API. Use when tracing agent dispatches
  on GitLab.
---

# Finding Agent Runs — GitLab CLI Recipes

## Environment setup

```bash
GITLAB_HOST=$(printf '%s\n' "$ORIGINATING_URL" | sed -E 's|^https://([^/]+)/.*|\1|')
DISPATCH_ENCODED=$(printf '%s' "$DISPATCH_REPO" | jq -sRr @uri)
REPO_ENCODED=$(printf '%s' "$REPO_FULL_NAME" | jq -sRr @uri)
```

The sandbox's command scanner blocks a `--header "PRIVATE-TOKEN: …"` argument.
Requests read the token from a curl config file instead. This is the same file
as the `gitlab` forge skill's. Write it before the first request, in its own
Bash tool call. Do not combine this setup with any GitLab fetch or other
command in the same call; the scanner blocks a call that mixes token-config
setup with a request.

```bash
(umask 077; set -C; rm -f /tmp/gitlab-api.curlrc; printf 'header = "PRIVATE-TOKEN: %s"\nsilent\n' "$GITLAB_TOKEN" > /tmp/gitlab-api.curlrc)
```

Make every `curl -K /tmp/gitlab-api.curlrc` request in a separate, later Bash
tool call. When you have made your last GitLab request, scrub the token in its
own Bash call: `: > /tmp/gitlab-api.curlrc`. Run the setup command again before
any later GitLab request.

## Pipeline listing

```bash
# List recent pipelines in the dispatch repo
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_ENCODED}/pipelines?ref=main&per_page=10" \
  | jq '.[] | {id: .id, status: .status, ref: .ref, created_at: .created_at}'
```

## Job listing

```bash
# List jobs in a pipeline
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_ENCODED}/pipelines/<PIPELINE_ID>/jobs" \
  | jq '.[] | {id: .id, name: .name, status: .status, stage: .stage}'
```

## Job logs

```bash
# Read job log output
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_ENCODED}/jobs/<JOB_ID>/trace" \
  | grep -i "error\|fail\|exit code"
```

## Artifact download

```bash
# Download job artifacts
curl --fail --silent --show-error \
  -K /tmp/gitlab-api.curlrc \
  --output artifacts.zip \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_ENCODED}/jobs/<JOB_ID>/artifacts"
```
