# prior-triage.jq: the forge-neutral half of step 2e of agents/triage.md.
# The github, gitlab and jira forge skills each carry an identical copy
# (scripts/prior-triage-test.sh checks that they match); each forge's
# prior-triage.sh reads the comments and passes them in as
#   {forge, trust_error, records: [{id, created, edited_at, author_ok,
#    edit, marker?, body | text + folds}]}
# where edit is "none", "own" (last edited by the triage account),
# "foreign" or "unknown" (edited, editor unreadable), and body is
# markdown (github, gitlab) or text and folds are already rendered (jira).

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

# Split a markdown body at fullsend's "Previous run" folds (a <details>
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
             | sub("\\s*</details>\\s*$"; ""))}]
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
def cause_lists:
  reduce (split("\n")[]) as $l ({sec: null, done: false, open: [], ruled_out: [], found: false};
    if .done then .
    elif ($l | cause_heading("open causes")) then .sec = "open" | .found = true
    elif ($l | cause_heading("ruled out")) then .sec = "ruled_out"
    elif .sec == null then .
    elif ($l | test("^\\s*(-{3,}|\\*{3,}|_{3,})\\s*$")) then .done = true
    elif ($l | test("^\\s*(\\*\\*[^*]+\\*\\*\\s*(\\([^)]*\\))?:?|#{1,6}\\s.*)\\s*$")) then .sec = null
    elif ($l | test("^\\s*([-*+]|[0-9]+[.)])\\s+\\S")) then .[.sec] += [$l | cause_name]
    else . end)
  | {found, open, ruled_out};

. as $in
| ($in.records
   | map(split_folds
     | .marker = (first((.marker // .text) | capture("<!-- fullsend:(?<m>triage-[a-z0-9-]+)").m) // null)
     | .status_note = (.text | test("<!-- fullsend:agent-status"))
     | .trusted = ($in.trust_error == null and .author_ok and (.edit == "none" or .edit == "own"))
     | .dated = (if .edit == "own" then .edited_at else .created end)
     | .sort_key = [(.dated | epoch), (.created | epoch), (.id | tonumber? // 0)])
   | sort_by(.sort_key)) as $all
| ($all | map(select(.trusted and .marker == "triage-agent"))) as $analyses
| ($analyses | last) as $base
| (if $base == null then [] else
     ($base.text | cause_lists | .open + .ruled_out | map(cause_key)) as $kept
     | ([$base.folds[] | {source: ($base.id + " " + .title), text}]
        + [$analyses[:-1] | reverse[]
           | .id as $id
           | {source: $id, text}, (.folds[] | {source: ($id + " " + .title), text})])
     | reduce (.[] | .source as $s | .text | cause_lists
               | (.open[] | {list: "open", cause: .}), (.ruled_out[] | {list: "ruled_out", cause: .})
               | .source = $s) as $e ([];
         ($e.cause | cause_key) as $k
         | if ($kept | index([$k])) != null then .
           else (map(.key) | index($k)) as $i
             | if $i == null then . + [{key: $k, cause: $e.cause, open_in: [], ruled_out_in: []}] else . end
             | (map(.key) | index($k)) as $j
             | .[$j][$e.list + "_in"] += [$e.source]
           end)
     | map(del(.key))
   end) as $dropped
| {
    forge: $in.forge,
    error: null,
    trust_error: $in.trust_error,
    analyses: [$analyses[] | {id, created, dated, edited: (.edit == "own")}],
    baseline: (if $base == null then null else {id: $base.id, dated: $base.dated, has_lists: ($base.text | cause_lists | .found), text: $base.text} end),
    updates: (if $base == null then [] else
      [$all[] | select(.trusted and .marker != "triage-agent" and (.status_note | not)
                       and (.sort_key > $base.sort_key))
              | {id, dated, marker, text}] end),
    untrusted_marked: [$all[] | select(.marker != null and (.trusted | not))
      | {id, marker,
         reason: (if $in.trust_error != null then "trust unknown: " + $in.trust_error
                  elif (.author_ok | not) then "not posted by the triage account"
                  elif .edit == "foreign" then "last edited by someone else"
                  else "edited, editor unreadable" end)}],
    dropped_cause_candidates: $dropped
  }
