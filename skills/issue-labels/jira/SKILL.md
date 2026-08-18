---
name: issue-labels
description: >-
  Discover labels already in use and recommend contextual labels to add or
  remove on Jira issues. Jira variant using curl against the Jira Cloud REST
  API. Produces label_actions in the agent result JSON.
---

# Issue Labels (Jira)

Recommend contextual labels for the issue being processed. These are labels
that describe the domain, area, priority, or other team-specific dimensions
-- NOT control labels used by agent pipelines.

Control labels are managed by each agent's post-script and will be refused
server-side if recommended. You do not need to track which labels are
control labels -- just recommend what fits and the pipeline will filter.

## Step 0: Derive variables from ISSUE_URL

```bash
ISSUE_KEY=$(echo "${ISSUE_URL}" | sed -E 's|.*/browse/||')
PROJECT_KEY="${ISSUE_KEY%-*}"
```

## Step 1: Discover labels already in use

Jira has no per-project label registry like GitHub/GitLab -- any string is a
valid label with no creation step. As the closest analog to "labels the
maintainers already established," list labels already used anywhere on the
Jira site via the global label-suggestion endpoint (paginate with `startAt`
until `isLast` is `true`):

```bash
curl --silent --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
  "${JIRA_BASE_URL}/rest/api/3/label?startAt=0&maxResults=200" \
  | jq -r '.values[]'
```

If the site has no labels beyond those used by agent pipelines, skip
labeling entirely -- do not emit `label_actions`.

## Step 2: Research labeling conventions

Spawn a sub-agent to investigate how labels have been applied to recent
issues in the project. The sub-agent should:

1. Query recent issues via JQL:
   ```bash
   curl --fail-with-body --silent --user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}" \
     --header "Content-Type: application/json" \
     --get --data-urlencode "jql=project = ${PROJECT_KEY} ORDER BY updated DESC" \
     --data-urlencode "maxResults=50" \
     --data-urlencode "fields=summary,labels" \
     "${JIRA_BASE_URL}/rest/api/3/search/jql"
   ```
2. Analyze which labels appear together and in what contexts.
3. Return a short summary (under 500 characters) describing the labeling
   conventions observed -- which labels are commonly used and any patterns in
   how they are applied.

Do not dump raw issue data into the parent context. Only use the sub-agent's
summary to inform your recommendations.

## Step 3: Recommend labels

Based on the content, the labels already in use, and the observed
conventions:

- Recommend labels to **add** if they clearly apply.
- Recommend labels to **remove** if stale labels from a prior run no longer
  apply.
- If no labels clearly apply, do not emit `label_actions` at all. Silence is
  better than noise.
- Only recommend labels already seen in Step 1. Do not invent labels.
- Jira label names cannot contain spaces -- use hyphens or underscores
  (e.g. `area-api`, not `area api`).

## Output

Include your recommendations in the `label_actions` field of the agent result
JSON:

```json
"label_actions": {
  "reason": "Single sentence explaining the label choices for the whole batch.",
  "actions": [
    { "action": "add", "label": "area-api" },
    { "action": "remove", "label": "area-cli" }
  ]
}
```

Write one concise sentence for `reason` that justifies the batch. Do not
include label justifications in the `comment` field -- the pipeline appends the
reason automatically.
