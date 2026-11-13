---
name: issue-labels
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

## Step 0: Request values

Run this first, in its own Bash tool call, before any other GitLab command.
It derives the host, project path, and issue IID from `ISSUE_URL` and prints
them:

```bash
GITLAB_HOST=$(printf '%s\n' "$ISSUE_URL" | sed -nE 's|^https://([^/]+)/.*|\1|p')
REPO=$(printf '%s\n' "$ISSUE_URL" | sed -E 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|')
REPO_ENCODED=$(printf '%s' "$REPO" | jq -sRr @uri)
ISSUE_NUMBER="${ISSUE_URL##*/}"
test -n "${GITLAB_HOST}" || echo "GITLAB_HOST is empty: ISSUE_URL is unset or not an https URL" >&2
if printf '%s' "${GITLAB_HOST}" | grep -Eqz '^[A-Za-z0-9.-]+$' && printf '%s' "${ISSUE_NUMBER}" | grep -Eqz '^[0-9]+$'; then
  printf 'GITLAB_HOST=%s\nREPO_ENCODED=%s\nISSUE_NUMBER=%s\n' "${GITLAB_HOST}" "${REPO_ENCODED}" "${ISSUE_NUMBER}"
else
  echo "GITLAB_HOST is not a plain hostname or ISSUE_NUMBER is not numeric" >&2
fi
```

If it printed no values, make no request and skip labeling. Otherwise, write
the printed values literally into every request URL below in place of
`<GITLAB_HOST>` and `<REPO_ENCODED>`. Never write `${GITLAB_HOST}` in a request
URL: the sandbox's SSRF check reads the URL before shell expansion and blocks
it (see the `gitlab` forge skill).

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
may share one call.

## Step 1: Discover available labels

```bash
curl -K /tmp/gitlab-api.curlrc \
  "https://<GITLAB_HOST>/api/v4/projects/<REPO_ENCODED>/labels?per_page=100" \
  | jq '[.[] | {name, description}]'
```

If the project has no labels beyond those used by agent pipelines, skip labeling
entirely -- do not emit `label_actions`.

## Step 2: Research labeling conventions

Spawn a sub-agent to investigate how labels have been applied to recent issues.
Put the printed `GITLAB_HOST` and `REPO_ENCODED` values literally in its
prompt. The sub-agent should:

1. Query recent closed and open issues:
   ```bash
   curl -K /tmp/gitlab-api.curlrc \
     "https://<GITLAB_HOST>/api/v4/projects/<REPO_ENCODED>/issues?per_page=50&order_by=updated_at&sort=desc" \
     | jq '[.[] | {iid, title, labels}]'
   ```
2. Analyze which labels appear together and in what contexts.
3. Return a short summary (under 500 characters) describing the labeling
   conventions observed -- which labels are commonly used and any patterns in
   how they are applied.

Do not dump raw issue data into the parent context. Only use the sub-agent's
summary to inform your recommendations.

After the sub-agent returns, scrub the token in its own Bash call:
`: > /tmp/gitlab-api.curlrc`. Run the token setup command again before any
later GitLab request.

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
