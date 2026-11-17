#!/usr/bin/env bash
# prior-triage.sh: step 2e of agents/triage.md for a GitHub issue. Reads
# every comment (all pages of the listing and of the editor query),
# decides which ones the triage App wrote and last edited, dates them, and
# prints the JSON that prior-triage.jq builds. Reads ISSUE_URL,
# FULLSEND_SLUG and FULLSEND_APP_SET. Exits 1, with "error" set, when the
# comments cannot be read.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
fail() { jq -n --arg e "$1" '{forge: "github", error: $e}'; exit 1; }

REPO=$(printf '%s\n' "${ISSUE_URL:-}" | sed -nE 's|^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/[0-9]+$|\1|p')
test -n "$REPO" || fail "ISSUE_URL is not a GitHub issue URL"
NUMBER="${ISSUE_URL##*/}"
OWNER="${REPO%/*}"
TMP=$(mktemp -d) || fail "cannot create a temporary directory"
trap 'rm -rf "$TMP"' EXIT

if ! gh api --paginate --slurp "repos/${REPO}/issues/${NUMBER}/comments?per_page=100" \
    > "$TMP/comments.json" 2> "$TMP/err" \
  || ! jq -e 'type == "array"' "$TMP/comments.json" > /dev/null 2>&1; then
  fail "cannot list the issue comments: $(head -c 300 "$TMP/err")"
fi

# Who last edited each comment: the listing does not say, so page through
# the editor query too.
TRUST_ERROR=""
QUERY='query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) { issue(number: $number) {
    comments(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { databaseId lastEditedAt editor { __typename login } } } } } }'
: > "$TMP/editors.jsonl"
AFTER=""
for _ in $(seq 1 100); do
  set -- api graphql -F "owner=${OWNER}" -F "name=${REPO#*/}" -F "number=${NUMBER}" -f "query=${QUERY}"
  test -z "$AFTER" || set -- "$@" -f "after=${AFTER}"
  if ! gh "$@" > "$TMP/page.json" 2> "$TMP/err" \
    || ! jq -e '.data.repository.issue.comments.nodes | type == "array"' "$TMP/page.json" > /dev/null 2>&1; then
    TRUST_ERROR="cannot read who last edited each comment: $(head -c 300 "$TMP/err")"
    break
  fi
  jq -c '.data.repository.issue.comments.nodes[]' "$TMP/page.json" >> "$TMP/editors.jsonl"
  AFTER=$(jq -r '.data.repository.issue.comments.pageInfo | if .hasNextPage then .endCursor // "" else "" end' "$TMP/page.json")
  test -n "$AFTER" || break
done
test -z "$AFTER" || test -n "$TRUST_ERROR" || TRUST_ERROR="editor query did not finish paging"

# Triage App names, lower case: the harness slug, <owner>-triage,
# fullsend-ai-triage and, when set, the app set's triage App.
NAMES=$(jq -nc --arg slug "${FULLSEND_SLUG:-}" --arg owner "$OWNER" --arg set "${FULLSEND_APP_SET:-}" \
  '[$slug, ($owner + "-triage"), "fullsend-ai-triage", (if $set == "" then "" else $set + "-triage" end)]
   | map(ascii_downcase | select(. != ""))')

jq -n --slurpfile pages "$TMP/comments.json" --slurpfile editors "$TMP/editors.jsonl" \
  --argjson names "$NAMES" --arg trust_error "$TRUST_ERROR" '
  def triage_name: ascii_downcase | sub("\\[bot\\]$"; "") | IN($names[]);
  ($editors | map({key: (.databaseId | tostring), value: .}) | from_entries) as $ed
  | {forge: "github",
     trust_error: (if $trust_error == "" then null else $trust_error end),
     records: [$pages[0] | add // [] | .[]
       | $ed[.id | tostring] as $e
       | {id: (.id | tostring), created: .created_at,
          edited_at: $e.lastEditedAt,
          author_ok: (.user.type == "Bot"
            and ((.performed_via_github_app.slug // .user.login // "") | triage_name)),
          edit: (if $e == null then "unknown"
                 elif $e.lastEditedAt == null then "none"
                 elif $e.editor == null then "unknown"
                 elif $e.editor.__typename == "Bot" and ($e.editor.login // "" | triage_name) then "own"
                 else "foreign" end),
          body}]}' | jq -f "$HERE/prior-triage.jq"
