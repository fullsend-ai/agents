---
name: fix-review-gitlab
description: >-
  GitLab REST API commands for fetching MR metadata and diffs in the fix agent.
  Use curl to view MR state, changes, and notes.
---

# Fix Review — GitLab API

Use `curl` with the GitLab REST API to fetch MR data for the fix agent.
The environment provides `GITLAB_TOKEN` for authentication.

Derive the API host and project path from the environment:

```bash
GITLAB_HOST=$(echo "${PR_URL}" | sed -E 's|^https://([^/]+)/.*|\1|')
REPO_ENCODED=$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)
```

## MR Metadata

```bash
# View MR with full details
curl --silent --config - \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}" \
  <<< "header = \"PRIVATE-TOKEN: ${GITLAB_TOKEN}\""
```

## MR Diff

```bash
# Fetch the current diff (changes)
curl --silent --config - \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/changes" \
  <<< "header = \"PRIVATE-TOKEN: ${GITLAB_TOKEN}\"" \
  | jq -r '.changes[] | "--- a/\(.old_path)\n+++ b/\(.new_path)\n\(.diff)"'
```

## Review findings fallback

This recovery path is GitHub-only. On GitLab, if
`/sandbox/workspace/review-body.txt` is empty, whitespace-only,
pointer-only, or under 200 bytes, log `::error::No review body found`
and continue from a human instruction or exit with disagree. Do not
re-fetch MR discussions as a substitute.

## MR Notes

```bash
# List MR notes (comments, for context on prior iterations)
curl --silent --config - \
  "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/notes?per_page=100&sort=asc" \
  <<< "header = \"PRIVATE-TOKEN: ${GITLAB_TOKEN}\""
```

## Re-check Data

The final re-check needs the current head and the notes created after the run
started, with the author and time of each.

```bash
# Scanner dialect (fullsend-ai/agents#1190): the token goes through a curl
# config file, never the command line; no `break` in a loop. Run as written.
RC=/tmp/recheck.curlrc
OLDMASK=$(umask); umask 077; printf 'header = "PRIVATE-TOKEN: %s"\nfail\nsilent\n' "$GITLAB_TOKEN" > "$RC"; umask "$OLDMASK"

# Current head SHA
curl -K "$RC" -o /tmp/recheck-head.json "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}"
NEW_HEAD_SHA=$(jq -r '.sha' /tmp/recheck-head.json)

# Notes newer than the run start, newest first. Page 1 holds the newest 100;
# when it is full and its last note is still newer than the run start, fetch
# page=2 the same way.
curl -K "$RC" -o /tmp/recheck-notes.json "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/merge_requests/${PR_NUMBER}/notes?per_page=100&sort=desc&page=1"
jq -c --arg since "$FULLSEND_RUN_STARTED_AT" '.[] | select(.system != true)
  | select((.created_at | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdate) > ($since | fromdate))
  | {username: .author.username, author_id: .author.id, at: .created_at, fullsend: ((.body // "") | contains("<!-- fullsend:")), body}' /tmp/recheck-notes.json

# The note author object has no `bot` field: for the marked notes only, look
# each author up and read it. Run as written (no `break`).
jq -r '.[] | select(.system != true) | select((.body // "") | contains("<!-- fullsend:")) | .author.id' /tmp/recheck-notes.json | sort -u > /tmp/recheck-marked-authors.txt
while read -r uid; do
  curl -K "$RC" -o "/tmp/recheck-user-${uid}.json" "https://${GITLAB_HOST}/api/v4/users/${uid}"
  jq -c '{id, username, bot}' "/tmp/recheck-user-${uid}.json"
done < /tmp/recheck-marked-authors.txt

# Delta from the dispatched head to the current one, when they differ.
# straight=true is the tree diff; the default is the merge-base diff.
curl -K "$RC" -o /tmp/recheck-compare.json "https://${GITLAB_HOST}/api/v4/projects/${REPO_ENCODED}/repository/compare?from=${FULLSEND_RUN_HEAD_SHA}&to=${NEW_HEAD_SHA}&straight=true"
jq -c '{compare_timeout, too_large: ([.diffs[] | .too_large] | any), diffs: [.diffs[] | {new_path, old_path, renamed_file, deleted_file, diff}]}' /tmp/recheck-compare.json
: > "$RC"
```

`select(.system != true)` drops GitLab's state notes. `fullsend` marks a
body carrying the marker; it excludes the note only when the author's `bot`
field on `users/:id` is true — a person's note is never excluded, marker or
not, and without that lookup a marked note is kept as context. The exact username of a bot that authored a marked note is fullsend's
login, never a pattern; `bot` tells a bot from a person, never the username's
shape, and other bots stay in as context. The `since` filter normalises GitLab's fractional seconds
and offset before comparing. The delta is complete only when
`compare_timeout` and `too_large` are both false; `fail` in the config makes
a missing SHA an error, not an empty delta. A rename carries `old_path` and an
empty `diff`.
