#!/usr/bin/env bash
# codex-v2-dispatch-contract-test.sh — Verify the Codex V2 dispatch rules.
#
# fullsend's runtime note carries the sentence below once fullsend admits
# collaboration V2 parents (fullsend-ai/fullsend#9085). The review and retro
# agents gate their V2 rules on it, so a wording change on either side must
# change both. The same holds for fullsend's withheld notice (its
# codexWithheldNotice), which the V2 rules treat as a final result with no
# content.
#
# The test checks three things:
# - both agents gate on the sentence;
# - each V2 rule body holds each of its rules, pinned by a phrase that must
#   occur once in it, and mentions close, fork_context, wait_agent, target
#   and "next open child", in any case, only in the sentences that rule out
#   their V1 use;
# - every pr-review step and the Constraints rule that the review agent's V2
#   rules cite, by number or by name, is still where they cite it. Each
#   citation row pins the citation in the V2 rules and a phrase that only the
#   cited rule contains (in skills/pr-review/SKILL.md, or under Constraints
#   in agents/review.md), so moving either side fails here instead of
#   silently breaking the citation.
#
# Run from the repo root:
#   bash scripts/codex-v2-dispatch-contract-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MARKER='`Dispatch follows collaboration V2.`'
NOTICE='`RESULT WITHHELD BY FULLSEND`'
FAILURES=0

pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES + 1))
}

# Join lines so the checks survive markdown re-wrapping.
join_lines() { tr '\n' ' ' | tr -s ' '; }

# count TEXT PHRASE [-i]: how many times PHRASE occurs in TEXT (-i: in any
# case).
count() {
  { grep -oF ${3:+"$3"} -- "$2" <<<"$1" || true; } | wc -l | tr -d ' '
}

# has NAME TEXT PHRASE: PHRASE occurs exactly once in TEXT.
has() {
  if [[ "$(count "$2" "$3")" -eq 1 ]]; then
    pass "$1 says $3"
  else
    fail "$1 does not say $3 exactly once"
  fi
}

for f in agents/review.md agents/retro.md; do
  has "${f}" "$(join_lines <"${REPO_ROOT}/${f}")" "${MARKER}"
  has "${f}" "$(join_lines <"${REPO_ROOT}/${f}")" "${NOTICE}"
done

# --- V2 rule bodies ---------------------------------------------------------

# v2_rules FILE START END: the text from START up to END in FILE, lines
# joined; empty when either is missing.
v2_rules() {
  local text rest
  text="$(join_lines <"${REPO_ROOT}/$1")"
  [[ "${text}" == *"$2"* ]] || return 0
  rest="${text#*"$2"}"
  [[ "${rest}" == *"$3"* ]] || return 0
  printf '%s\n' "${rest%%"$3"*}"
}

# only_in NAME TEXT TOKEN ALLOWED...: every TOKEN in TEXT, in any case, sits
# inside one of the ALLOWED phrases, the sentences that rule out its V1 use.
# Each ALLOWED phrase covers one TOKEN, however often it occurs.
only_in() {
  local name="$1" text="$2" token="$3" allowed=0 phrase
  shift 3
  for phrase in "$@"; do
    allowed=$((allowed + ($(count "${text}" "${phrase}" -i) > 0)))
  done
  if [[ "$(count "${text}" "${token}" -i)" -eq "${allowed}" ]]; then
    pass "${name} mentions ${token} only to rule out its V1 use"
  else
    fail "${name} prescribes ${token} outside the sentences that rule it out"
  fi
}

NAME='agents/review.md V2 rules'
REVIEW_RULES="$(v2_rules agents/review.md "When the note says ${MARKER}" '## Inputs')"
[[ -n "${REVIEW_RULES}" ]] || fail "${NAME} not found between the gate sentence and ## Inputs"
for rule in \
  "these rules replace the \`pr-review\` skill's Codex rules" \
  '`spawn_agent` with a `task_name` unique in the run' \
  'Codex accepts only lowercase letters, digits and `_`' \
  '`message` = the prompt' \
  '`agent_type` = the persona name when listed, else omit it' \
  '`fork_turns: "none"`' \
  'never `model`, `reasoning_effort` or `fork_context`' \
  "A denied spawn: the note's rule." \
  'Run `date +%s` after each spawn and each timed-out wait.' \
  "each finished child's result arrives as its own message" \
  'whose `Sender:` is `/root/<task_name>`' \
  'its `Task name:` is your own path, `/root`' \
  'it belongs to the persona you spawned with that `task_name`' \
  '`wait_agent` takes only `timeout_ms` (≤ 120000), never a target' \
  'its return is not a result' \
  'after a timeout, wait again' \
  'There is no `close_agent`.' \
  '`interrupt_agent` always takes `target` = the task name' \
  'the task name `spawn_agent` returned (`/root/<task_name>`)' \
  'one call per child' \
  'a payload that is empty, is `Agent shut down.` or `Agent was not found.`' \
  '`Agent errored:` or `Agent interrupted by Guardian:`' \
  "a payload that is exactly ${NOTICE} (the runtime sends it in place of a result it withheld)" \
  'still running 900 s after its spawn: interrupt it' \
  'it sends no result, unless the call reports it `completed`, when its result message is the result' \
  "Apply that sub-agent's failure fallback" \
  "never retry the spawn or read the child's raw rollout" \
  '`agent_type` `security-triage` when listed, else `explore` (instruction-only)' \
  'wait for its result before step 3d' \
  'at most four running' \
  'Start up to four, `correctness` and `security` first' \
  'start the next selected sub-agent as each child ends (its result arrives or it is final without one)' \
  'until every selected sub-agent has a result or a failure' \
  'Before each wait, check the Time budget: under 240 s, if any selected sub-agent has neither a result nor a failure' \
  'interrupt every running child, start no more' \
  "the skill's skip rule and 600 s check still decide whether the challenger runs" \
  'When it runs, spawn it once every step 4 sub-agent has a result or a failure' \
  'Before each wait, recheck the time: under 240 s, interrupt it' \
  'with no result, apply item 4'; do
  has "${NAME}" "${REVIEW_RULES}" "${rule}"
done
only_in "${NAME}" "${REVIEW_RULES}" close 'the Codex lines of step 6d) and the `close_agent` final-state rule under Constraints:' 'There is no `close_agent`'
only_in "${NAME}" "${REVIEW_RULES}" fork_context 'never `model`, `reasoning_effort` or `fork_context`'
only_in "${NAME}" "${REVIEW_RULES}" wait_agent '`wait_agent` takes only `timeout_ms`' '`wait_agent` never takes one'
only_in "${NAME}" "${REVIEW_RULES}" target 'never a target' '`interrupt_agent` always takes `target`'
only_in "${NAME}" "${REVIEW_RULES}" 'next open child'

NAME='agents/retro.md V2 rules'
RETRO_RULES="$(v2_rules agents/retro.md "If the note also says ${MARKER}" 'Synthesis and `agent-result.json`')"
[[ -n "${RETRO_RULES}" ]] || fail "${NAME} not found between the gate sentence and the synthesis rule"
for rule in \
  'use these rules instead' \
  '`spawn_agent` with a unique `task_name`' \
  '(lowercase letters, digits and `_`)' \
  'the task as `message`, no `agent_type`' \
  '`fork_turns: "none"`' \
  'never `model`, `reasoning_effort` or `fork_context`' \
  "a denied spawn: the note's rule; record it in \`summary\`" \
  '`wait_agent` with only `timeout_ms` ≤ 120000, never a target' \
  'a timed-out wait is no result' \
  'wait again while any task is running' \
  'each result arrives as its own message' \
  'whose `Sender:` is `/root/<task_name>`' \
  '(its `Task name:` is your own path)' \
  'there is no close' \
  'at most four running' \
  'starting the next task as each task ends (its result arrives or it is final without one)' \
  'run `date +%s` after each spawn and at each timed-out wait' \
  'a payload that is empty, is `Agent shut down.` or `Agent was not found.`' \
  '`Agent errored:` or `Agent interrupted by Guardian:`' \
  "a payload that is exactly ${NOTICE} (the runtime sends it in place of a result it withheld)" \
  'a task still running 900 s after its spawn (interrupt it with `interrupt_agent`' \
  '`target` = the task name `spawn_agent` returned, `/root/<task_name>`; it sends no result' \
  'is final for that task' \
  'record the gap in `summary` unless `interrupt_agent` reports it `completed`' \
  "when its result message is the task's result" \
  "do not retry it or read the child's raw rollout"; do
  has "${NAME}" "${RETRO_RULES}" "${rule}"
done
only_in "${NAME}" "${RETRO_RULES}" close 'there is no close'
only_in "${NAME}" "${RETRO_RULES}" fork_context 'never `model`, `reasoning_effort` or `fork_context`'
only_in "${NAME}" "${RETRO_RULES}" wait_agent '`wait_agent` with only `timeout_ms`'
only_in "${NAME}" "${RETRO_RULES}" target 'never a target' 'interrupt it with `interrupt_agent` and `target`'
only_in "${NAME}" "${RETRO_RULES}" 'next open child'

# --- Rules the review agent's V2 rules cite ---------------------------------

# section FILE HEADING: the lines under the first heading that starts with
# HEADING, up to the next heading of the same or a higher level. Lines inside
# ``` fences are never headings.
section() {
  awk -v h="$2" '
    /^[[:space:]]*```/ { fence = !fence }
    found && !fence && /^#+ / && length($1) <= level { exit }
    found { print }
    !found && !fence && index($0, h) == 1 { found = 1; level = length($1) }
  ' "$1"
}

# item N: top-level item N of a numbered list, up to the next unindented line
# outside a ``` fence.
item() {
  awk -v n="$1. " '
    on && !fence && /^[^[:space:]]/ { exit }
    /^[[:space:]]*```/ { fence = !fence }
    !on && !fence && index($0, n) == 1 { on = 1 }
    on { print }
  '
}

# cites CITATION FILE HEADING ITEM PHRASE: the review agent's V2 rules still
# say CITATION, and the step under HEADING in FILE (item ITEM of it, when
# given) still holds the cited rule, named by PHRASE, which occurs once in
# FILE.
cites() {
  local text step
  text="$(section "${REPO_ROOT}/$2" "$3")"
  if [[ -n "$4" ]]; then
    text="$(item "$4" <<<"${text}")"
  fi
  step="${3##*# }"
  step="${step%. }"
  case "${step}" in [0-9]*) step="step ${step}" ;; esac
  step="${step}${4:+ item $4}"
  if [[ "${REVIEW_RULES}" != *"$1"* ]]; then
    fail "agents/review.md V2 rules no longer say \"$1\"; update this row with them"
  elif [[ "$(count "$(join_lines <"${REPO_ROOT}/$2")" "$5")" -ne 1 ]] ||
    ! grep -qF -- "$5" <<<"$(join_lines <<<"${text}")"; then
    fail "$2 ${step} no longer holds the rule cited as \"$1\" ($5 not there once); update the citation and this row together"
  else
    pass "\"$1\" is $2 ${step}: $5"
  fi
}

SKILL=skills/pr-review/SKILL.md
TRIAGE='`agent_type`: `security-triage` when listed'
WAVES='**Codex roster:** at most four open'
SKIP='**Skip when there is nothing to adjudicate.**'
cites 'check the Time budget' "${SKILL}" '### Time budget' '' 'under 240 s remaining'
cites 'write the `time-budget` failure' "${SKILL}" '### Time budget' '' '`time-budget` and no `body`'
cites 'step 3c-1 item 4' "${SKILL}" '#### 3c-1. ' 4 "${TRIAGE}"
cites 'except step 3c-1, below' "${SKILL}" '#### 3c-1. ' 4 "${TRIAGE}"
cites '**Step 3c-1:**' "${SKILL}" '#### 3c-1. ' 4 "${TRIAGE}"
cites '3c-1 item 6' "${SKILL}" '#### 3c-1. ' 6 'If the security-triage sub-agent fails'
cites '3c-2' "${SKILL}" '#### 3c-2. ' '' 'If risk assessment fails'
cites 'before step 3d' "${SKILL}" '#### 3d. ' '' 'assemble a context package'
cites 'step 4 item 2' "${SKILL}" '### 4. ' 2 '**Codex roster** (a codex note'
cites 'and its waves' "${SKILL}" '### 4. ' '' "${WAVES}"
cites '**Step 4 waves:**' "${SKILL}" '### 4. ' '' "${WAVES}"
cites 'every step 4 sub-agent' "${SKILL}" '### 4. ' '' "${WAVES}"
cites 'step 5' "${SKILL}" '### 5. ' '' 'fails to return findings'
cites '**Step 6d:**' "${SKILL}" '#### 6d. ' '' "${SKIP}"
cites "the skill's skip rule and 600 s check" "${SKILL}" '#### 6d. ' '' "${SKIP}"
cites "the skill's skip rule and 600 s check" "${SKILL}" '#### 6d. ' '' '`REMAINING` under 600'
cites 'the Codex lines of step 6d' "${SKILL}" '#### 6d. ' '' 'On Codex, recheck before each wait'
cites 'the Codex lines of step 6d' "${SKILL}" '#### 6d. ' '' 'Codex: once its children close'
cites '6d item 4' "${SKILL}" '#### 6d. ' 4 'fall back to the pre-challenger merged finding set'
cites 'apply item 4' "${SKILL}" '#### 6d. ' 4 'fall back to the pre-challenger merged finding set'
cites 'the `close_agent` final-state rule under Constraints' agents/review.md '## Constraints' '' 'If `close_agent` reports `completed`'

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "All Codex V2 dispatch contract checks passed"
