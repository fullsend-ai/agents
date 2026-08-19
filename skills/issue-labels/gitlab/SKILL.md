---
name: gitlab
description: >-
  Use when labeling an issue or merge request based on its content and the
  project's label conventions, or when delegated to by the review or
  triage agent. Discover project labels and recommend contextual labels
  to add or remove on issues and merge requests. GitLab variant using curl
  against the GitLab REST API. Produces label_actions in the agent result
  JSON.
---

# Issue Labels (GitLab)

Recommend contextual labels for the issue or merge request being processed.
These are labels that describe the domain, area, priority, or other
team-specific dimensions -- NOT control labels used by agent pipelines.

Control labels are managed by each agent's post-script and will be refused
server-side if recommended. You do not need to track which labels are
control labels -- just recommend what fits and the pipeline will filter.

## Step 0: Derive project variables from ISSUE_URL

```bash
# Extract host, project path, and issue IID from the ISSUE_URL env var.
GITLAB_HOST=$(echo "${ISSUE_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
REPO=$(echo "${ISSUE_URL}" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
REPO_ENCODED=$(printf '%s' "${REPO}" | jq -sRr @uri)
ISSUE_NUMBER=$(basename "${ISSUE_URL}")
```

## Step 1: Discover available labels

```bash
curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/labels?per_page=100" \
  | jq '[.[] | {name, description}]'
```

If the project has no labels beyond those used by agent pipelines, skip labeling
entirely -- do not emit `label_actions`.

## Step 2: Research labeling conventions

Spawn a sub-agent to investigate how labels have been applied to recent issues.
The sub-agent should:

1. Query recent closed and open issues:
   ```bash
   curl --silent --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
     "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/issues?per_page=50&order_by=updated_at&sort=desc" \
     | jq '[.[] | {iid, title, labels}]'
   ```
2. Analyze which labels appear together and in what contexts.
3. Return a short summary (under 500 characters) describing the labeling
   conventions observed -- which labels are commonly used and any patterns in
   how they are applied.

Do not dump raw issue data into the parent context. Only use the sub-agent's
summary to inform your recommendations.

## Step 3: Recommend labels

Based on the content, the available labels, and the observed conventions:

- Recommend labels to **add** if they clearly apply.
- Recommend labels to **remove** if stale labels from a prior run no longer
  apply.
- If no labels clearly apply, do not emit `label_actions` at all. Silence is
  better than noise.
- Only recommend labels that exist in the project's label list. Do not invent labels.

## Output

Include your recommendations in the `label_actions` field of the agent result
JSON:

```json
"label_actions": {
  "reason": "Single sentence explaining the label choices for the whole batch.",
  "actions": [
    { "action": "add", "label": "area/api" },
    { "action": "remove", "label": "area/cli" }
  ]
}
```

Write one concise sentence for `reason` that justifies the batch. Do not
include label justifications in the `comment` field -- the pipeline appends the
reason automatically.
