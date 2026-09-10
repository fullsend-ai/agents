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
GITLAB_HOST=$(echo "${ORIGINATING_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
DISPATCH_ENCODED=$(printf '%s' "${DISPATCH_REPO}" | jq -sRr @uri)
REPO_ENCODED=$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)
```

## Pipeline listing

```bash
# List recent pipelines in the dispatch repo
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_ENCODED}/pipelines?ref=main&per_page=10" \
  | jq '.[] | {id: .id, status: .status, ref: .ref, created_at: .created_at}'
```

## Job listing

```bash
# List jobs in a pipeline
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_ENCODED}/pipelines/<PIPELINE_ID>/jobs" \
  | jq '.[] | {id: .id, name: .name, status: .status, stage: .stage}'
```

## Job logs

```bash
# Read job log output
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_ENCODED}/jobs/<JOB_ID>/trace" \
  | grep -i "error\|fail\|exit code"
```

## Artifact download

```bash
# Download job artifacts
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --output artifacts.zip \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_ENCODED}/jobs/<JOB_ID>/artifacts"
```
