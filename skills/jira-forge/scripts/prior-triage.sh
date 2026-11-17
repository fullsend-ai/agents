#!/usr/bin/env bash
# prior-triage.sh: step 2e of agents/triage.md for a Jira issue. Reads
# every comment page with its properties, decides which ones this
# credential's account wrote and last edited, dates them, renders each
# body (Atlassian Document Format) as text split at its "Previous run"
# folds, and prints the JSON that prior-triage.jq builds. Reads ISSUE_URL,
# JIRA_TOKEN, JIRA_USER_EMAIL, JIRA_API_URL and JIRA_BASE_URL. Exits 1,
# with "error" set, when the comments cannot be read.
set -u -o pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
fail() {
  jq -n --arg e "$1" '{forge: "jira", error: $e, trust_error: null, trusted_names: null, analyses: [],
    baseline: null, updates: [], untrusted_marked: [], dropped_cause_candidates: []}'
  exit 1
}

ISSUE_KEY="${ISSUE_URL:-}"
ISSUE_KEY="${ISSUE_KEY##*/browse/}"
printf '%s' "$ISSUE_KEY" | grep -Eq '^[A-Z][A-Z0-9_]*-[0-9]+$' || fail "ISSUE_URL is not a Jira issue URL"
BASE="${JIRA_API_URL:-${JIRA_BASE_URL:-}}"
test -n "$BASE" || fail "neither JIRA_API_URL nor JIRA_BASE_URL is set"
TMP=$(mktemp -d) || fail "cannot create a temporary directory"
trap 'rm -rf "$TMP"' EXIT
# The two credential modes of scripts/lib/jira-auth.lib.sh: Basic with
# email:token for a bot user, Bearer with the token for a service account
# (an email that is empty or only whitespace). The credential goes in a
# curl config file, never on a command line.
JIRA_EMAIL="${JIRA_USER_EMAIL:-}"
JIRA_EMAIL="${JIRA_EMAIL#"${JIRA_EMAIL%%[![:space:]]*}"}"
JIRA_EMAIL="${JIRA_EMAIL%"${JIRA_EMAIL##*[![:space:]]}"}"
test -n "${JIRA_TOKEN:-}" || fail "the Jira token is empty"
quote() { printf '%s' "$1" | sed 's/[\\"]/\\&/g'; }
(
  umask 077
  if test -n "$JIRA_EMAIL"; then
    printf 'user = "%s:%s"\n' "$(quote "$JIRA_EMAIL")" "$(quote "$JIRA_TOKEN")"
  else
    printf 'oauth2-bearer = "%s"\n' "$(quote "$JIRA_TOKEN")"
  fi > "$TMP/curlrc"
)
jira() { curl -K "$TMP/curlrc" --fail-with-body --silent --show-error "${BASE}/rest/api/3/$1"; }

# Every comment: an edited marked comment keeps its creation time, so it
# can sit on any page.
: > "$TMP/comments.jsonl"
START=0
while :; do
  if ! jira "issue/${ISSUE_KEY}/comment?orderBy=created&startAt=${START}&maxResults=100&expand=properties" \
      > "$TMP/page.json" 2> "$TMP/err" \
    || ! jq -e '.comments | type == "array"' "$TMP/page.json" > /dev/null 2>&1; then
    fail "cannot list the issue comments: $(head -c 300 "$TMP/err") $(head -c 300 "$TMP/page.json")"
  fi
  jq -c '.comments[]' "$TMP/page.json" >> "$TMP/comments.jsonl"
  NEXT=$(jq -r --argjson s "$START" '(.startAt // $s) + (.maxResults // (.comments | length)) as $n
    | if (.comments | length) == 0 or $n >= (.total // 0) then "" else $n end' "$TMP/page.json")
  test -n "$NEXT" || break
  test "$NEXT" -gt "$START" || fail "comment paging did not advance"
  START=$NEXT
done

TRUST_ERROR=""
ME=""
if ! jira myself > "$TMP/myself.json" 2> "$TMP/err" \
  || ! ME=$(jq -er '.accountId | strings' "$TMP/myself.json" 2> /dev/null); then
  TRUST_ERROR="cannot look up this credential's account (GET /rest/api/3/myself, needs read:jira-user): $(head -c 300 "$TMP/err")"
  ME=""
fi

jq -n --slurpfile comments "$TMP/comments.jsonl" --arg me "$ME" --arg trust_error "$TRUST_ERROR" '
  # Document text as markdown-like lines: bold as **...**, headings as #,
  # list items as "- ", a rule as ---.
  def inline: [.. | objects | select(.type == "text")
    | if any(.marks[]?; .type == "strong") then "**" + .text + "**" else .text end] | join("");
  def lines:
    if .type == "heading" then ("#" * (.attrs.level // 1)) + " " + inline
    elif .type == "bulletList" or .type == "orderedList" then .content[]? | "- " + inline
    elif .type == "rule" then "---"
    elif .type == "expand" or .type == "nestedExpand" or .type == "panel" then .content[]? | lines
    else inline end;
  def render: [.[]? | lines] | join("\n");
  def is_fold: .type == "expand" and ((.attrs.title // "") | startswith("Previous run"));
  {forge: "jira",
   trust_error: (if $trust_error == "" then null else $trust_error end),
   records: [$comments[]
     | (.body.content // []) as $nodes
     | (first(range(0; $nodes | length) as $i | select($nodes[$i] | is_fold) | $i) // ($nodes | length)) as $cut
     # Jira keeps updated equal to created until someone edits the comment.
     | ((.updated // .created) != .created) as $edited
     | {id: (.id | tostring), created, edited_at: (.updated // .created),
        author_ok: ($me != "" and .author.accountId == $me),
        edit: (if ($edited | not) then "none"
               elif .updateAuthor.accountId == null then "unknown"
               elif .updateAuthor.accountId == $me then "own"
               else "foreign" end),
        marker: (first(.properties[]? | select(.key == "fullsend.sticky-marker") | .value.marker | strings) // null),
        status_note: any(.properties[]?; .key == "fullsend.agent-status"),
        text: ($nodes[:$cut] | render),
        folds: [$nodes[$cut:][] | select(is_fold) | {title: .attrs.title, text: (.content | render)}]}]}' \
  > "$TMP/in.json" 2> "$TMP/err" || fail "cannot read the comments: $(head -c 300 "$TMP/err")"
jq -f "$HERE/prior-triage.jq" "$TMP/in.json" > "$TMP/out.json" 2> "$TMP/err" \
  || fail "cannot build the result: $(head -c 300 "$TMP/err")"
cat "$TMP/out.json"
