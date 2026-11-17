#!/usr/bin/env bash
# shellcheck shell=bash
# prior-triage.lib.sh — Step 2e of agents/triage.md, run on the host.
#
# Bundled into pre-triage.sh. prior_triage_write reads every comment on the
# issue (all pages of the listing and of the editor query), decides which
# ones the triage account posted and last edited, dates them, cuts each at
# its first "Previous run" fold, and writes one JSON object that
# harness/triage.yaml copies into the sandbox for step 2e. A tracker error
# is written into the file and the pre-script goes on; only a job
# directory another user could control fails it (see prior_triage_write).
#
# Expected globals (set by tracker_parse_issue_url): REPO, ISSUE_NUMBER,
# and on GitLab REPO_ENCODED.
# Expected env vars: FULLSEND_TRACKER and the tracker credentials the
# triage ops use; FULLSEND_APP_SET (optional, GitHub).
#
# Upstream sources (fullsend-ai/fullsend at the version pinned in go.mod):
#   folds        internal/sticky/sticky.go BuildUpdatedBody writes
#                "Previous run", then "Previous run (2)", ..., and drops
#                the oldest of a very long comment
#   run status   internal/tracker/tracker.go StatusMarkerPrefix
#                ("fullsend:agent-status:") in comment bodies;
#                internal/tracker/jira_client.go statusPropertyKey
#                ("fullsend.agent-status") on Jira
#   Jira marker  internal/tracker/jira_client.go stickyPropertyKey
#                ("fullsend.sticky-marker")
#
# The fold cut and the Open causes / Ruled out parsing below read the
# lists the way step 2e and the sufficient action in agents/triage.md
# write them; the cause_lists judge in eval/triage/eval.yaml reads the same
# lists to grade a run, so a format change there belongs here too.

[[ -n "${PRIOR_TRIAGE_SH_LOADED:-}" ]] && return 0
PRIOR_TRIAGE_SH_LOADED=1

# prior_triage_write <file> — write the step 2e JSON to <file>.
# The file's directory is this job's own: any earlier one is removed and a
# new one is created private to this user. The harness copies whatever is
# at the path into the sandbox as this run's analysis, so anything another
# user could control there fails the pre-script (returns 1 under the
# caller's set -e): a directory this user cannot remove, one that appears
# while it is being created, or, checked again before and after the copy
# because the network reads take seconds, a directory that is no longer a
# real one this user owns or a file that is not the one this run wrote.
# Every other failure (no directory could be made, a failed write) leaves
# nothing at the path, so it ends in a warning and the run goes on without
# the file. What remains is the instant between the last check and the
# harness copying the file, which a check here cannot close.
prior_triage_write() {
  local out="$1" dir work=""
  dir=$(dirname "${out}")
  rm -rf "${dir}" 2> /dev/null || true
  if [[ -e "${dir}" || -L "${dir}" ]]; then
    echo "::error::Prior triage directory $(_gha_sanitize "${dir}") exists and cannot be removed; refusing to run with a file another user may control" >&2
    return 1
  fi
  if ! mkdir -p "$(dirname "${dir}")" 2> /dev/null || ! (umask 077 && mkdir "${dir}") 2> /dev/null; then
    if [[ -e "${dir}" || -L "${dir}" ]]; then
      echo "::error::Prior triage directory $(_gha_sanitize "${dir}") appeared while it was being created; refusing to run with a file another user may control" >&2
      return 1
    fi
    echo "::warning::Prior triage analysis not written: cannot create $(_gha_sanitize "${dir}")"
    return 0
  fi
  if ! work=$(mktemp -d 2> /dev/null); then
    rm -rf "${dir}" 2> /dev/null || true
    echo "::warning::Prior triage analysis not written: cannot create a work directory"
    return 0
  fi
  if ! (_prior_triage_run "${work}") > "${work}/out.json" 2> "${work}/log" \
    || ! jq -e 'type == "object"' "${work}/out.json" > /dev/null 2>&1; then
    _prior_triage_error "$(tail -n 3 "${work}/log" | tr '\n' ' ' | cut -c1-300)" > "${work}/out.json" 2> /dev/null || true
  fi
  if ! _prior_triage_dir_ok "${dir}"; then
    rm -rf "${work}" 2> /dev/null || true
    echo "::error::Prior triage directory $(_gha_sanitize "${dir}") changed while the comments were read; refusing to run with a file another user may control" >&2
    return 1
  fi
  (umask 077 && cp "${work}/out.json" "${out}") 2> /dev/null || true
  if cmp -s "${work}/out.json" "${out}" && _prior_triage_dir_ok "${dir}" && [[ ! -L "${out}" ]]; then
    if [[ "$(jq -r '.error // empty' "${out}" 2> /dev/null)" != "" ]]; then
      echo "::warning::Prior triage analysis written with an error: $(_gha_sanitize "$(jq -r .error "${out}")")"
    else
      echo "Prior triage analysis written to $(_gha_sanitize "${out}")."
    fi
  elif [[ -e "${out}" || -L "${out}" ]] || ! _prior_triage_dir_ok "${dir}"; then
    rm -f "${out}" 2> /dev/null || true
    rm -rf "${work}" 2> /dev/null || true
    echo "::error::Prior triage file $(_gha_sanitize "${out}") is not the one this run wrote; refusing to run with a file another user may control" >&2
    return 1
  else
    echo "::warning::Prior triage analysis not written to $(_gha_sanitize "${out}")"
  fi
  rm -rf "${work}" 2> /dev/null || true
  return 0
}

# A real directory, not a symlink, that this user owns.
_prior_triage_dir_ok() {
  [[ ! -L "$1" && -d "$1" && -O "$1" ]]
}

_prior_triage_error() {
  jq -n --arg f "${FULLSEND_TRACKER:-}" --arg e "${1:-unknown error}" \
    '{forge: $f, error: $e, trust_error: null, trusted_names: null, seen: null, analyses: [],
      baseline: null, updates: [], earlier_results: [], untrusted_marked: [], dropped_cause_candidates: []}'
}

# Runs in a subshell inside a condition, where errexit does not apply, so
# every step that can fail returns its own status.
_prior_triage_run() {
  local work="$1"
  case "${FULLSEND_TRACKER}" in
    github) _prior_triage_github "${work}" || return 1 ;;
    gitlab) _prior_triage_gitlab "${work}" || return 1 ;;
    jira) _prior_triage_jira "${work}" || return 1 ;;
    *) echo "unsupported tracker ${FULLSEND_TRACKER}" >&2; return 1 ;;
  esac
  _prior_triage_program > "${work}/select.jq" || return 1
  jq -f "${work}/select.jq" "${work}/in.json"
}

# --- GitHub ---

_prior_triage_github() {
  local work="$1" owner="${REPO%/*}" after="" trust_error="" names _
  # --paginate prints one array per page; --slurpfile below joins them.
  if ! gh api --paginate "repos/${REPO}/issues/${ISSUE_NUMBER}/comments?per_page=100" > "${work}/comments.json" \
    || ! jq -s -e 'all(type == "array")' "${work}/comments.json" > /dev/null; then
    echo "cannot list the issue comments" >&2
    return 1
  fi
  # Who last edited each comment: the listing does not say.
  local query='query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) { issue(number: $number) {
    comments(first: 100, after: $after) {
      pageInfo { hasNextPage endCursor }
      nodes { databaseId lastEditedAt editor { __typename login } } } } } }'
  : > "${work}/editors.jsonl"
  for _ in $(seq 1 100); do
    local args=(api graphql -f "owner=${owner}" -f "name=${REPO#*/}" -F "number=${ISSUE_NUMBER}" -f "query=${query}")
    [[ -z "${after}" ]] || args+=(-f "after=${after}")
    if ! gh "${args[@]}" > "${work}/page.json" 2> "${work}/gql.err" \
      || ! jq -e '.data.repository.issue.comments.nodes | type == "array"' "${work}/page.json" > /dev/null 2>&1; then
      trust_error="cannot read who last edited each comment: $(head -c 200 "${work}/gql.err")"
      break
    fi
    # Partial data next to errors may hide an editor: trust nothing then.
    if jq -e '(.errors // []) | length > 0' "${work}/page.json" > /dev/null 2>&1; then
      trust_error="editor query returned errors: $(jq -c '[.errors[].message]' "${work}/page.json" | head -c 200)"
      break
    fi
    jq -c '.data.repository.issue.comments.nodes[]' "${work}/page.json" >> "${work}/editors.jsonl"
    after=$(jq -r '.data.repository.issue.comments.pageInfo | if .hasNextPage then .endCursor // "?" else "" end' "${work}/page.json")
    if [[ "${after}" == "?" ]]; then
      trust_error="editor query reported another page without a cursor"
      break
    fi
    [[ -n "${after}" ]] || break
  done
  [[ -z "${after}" || -n "${trust_error}" ]] || trust_error="editor query did not finish paging"
  # Triage App names, lower case: the names scripts/lib/review-ops.lib.sh
  # trusts for the review App, with -triage in place of -review. The
  # harness slug (FULLSEND_SLUG) is exported only into the sandbox, so it
  # is not one of them.
  names=$(jq -nc --arg owner "${owner}" --arg set "${FULLSEND_APP_SET:-}" \
    '[($owner + "-triage"), "fullsend-ai-triage", (if $set == "" then empty else $set + "-triage" end)]
     | map(ascii_downcase) | unique')
  jq -n --slurpfile pages "${work}/comments.json" --slurpfile editors "${work}/editors.jsonl" \
    --argjson names "${names}" --arg trust_error "${trust_error}" '
    def triage_name: ascii_downcase | sub("\\[bot\\]$"; "") | IN($names[]);
    ($editors | map({key: (.databaseId | tostring), value: .}) | from_entries) as $ed
    | {forge: "github",
       trust_error: (if $trust_error == "" then null else $trust_error end),
       trusted_names: $names,
       records: [$pages | add // [] | .[]
         | $ed[.id | tostring] as $e
         | {id: (.id | tostring), created: .created_at, listed_at: .updated_at,
            edited_at: $e.lastEditedAt,
            author_ok: (.user.type == "Bot"
              and ((.performed_via_github_app.slug // .user.login // "") | triage_name)),
            author_bot: (.user.type == "Bot"),
            author_name: ((.performed_via_github_app.slug // .user.login // "") | sub("\\[bot\\]$"; "")),
            edit: (if $e == null then "unknown"
                   elif $e.lastEditedAt == null then "none"
                   elif $e.editor == null then "unknown"
                   elif $e.editor.__typename == "Bot" and ($e.editor.login // "" | triage_name) then "own"
                   else "foreign" end),
            body}]}' > "${work}/in.json"
}

# --- GitLab ---

_prior_triage_gitlab() {
  local work="$1" page=1 next count me="" trust_error="" after=null origin _
  # Notes oldest first, 100 a page. A short page is the last; a full one
  # without X-Next-Page is not.
  : > "${work}/notes.jsonl"
  while [[ -n "${page}" ]]; do
    if ! _gitlab_api GET "/projects/${REPO_ENCODED}/issues/${ISSUE_NUMBER}/notes?per_page=100&sort=asc&page=${page}" \
        -D "${work}/headers" > "${work}/page.json" \
      || ! jq -e 'type == "array"' "${work}/page.json" > /dev/null 2>&1; then
      echo "cannot list the issue notes" >&2
      return 1
    fi
    jq -c '.[]' "${work}/page.json" >> "${work}/notes.jsonl"
    next=$(tr -d '\r' < "${work}/headers" | sed -nE 's/^[Xx]-[Nn]ext-[Pp]age:[[:space:]]*([0-9]*).*/\1/p' | tail -n 1)
    count=$(jq length "${work}/page.json")
    if [[ "${count}" -lt 100 ]]; then page=""; else page="${next:-$((page + 1))}"; fi
    [[ "${page:-0}" -le 1000 ]] || { echo "too many note pages" >&2; return 1; }
  done
  # The account this token belongs to, and who last edited each note.
  : > "${work}/editors.jsonl"
  if _gitlab_api GET /user > "${work}/user.json" 2> "${work}/user.err" \
    && me=$(jq -er '.id | numbers' "${work}/user.json" 2> /dev/null); then
    origin=$(_gitlab_trusted_origin)
    for _ in $(seq 1 100); do
      jq -n --arg path "${REPO}" --arg iid "${ISSUE_NUMBER}" --argjson after "${after}" '{
        query: "query($path: ID!, $iid: String!, $after: String) { project(fullPath: $path) { issue(iid: $iid) { notes(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id lastEditedAt lastEditedBy { id } } } } } }",
        variables: {path: $path, iid: $iid, after: $after}}' > "${work}/query.json"
      if ! curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
          --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" --header "Content-Type: application/json" \
          --data @"${work}/query.json" "${origin}/api/graphql" > "${work}/page.json" 2> "${work}/gql.err" \
        || ! jq -e '.data.project.issue.notes.nodes | type == "array"' "${work}/page.json" > /dev/null 2>&1; then
        trust_error="cannot read who last edited each note: $(head -c 200 "${work}/gql.err")"
        break
      fi
      # Partial data next to errors may hide an editor: trust nothing then.
      if jq -e '(.errors // []) | length > 0' "${work}/page.json" > /dev/null 2>&1; then
        trust_error="editor query returned errors: $(jq -c '[.errors[].message]' "${work}/page.json" | head -c 200)"
        break
      fi
      jq -c '.data.project.issue.notes.nodes[]' "${work}/page.json" >> "${work}/editors.jsonl"
      after=$(jq -c '.data.project.issue.notes.pageInfo
        | if .hasNextPage then (.endCursor // "?") else null end' "${work}/page.json")
      if [[ "${after}" == '"?"' ]]; then
        trust_error="editor query reported another page without a cursor"
        break
      fi
      [[ "${after}" != null ]] || break
    done
    [[ "${after}" == null || -n "${trust_error}" ]] || trust_error="editor query did not finish paging"
  else
    me=""
    trust_error="cannot look up this token's account (GET /api/v4/user): $(head -c 200 "${work}/user.err")"
  fi
  # A gid ends in the numeric id: gid://gitlab/Note/<n>, gid://gitlab/User/<n>.
  jq -n --slurpfile notes "${work}/notes.jsonl" --slurpfile editors "${work}/editors.jsonl" \
    --arg me "${me}" --arg trust_error "${trust_error}" '
    def gid_number: tostring | sub("^.*/"; "");
    ($editors | map({key: (.id | gid_number), value: .}) | from_entries) as $ed
    | {forge: "gitlab",
       trust_error: (if $trust_error == "" then null else $trust_error end),
       trusted_names: null,
       records: [$notes[] | select(.system != true)
         | $ed[.id | tostring] as $e
         | {id: (.id | tostring), created: .created_at, listed_at: .updated_at,
            edited_at: $e.lastEditedAt,
            author_ok: ($me != "" and (.author.id | tostring) == $me),
            edit: (if $e == null then "unknown"
                   elif $e.lastEditedBy == null then "none"
                   elif ($e.lastEditedBy.id | gid_number) == $me then "own"
                   else "foreign" end),
            body}]}' > "${work}/in.json"
}

# --- Jira ---

_prior_triage_jira() {
  local work="$1" start=0 next="" me="" trust_error="" _
  # Every comment: an edited marked comment keeps its creation time, so it
  # can sit on any page. Advance by the comments actually returned.
  # A page ends the listing when it is empty, when the total is reached,
  # or, without a total, when it is short. At most 100 pages, as fullsend's
  # own Jira client (internal/forge/jira/client.go ListComments).
  : > "${work}/comments.jsonl"
  for _ in $(seq 1 100); do
    if ! _jira_api GET "/issue/${ISSUE_NUMBER}/comment?orderBy=created&startAt=${start}&maxResults=100&expand=properties" \
        > "${work}/page.json" \
      || ! jq -e '.comments | type == "array"' "${work}/page.json" > /dev/null 2>&1; then
      echo "cannot list the issue comments" >&2
      return 1
    fi
    jq -c '.comments[]' "${work}/page.json" >> "${work}/comments.jsonl"
    next=$(jq -r --argjson s "${start}" '(.comments | length) as $c | ($s + $c) as $n
      | if $c == 0 then ""
        elif (.total | type) == "number" then (if $n >= .total then "" else $n end)
        elif $c < 100 then ""
        else $n end' "${work}/page.json")
    [[ -n "${next}" ]] || break
    start="${next}"
  done
  if [[ -n "${next}" ]]; then
    echo "comment listing did not finish paging" >&2
    return 1
  fi
  if ! _jira_api GET /myself > "${work}/myself.json" 2> "${work}/myself.err" \
    || ! me=$(jq -er '.accountId | strings' "${work}/myself.json" 2> /dev/null); then
    me=""
    trust_error="cannot look up this credential's account (GET /rest/api/3/myself, needs read:jira-user): $(head -c 200 "${work}/myself.err")"
  fi
  jq -n --slurpfile comments "${work}/comments.jsonl" --arg me "${me}" --arg trust_error "${trust_error}" '
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
     trusted_names: null,
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
    > "${work}/in.json"
}

# --- Selection (all trackers) ---
#
# Input: {forge, trust_error, trusted_names, records: [{id, created,
# edited_at, author_ok, author_bot?, edit, marker?, status_note?,
# body | text + folds}]}, where edit is "none", "own" (last edited by the
# triage account), "foreign" or "unknown" (edited, editor unreadable).
_prior_triage_program() {
  cat <<'PRIOR_TRIAGE_JQ'
# An ISO 8601 time as epoch seconds: "Z", "+00:00" and "+0000" offsets,
# with or without fractional seconds.
def epoch:
  if . == null then null else
    (first(capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})T(?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>[.][0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")) // null) as $c
    | if $c == null then null else
        (($c.d + "T" + $c.t + "Z") | fromdateiso8601)
        + (if $c.f then ("0" + $c.f | tonumber) else 0 end)
        - (if ($c.z // "Z") == "Z" then 0 else
             ($c.z | gsub(":"; "")) as $z
             | (if $z[0:1] == "-" then -1 else 1 end)
               * (($z[1:3] | tonumber) * 3600 + ($z[3:5] | tonumber) * 60)
           end)
      end
  end;

# Split a markdown body at fullsend "Previous run" folds (a <details>
# whose <summary> starts with "Previous run"; sticky.go writes them most
# recent first and may cut the last one short).
def fold_re: "<details>\\s*<summary>\\s*Previous run[^<]*</summary>";
def split_folds:
  if has("text") then . else
    (.body // "" | gsub("\r"; "")) as $b
    | [$b | match(fold_re; "g") | .string | capture("<summary>\\s*(?<t>[^<]*?)\\s*</summary>").t] as $titles
    | [$b | splits(fold_re)] as $parts
    | .text = ($parts[0] | sub("\\s+$"; ""))
    | .folds = [range(0; $titles | length) as $i
        | {title: $titles[$i],
           text: ($parts[$i + 1]
             | gsub("<!-- sticky:history-(start|end) -->"; "")
             | sub("(\\s*</details>)+\\s*$"; ""))}]
  end;

# The Open causes and Ruled out lists of an analysis text, as cause names
# (each item's text before its evidence). Headings match loosely; a list
# runs to the next heading or horizontal rule.
def cause_heading($name):
  test("^\\s*(\\*\\*\\s*" + $name + "\\s*(\\([^)]*\\))?\\s*:?\\s*\\*\\*\\s*(\\([^)]*\\))?:?|#{1,6}\\s*" + $name + "\\s*(\\([^)]*\\))?\\s*:?)\\s*$"; "i");
def cause_name:
  sub("^\\s*([-*+]|[0-9]+[.)])\\s+"; "")
  | [splits("\\s[—–-]\\s|—")][0]
  | gsub("\\*\\*|`"; "")
  | sub("\\s*\\(unverified\\)\\s*$"; "")
  | sub("^\\s+"; "") | sub("\\s+$"; "");
def cause_key: ascii_downcase | gsub("\\s+"; " ") | sub("[.:;]+$"; "");
# The size fold writes the oldest Ruled out entries as one line,
# "Also ruled out (see earlier analysis): a; b; c", as a list item or a
# plain line, label bold or not, after a colon or a spaced dash. Each
# ";"-separated name on it is ruled out, each cut at its evidence like a
# list item; a plain list item such as "Alpha, Beta" stays one name. The
# cause_lists judge as fullsend-ai/agents#2062 changes it reads the fold
# line the same way.
def fold_line_re: "^\\s*(?:(?:[-*+]|[0-9]+[.)])\\s+)?\\*{0,2}also ruled out\\b[^:\\n]*?(?::\\*{0,2}|\\s[—–-]\\s|—)\\s*(?<names>.+)$";
def cause_lists:
  reduce (split("\n")[]) as $l ({sec: null, done: false, open: [], ruled_out: [], found: false};
    if .done then .
    elif ($l | cause_heading("open causes")) then .sec = "open" | .found = true
    elif ($l | cause_heading("ruled out")) then .sec = "ruled_out"
    elif .sec == null then .
    elif ($l | test("^\\s*(-{3,}|\\*{3,}|_{3,})\\s*$")) then .done = true
    elif ($l | test(fold_line_re; "i")) then
      .ruled_out += [$l | capture(fold_line_re; "i").names | split(";")[] | cause_name | select(. != "")]
    elif ($l | test("^\\s*(\\*\\*[^*]+\\*\\*\\s*(\\([^)]*\\))?:?|#{1,6}\\s.*)\\s*$")) then .sec = null
    elif ($l | test("^\\s*([-*+]|[0-9]+[.)])\\s+\\S")) then .[.sec] += [$l | cause_name]
    else . end)
  | {found, open, ruled_out};

. as $in
| ($in.records
   | map(split_folds
     | .marker = (first((.marker // .text) | capture("<!-- fullsend:(?<m>triage-[a-z0-9-]+)").m) // null)
     | .status_note = ((.status_note // false) or (.text | test("<!-- fullsend:agent-status")))
     | .dated = (if .edit == "own" then .edited_at else .created end)
     | .sort_key = [(.dated | epoch), (.created | epoch), (.id | tonumber? // 0)]
     # A date that does not parse cannot be ordered, so it is not trusted.
     | .date_bad = (.sort_key[0] == null or .sort_key[1] == null)
     # The listing and the editor query are two requests: an edit after
     # the listing has an editor time later than the listed update time,
     # and the listed body is then the old one. A few seconds of slack
     # allow for the two APIs stamping the same edit apart.
     | .raced = (.edit == "own" and .listed_at != null
                 and ((.edited_at | epoch) // 0) > ((.listed_at | epoch) // 0) + 5)
     | .trusted = ($in.trust_error == null and .author_ok and (.edit == "none" or .edit == "own")
                   and (.date_bad | not) and (.raced | not)))
   | sort_by(.sort_key)) as $all
| ($all | map(select(.trusted and .marker == "triage-agent"))) as $analyses
| ($analyses | last) as $base
# Only a baseline with lists has causes to drop; without them the rebuild
# path in step 2e reads every earlier analysis anyway.
| (if $base == null or ($base.text | cause_lists | .found | not) then [] else
     ($base.text | cause_lists | .open + .ruled_out | map(cause_key)) as $kept
     | ([$base.folds[] | {source: ($base.id + " " + .title), text}]
        + [$analyses[:-1] | reverse[]
           | .id as $id
           | {source: $id, text}, (.folds[] | {source: ($id + " " + .title), text})])
     # Keyed by cause; jq keeps insertion order, so the list stays newest first.
     | reduce (.[] | .source as $s | .text | cause_lists
               | (.open[] | {list: "open", cause: .}), (.ruled_out[] | {list: "ruled_out", cause: .})
               | .source = $s) as $e ({};
         ($e.cause | cause_key) as $k
         | if ($kept | any(. == $k)) then .
           else .[$k] = ((.[$k] // {cause: $e.cause, newest: $e.list, open_in: [], ruled_out_in: []})
                         | .[$e.list + "_in"] += [$e.source])
           end)
     | [.[]]
   end) as $dropped
| {
    forge: $in.forge,
    error: null,
    trust_error: $in.trust_error,
    trusted_names: $in.trusted_names,
    seen: {comments: ($all | length), marked: ($all | map(select(.marker != null)) | length)},
    analyses: [$analyses[] | {id, created, dated, edited: (.edit == "own"), text, folds}],
    baseline: (if $base == null then null else {id: $base.id, dated: $base.dated, has_lists: ($base.text | cause_lists | .found), text: $base.text} end),
    updates: (if $base == null then [] else
      [$all[] | select(.trusted and .marker != "triage-agent" and (.status_note | not)
                       and (.sort_key > $base.sort_key))
              | {id, dated, marker, text}] end),
    earlier_results: [$all[] | select(.trusted and .marker != "triage-agent" and .marker != "triage-in-progress"
                       and (.status_note | not)
                       and ($base == null or .sort_key <= $base.sort_key))
              | {id, dated, marker, text}],
    untrusted_marked: [$all[] | select(.marker != null and (.trusted | not))
      | {id, created, marker,
         reason: (if $in.trust_error != null then "trust unknown: " + $in.trust_error
                  elif (.author_ok | not) and .author_bot and ((.author_name // "") | ascii_downcase | endswith("-triage"))
                    then "App not in the trusted names"
                  elif (.author_ok | not) then "not posted by the triage account"
                  elif .edit == "foreign" then "last edited by someone else"
                  elif .date_bad then "date unreadable"
                  elif .raced then "edited during the read"
                  else "edited, editor unreadable" end),
         text, folds}],
    dropped_cause_candidates: $dropped
  }
PRIOR_TRIAGE_JQ
}
