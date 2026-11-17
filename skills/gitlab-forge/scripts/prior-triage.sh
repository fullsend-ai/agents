#!/usr/bin/env bash
# prior-triage.sh: step 2e of agents/triage.md for a GitLab issue. Reads
# every note (all pages of the listing and of the editor query), decides
# which ones this token's account wrote and last edited, dates them, and
# prints the JSON that prior-triage.jq builds. Reads ISSUE_URL and
# GITLAB_TOKEN. Exits 1, with "error" set, when the notes cannot be read.
set -u -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
fail() {
  jq -n --arg e "$1" '{forge: "gitlab", error: $e, trust_error: null, trusted_names: null, analyses: [],
    baseline: null, updates: [], untrusted_marked: [], dropped_cause_candidates: []}'
  exit 1
}

HOST=$(printf '%s\n' "${ISSUE_URL:-}" | sed -nE 's|^https://([A-Za-z0-9.-]+)/.+/-/issues/[0-9]+$|\1|p')
PROJECT=$(printf '%s\n' "${ISSUE_URL:-}" | sed -nE 's|^https://[^/]+/(.+)/-/issues/[0-9]+$|\1|p')
if test -z "$HOST" || test -z "$PROJECT"; then fail "ISSUE_URL is not a GitLab issue URL"; fi
IID="${ISSUE_URL##*/}"
ENCODED=$(printf '%s' "$PROJECT" | jq -sRr @uri)
API="https://${HOST}/api/v4"
TMP=$(mktemp -d) || fail "cannot create a temporary directory"
trap 'rm -rf "$TMP"' EXIT
# The token goes in a curl config file, never on a command line.
(umask 077; printf 'header = "PRIVATE-TOKEN: %s"\nsilent\nshow-error\nfail\n' "${GITLAB_TOKEN:-}" > "$TMP/curlrc")

# Notes oldest first, 100 a page, until X-Next-Page is empty.
: > "$TMP/notes.jsonl"
PAGE=1
while test -n "$PAGE"; do
  if ! curl -K "$TMP/curlrc" -D "$TMP/headers" \
      "${API}/projects/${ENCODED}/issues/${IID}/notes?per_page=100&sort=asc&page=${PAGE}" \
      > "$TMP/page.json" 2> "$TMP/err" \
    || ! jq -e 'type == "array"' "$TMP/page.json" > /dev/null 2>&1; then
    fail "cannot list the issue notes: $(head -c 300 "$TMP/err")"
  fi
  jq -c '.[]' "$TMP/page.json" >> "$TMP/notes.jsonl"
  # A short page is the last; a full one without X-Next-Page is not.
  NEXT=$(tr -d '\r' < "$TMP/headers" | sed -nE 's/^[Xx]-[Nn]ext-[Pp]age:[[:space:]]*([0-9]*).*/\1/p' | tail -n 1)
  if test "$(jq length "$TMP/page.json")" -lt 100; then PAGE=""; else PAGE="${NEXT:-$((PAGE + 1))}"; fi
  test "${PAGE:-0}" -le 1000 || fail "too many note pages"
done

# The account this token belongs to, and who last edited each note.
TRUST_ERROR=""
ME=""
if curl -K "$TMP/curlrc" "${API}/user" > "$TMP/user.json" 2> "$TMP/err" \
  && ME=$(jq -er '.id | numbers' "$TMP/user.json" 2> /dev/null); then
  : > "$TMP/editors.jsonl"
  AFTER=null
  for _ in $(seq 1 100); do
    jq -n --arg path "$PROJECT" --arg iid "$IID" --argjson after "$AFTER" '{
      query: "query($path: ID!, $iid: String!, $after: String) { project(fullPath: $path) { issue(iid: $iid) { notes(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id lastEditedAt lastEditedBy { id } } } } } }",
      variables: {path: $path, iid: $iid, after: $after}}' > "$TMP/query.json"
    if ! curl -K "$TMP/curlrc" --header "Content-Type: application/json" --data @"$TMP/query.json" \
        "https://${HOST}/api/graphql" > "$TMP/page.json" 2> "$TMP/err" \
      || ! jq -e '.data.project.issue.notes.nodes | type == "array"' "$TMP/page.json" > /dev/null 2>&1; then
      TRUST_ERROR="cannot read who last edited each note: $(head -c 300 "$TMP/err")"
      break
    fi
    jq -c '.data.project.issue.notes.nodes[]' "$TMP/page.json" >> "$TMP/editors.jsonl"
    AFTER=$(jq -c '.data.project.issue.notes.pageInfo | if .hasNextPage and .endCursor then .endCursor else null end' "$TMP/page.json")
    test "$AFTER" != null || break
  done
  test "$AFTER" = null || test -n "$TRUST_ERROR" || TRUST_ERROR="editor query did not finish paging"
else
  TRUST_ERROR="cannot look up this token's account (GET /api/v4/user): $(head -c 300 "$TMP/err")"
  : > "$TMP/editors.jsonl"
fi

# A gid ends in the numeric id: gid://gitlab/Note/<n>, gid://gitlab/User/<n>.
jq -n --slurpfile notes "$TMP/notes.jsonl" --slurpfile editors "$TMP/editors.jsonl" \
  --arg me "$ME" --arg trust_error "$TRUST_ERROR" '
  def gid_number: tostring | sub("^.*/"; "");
  ($editors | map({key: (.id | gid_number), value: .}) | from_entries) as $ed
  | {forge: "gitlab",
     trust_error: (if $trust_error == "" then null else $trust_error end),
     records: [$notes[] | select(.system != true)
       | $ed[.id | tostring] as $e
       | {id: (.id | tostring), created: .created_at,
          edited_at: $e.lastEditedAt,
          author_ok: ($me != "" and (.author.id | tostring) == $me),
          edit: (if $e == null then "unknown"
                 elif $e.lastEditedBy == null then "none"
                 elif ($e.lastEditedBy.id | gid_number) == $me then "own"
                 else "foreign" end),
          body}]}' \
  > "$TMP/in.json" 2> "$TMP/err" || fail "cannot read the comments: $(head -c 300 "$TMP/err")"
jq -f "$HERE/prior-triage.jq" "$TMP/in.json" > "$TMP/out.json" 2> "$TMP/err" \
  || fail "cannot build the result: $(head -c 300 "$TMP/err")"
cat "$TMP/out.json"
