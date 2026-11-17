#!/usr/bin/env bash
# shellcheck shell=bash
# triage-state.lib.sh — The triage state a re-triage run starts from
# (fullsend-ai/agents#2042).
#
# A sufficient result carries triage_summary.open_causes and
# triage_summary.ruled_out, each a list of {cause, evidence, verified}. The
# post-script lists them in the comment for people and stores them as data
# for the next run: on GitHub and GitLab as a hidden HTML comment at the end
# of the comment body,
#
#   <!-- triage-state-v1:<base64 of {"open_causes":[...],"ruled_out":[...]}> -->
#
# and on Jira, which has no hidden text in ADF, as the comment entity
# property fullsend.triage-state (see jira-triage-ops.lib.sh).
#
# The marker is not in fullsend's "<!-- fullsend:" namespace on purpose:
# `fullsend post-comment` escapes every such marker in the body it is given,
# so only its own marker stays live. Trust in this one comes from the
# comment's author, which the agent checks (agents/triage.md step 2e), and
# from triage_state_neutralize, which escapes any copy the agent wrote.
#
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${TRIAGE_STATE_SH_LOADED:-}" ]] && return 0
TRIAGE_STATE_SH_LOADED=1

# The readable comment cap from agents/triage.md. It applies to everything
# posted except the hidden state marker: the agent's comment, the lists and
# the footers (see triage_state_compose).
TRIAGE_STATE_READABLE_CAP=4000
# Jira caps an entity property value at 32768 bytes; keep the state under it
# with room to spare (only multibyte text can come near it).
TRIAGE_STATE_MAX_BYTES=30000

# triage_state_json RESULT_FILE — print the state as compact JSON, bounded
# to the schema's limits (newlines folded, strings and lists cut, ruled_out
# keeping its newest entries), or nothing when the result has no open cause.
triage_state_json() {
  jq -c '
    def text($n):
      (if type == "string" then . else "" end)
      | gsub("[\\r\\n\\t]+"; " ") | gsub("^ +| +$"; "")
      | if length > $n then .[0:($n - 1)] + "…" else . end;
    def causes:
      (if type == "array" then . else [] end)
      | map(select(type == "object")
            | {cause: (.cause | text(200)), evidence: (.evidence | text(300)), verified: (.verified == true)}
            | select(.cause != ""));
    (.triage_summary // {}) as $s
    | {open_causes: ($s.open_causes | causes | .[0:10]),
       ruled_out: ($s.ruled_out | causes | if length > 25 then .[(length - 25):] else . end)}
    # Only multibyte text can push the state past the byte cap: drop the
    # oldest ruled-out entries until it fits.
    | until((tojson | utf8bytelength) <= $max_bytes or (.ruled_out | length) == 0; .ruled_out |= .[1:])
    | if (.open_causes | length) == 0 then empty else . end
  ' --argjson max_bytes "${TRIAGE_STATE_MAX_BYTES}" "$1"
}

# triage_state_compose STATE_JSON AGENT_COMMENT FOOTER — print the readable
# comment that is posted: AGENT_COMMENT, the lists, then FOOTER (the labels,
# components and next-steps sections the post-script appended), within
# TRIAGE_STATE_READABLE_CAP characters. The lists are one line per cause,
# unverified causes marked, "Ruled out" left out when empty. When the whole
# does not fit, the lists are condensed in this order: ruled-out evidence,
# all evidence, the oldest ruled-out lines (counted in one line), then the
# open cause names are cut to 80 characters. If it still does not fit, the
# agent's comment is cut, and as a last resort the whole text, each with a
# note saying so. The stored state always keeps every entry.
triage_state_compose() {
  jq -rn --argjson state "$1" --arg agent "$2" --arg footer "$3" \
    --argjson cap "${TRIAGE_STATE_READABLE_CAP}" '
    def safe: gsub("<!--"; "&lt;!--");
    def clip($n): if length > $n then .[0:($n - 1)] + "…" else . end;
    def line($full; $name_max):
      "- " + (.cause | clip($name_max) | safe)
      + (if .verified then "" else " _(unverified)_" end)
      + (if $full and .evidence != "" then " — " + (.evidence | clip(160) | safe) else "" end);
    def render($o; $r; $full_open; $full_ruled; $hidden; $name_max):
      "**Open causes:**\n" + ($o | map(line($full_open; $name_max)) | join("\n"))
      + (if ($r | length) + $hidden > 0 then
           "\n\n**Ruled out:**\n"
           + ((if $hidden > 0 then ["- \($hidden) earlier ruled-out cause(s) not listed here; the triage state keeps them"] else [] end)
              + ($r | map(line($full_ruled; $name_max))) | join("\n"))
         else "" end);
    def note: "\n\n_(Cut to fit the comment limit; the triage state keeps every cause.)_";
    ($agent + "\n\n") as $head
    | ($cap - ($head | length) - ($footer | length)) as $budget
    | $state.open_causes as $o | $state.ruled_out as $r
    | ([ render($o; $r; true; true; 0; 200),
         render($o; $r; true; false; 0; 200),
         render($o; $r; false; false; 0; 200),
         (range(1; ($r | length) + 1) as $k | render($o; $r[$k:]; false; false; $k; 200)),
         render($o; []; false; false; ($r | length); 80) ]
       | (map(select(length <= $budget)) | first) // last) as $lists
    | ($head + $lists + $footer) as $all
    | if ($all | length) <= $cap then $all
      else
        ($cap - ($lists | length) - ($footer | length) - 2 - (note | length)) as $keep
        | if $keep >= 0 then $agent[0:$keep] + note + "\n\n" + $lists + $footer
          else $all[0:($cap - (note | length))] + note
          end
      end
  '
}

# triage_state_marker STATE_JSON — print the hidden marker for GitHub/GitLab.
triage_state_marker() {
  local encoded
  encoded="$(printf '%s' "$1" | base64 | tr -d '\n')"
  printf '<!-- triage-state-v1:%s -->' "${encoded}"
}

# triage_state_neutralize TEXT — escape every state marker opener in TEXT, so
# the only live marker in a posted comment is the one the post-script adds.
triage_state_neutralize() {
  jq -rn --arg t "$1" '$t | gsub("(?i)<(?=!--\\s*triage-state)"; "&lt;")'
}
