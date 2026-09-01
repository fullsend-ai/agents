---
name: jira-components
description: >-
  Use when discovering Jira project components and recommending component
  assignments for the issue being triaged. Jira-only skill using curl against
  the Jira Cloud REST API. Produces component_actions in the agent result JSON.
---

# Jira Components

Recommend component assignments for the issue being triaged. Jira projects
can have a set of first-class components that categorize issues by area of
ownership. This skill discovers the allowed components and recommends which
ones to assign.

## Step 0: Derive variables from ISSUE_URL

```bash
ISSUE_KEY=$(echo "${ISSUE_URL}" | sed -E 's|.*/browse/||')
PROJECT_KEY="${ISSUE_KEY%-*}"
```

## Step 1: Discover available components

Query the project's components from the Jira Cloud REST API:

```bash
curl --silent \
  "${JIRA_BASE_URL}/rest/api/3/project/${PROJECT_KEY}/components" \
  | jq '[.[] | {name, description}]'
```

If the project has no components, skip component assignment entirely -- do not
emit `component_actions`.

## Step 2: Check current components on the issue

```bash
curl --silent \
  "${JIRA_BASE_URL}/rest/api/3/issue/${ISSUE_KEY}?fields=components" \
  | jq '[.fields.components[].name]'
```

## Step 3: Recommend components

Based on the issue content and the available components:

- Recommend components to **add** if they clearly apply.
- Recommend components to **remove** if a previously assigned component no
  longer applies.
- If no components clearly apply, do not emit `component_actions` at all.
  Silence is better than noise.
- Only recommend components that exist in Step 1. Do not invent components.

## Output

Include your recommendations in the `component_actions` field of the agent
result JSON:

```json
"component_actions": {
  "reason": "Single sentence explaining the component choices.",
  "actions": [
    { "action": "add", "component": "backend" },
    { "action": "remove", "component": "frontend" }
  ]
}
```

Write one concise sentence for `reason` that justifies the batch. Do not
include component justifications in the `comment` field -- the pipeline
appends the reason automatically.
