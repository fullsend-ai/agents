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

# The readable comment cap from agents/triage.md. The lists are condensed to
# fit what the agent's comment leaves of it; the state marker is not counted.
TRIAGE_STATE_READABLE_CAP=4000
# The lists always get at least this much, so the open causes stay visible
# beside a long comment.
TRIAGE_STATE_MIN_BUDGET=1000

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
    | if (.open_causes | length) == 0 then empty else . end
  ' "$1"
}

# triage_state_render STATE_JSON BUDGET — print the readable lists, one line
# per cause. Unverified causes are marked; "Ruled out" is left out when
# empty. When the lists exceed BUDGET characters they are condensed in this
# order: ruled-out evidence, then all evidence, then the oldest ruled-out
# lines (counted in one line instead). The open causes are always listed.
triage_state_render() {
  jq -r --argjson budget "$2" '
    def safe: gsub("<!--"; "&lt;!--");
    def clip($n): if length > $n then .[0:($n - 1)] + "…" else . end;
    def line($full):
      "- " + (.cause | safe)
      + (if .verified then "" else " _(unverified)_" end)
      + (if $full and .evidence != "" then " — " + (.evidence | clip(160) | safe) else "" end);
    def render($o; $r; $full_open; $full_ruled; $hidden):
      "**Open causes:**\n" + ($o | map(line($full_open)) | join("\n"))
      + (if ($r | length) + $hidden > 0 then
           "\n\n**Ruled out:**\n"
           + ((if $hidden > 0 then ["- \($hidden) earlier ruled-out cause(s) not listed here; the triage state keeps them"] else [] end)
              + ($r | map(line($full_ruled))) | join("\n"))
         else "" end);
    def fits: length <= $budget;
    .open_causes as $o | .ruled_out as $r
    | render($o; $r; true; true; 0) as $a
    | if ($a | fits) then $a else
        render($o; $r; true; false; 0) as $b
        | if ($b | fits) then $b else
            render($o; $r; false; false; 0) as $c
            | if ($c | fits) then $c else
                ([range(1; ($r | length) + 1)
                  | . as $k | render($o; $r[$k:]; false; false; $k) | select(fits)] | first)
                // render($o; []; false; false; ($r | length))
              end
          end
      end
  ' <<<"$1"
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

# triage_state_budget COMMENT — the characters the lists may use after
# COMMENT and the blank line that separates them.
triage_state_budget() {
  local left=$((TRIAGE_STATE_READABLE_CAP - ${#1} - 2))
  if [[ ${left} -lt ${TRIAGE_STATE_MIN_BUDGET} ]]; then
    left=${TRIAGE_STATE_MIN_BUDGET}
  fi
  echo "${left}"
}
