#!/usr/bin/env bash
# prior-triage.sh: step 2e of agents/triage.md for a Jira issue. Reads
# every comment page with its properties, decides which ones this
# credential's account wrote and last edited, dates them, renders each
# body (Atlassian Document Format) as text split at its "Previous run"
# folds, and prints the JSON that prior-triage.jq builds. Reads ISSUE_URL,
# JIRA_TOKEN, JIRA_USER_EMAIL, JIRA_API_URL and JIRA_BASE_URL. Exits 1,
# with "error" set, when the comments cannot be read.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
fail() { jq -n --arg e "$1" '{forge: "jira", error: $e}'; exit 1; }

ISSUE_KEY="${ISSUE_URL:-}"
ISSUE_KEY="${ISSUE_KEY##*/browse/}"
printf '%s' "$ISSUE_KEY" | grep -Eq '^[A-Z][A-Z0-9_]*-[0-9]+$' || fail "ISSUE_URL is not a Jira issue URL"
BASE="${JIRA_API_URL:-${JIRA_BASE_URL:-}}"
test -n "$BASE" || fail "neither JIRA_API_URL nor JIRA_BASE_URL is set"
# Basic auth for a bot user with an email, Bearer for a service account.
JIRA_EMAIL="${JIRA_USER_EMAIL:-}"; JIRA_EMAIL="${JIRA_EMAIL//[[:space:]]/}"
JIRA_AUTH_FLAG=--oauth2-bearer; test -n "${JIRA_EMAIL}" && JIRA_AUTH_FLAG=--user
JIRA_AUTH="${JIRA_EMAIL:+${JIRA_EMAIL}:}${JIRA_TOKEN:-}"
TMP=$(mktemp -d) || fail "cannot create a temporary directory"
trap 'rm -rf "$TMP"' EXIT
jira() { curl --fail-with-body --silent --show-error "${JIRA_AUTH_FLAG}" "${JIRA_AUTH}" "${BASE}/rest/api/3/$1"; }

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
  def epoch: (first(capture("^(?<d>[^T]+)T(?<t>[0-9:]{8})(?<f>[.][0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")) // null) as $c
    | if $c == null then null else
        (($c.d + "T" + $c.t + "Z") | fromdateiso8601) + (if $c.f then ("0" + $c.f | tonumber) else 0 end)
        - (if ($c.z // "Z") == "Z" then 0 else ($c.z | gsub(":"; "")) as $z
             | (if $z[0:1] == "-" then -1 else 1 end) * (($z[1:3] | tonumber) * 3600 + ($z[3:5] | tonumber) * 60) end)
      end;
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
     | ((.updated | epoch) > (.created | epoch)) as $edited
     | {id: (.id | tostring), created, edited_at: .updated,
        author_ok: ($me != "" and .author.accountId == $me),
        edit: (if ($edited | not) then "none"
               elif .updateAuthor.accountId == null then "unknown"
               elif .updateAuthor.accountId == $me then "own"
               else "foreign" end),
        marker: (first(.properties[]? | select(.key == "fullsend.sticky-marker") | .value.marker | strings) // null),
        text: ($nodes[:$cut] | render),
        folds: [$nodes[$cut:][] | select(is_fold) | {title: .attrs.title, text: (.content | render)}]}]}' \
  | jq -f "$HERE/prior-triage.jq"
