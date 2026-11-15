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

Run both passes for every proposal — fix-keyed and root-cause-keyed (see the
retro-analysis skill's "Before proposing" section). The fix-keyed pass searches
the proposal's `target_repo`; the root-cause pass must also search the other
layer projects the localization rules can route a proposal to (platform, the
agents project, the source project), because a symptom fix and its root cause
can land in different layers. GitLab's issue search is per-project, so run the
root-cause query once per layer project and merge the results. Do not use a
group-wide search — it reaches private/unrelated sibling projects.

```bash
TARGET_ENCODED=$(printf '%s' "<target_repo>" | jq -sRr @uri)

# Fix-keyed: keywords drawn from the proposed change, open issues
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${TARGET_ENCODED}/issues?search=<fix+keywords>&state=opened&per_page=20" \
  | jq '.[] | {iid: .iid, title: .title, state: .state, web_url: .web_url, description: .description}'

# Root-cause-keyed: run once per layer project (platform, agents, source),
# encoding each path, and merge. Do not use a group-wide search. No state=opened
# — the close-reason rules must apply across layers, so this returns closed
# issues too, projecting closed_at, labels and _links.closed_as_duplicate_of
# (GitLab has no close-reason API; see the close-reason note below).
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/<layer-project-encoded>/issues?search=<subsystem+or+root-cause+keywords>&per_page=20" \
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
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${TARGET_ENCODED}/issues?search=<keywords>&per_page=20" \
  | jq '.[] | {iid: .iid, title: .title, state: .state, closed_at: .closed_at, labels: .labels, closed_as_duplicate_of: ._links.closed_as_duplicate_of, web_url: .web_url, description: .description}'

# Follow a duplicate chain to its canonical. Prefer the structured link
# (_links.closed_as_duplicate_of, added in gitlab!89375) from the projection
# above; fall back to the candidate's own description and notes for a
# "duplicate of #X" reference only when it is absent. (The duplicate points to
# the canonical, not the reverse — a search mentioning the candidate's number
# does not find its canonical.)
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${TARGET_ENCODED}/issues/<candidate-iid>" \
  | jq '{iid: .iid, title: .title, state: .state, description: .description, closed_as_duplicate_of: ._links.closed_as_duplicate_of}'
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${TARGET_ENCODED}/issues/<candidate-iid>/notes?per_page=50" \
  | jq '.[] | {body: .body}'
# Then fetch the referenced canonical directly (follow further links if it is
# itself a duplicate). Note its project: the canonical may live in another layer.
```

Use multiple searches with different keyword combinations if the first returns no results — the same idea can be filed under different titles.
