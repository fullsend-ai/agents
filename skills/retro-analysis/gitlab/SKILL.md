---
name: retro-analysis-gitlab
description: >
  GitLab-specific CLI recipes for the retro-analysis skill. Use curl
  against the GitLab REST API to trace pipelines, read job logs,
  download artifacts, and search for duplicate issues on GitLab.
---

# Retro Analysis — GitLab CLI Recipes

## Environment setup

```bash
GITLAB_HOST=$(echo "${ORIGINATING_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
REPO_ENCODED=$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)
ORG=$(echo "${REPO_FULL_NAME}" | cut -d/ -f1)
DISPATCH_REPO="${ORG}/.fullsend"
DISPATCH_REPO_ENCODED=$(printf '%s' "${DISPATCH_REPO}" | jq -sRr @uri)
```

All API calls use:
```bash
curl --fail --silent --show-error \
  --connect-timeout 10 --max-time 30 \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4${ENDPOINT}"
```

## Pipeline tracing

### List recent pipelines in the dispatch project

Agent workflows run in the dispatch project (`${DISPATCH_REPO}`), not the
source project.

```bash
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_REPO_ENCODED}/pipelines?per_page=20" \
  | jq '.[] | {id: .id, status: .status, ref: .ref, created_at: .created_at}'
```

### List jobs in a pipeline

```bash
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_REPO_ENCODED}/pipelines/<PIPELINE_ID>/jobs" \
  | jq '.[] | {id: .id, name: .name, status: .status, stage: .stage}'
```

## Reading job logs

```bash
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_REPO_ENCODED}/jobs/<JOB_ID>/trace" \
  | grep -i "error\|fail\|exit code"
```

## Downloading artifacts

```bash
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  --output artifacts.zip \
  "https://${GITLAB_HOST}/api/v4/projects/${DISPATCH_REPO_ENCODED}/jobs/<JOB_ID>/artifacts"
```

## Duplicate search

Search the target project — match each proposal's `target_repo`:

```bash
TARGET_ENCODED=$(printf '%s' "<target_repo>" | jq -sRr @uri)
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${TARGET_ENCODED}/issues?search=<topic+keywords>&state=opened&per_page=20" \
  | jq '.[] | {iid: .iid, title: .title, web_url: .web_url, description: .description}'
```

Use multiple searches with different keyword combinations if the first returns no results — the same idea can be filed under different titles.

## Existing-practice search

Before proposing a governance rule about a pattern, search `target_repo` for it using the project blob search endpoint. The endpoint defaults to 20 results per page and returns raw blob hits, not deduplicated paths, so count **unique matching paths across all pages**, not raw hits on a single page — otherwise the count can look low even when many more files contradict the rule:

```bash
TARGET_ENCODED=$(printf '%s' "<target_repo>" | jq -sRr @uri)
PAGE=1
MATCHED_PATHS='[]'
AMBIGUOUS=0
while :; do
  RESPONSE=$(curl --fail --silent --show-error \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "https://${GITLAB_HOST}/api/v4/projects/${TARGET_ENCODED}/search?scope=blobs&search=gh&per_page=100&page=${PAGE}")
  RAW_COUNT=$(echo "$RESPONSE" | jq 'length')
  MATCHED_PATHS=$(jq -n --argjson acc "$MATCHED_PATHS" --argjson page "$RESPONSE" \
    '($acc + [$page[] | select(.path | endswith("SKILL.md")) | .path]) | unique')
  if [ "$RAW_COUNT" -lt 100 ]; then
    break
  fi
  PAGE=$((PAGE + 1))
  if [ "$PAGE" -gt 10 ]; then
    AMBIGUOUS=1
    break
  fi
done
UNIQUE_COUNT=$(echo "$MATCHED_PATHS" | jq 'length')
echo "$MATCHED_PATHS" | jq '.'
```

Apply the `SKILL.md`/path filter and the uniqueness count together, in the same `jq` expression that builds `MATCHED_PATHS` — filtering `path` only after a later, separate step re-introduces the undercount this recipe exists to avoid. Treat the result as ambiguous and fail closed per the shared skill's rule (the same way an API error is handled) if `AMBIGUOUS` was set (pagination was cut off before reaching a partial page) or if `UNIQUE_COUNT` equals `per_page` (100) — either case means the true count could extend beyond what was collected. This is a heuristic for the pattern token, not a parser of exact CLI invocations — review hits before counting them. If the request errors or the results look ambiguous, treat the check as failed rather than guessing at a count.
