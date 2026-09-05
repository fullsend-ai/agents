#!/usr/bin/env bash
# pre-fix-test.sh — Test the fix-budget label parser used by pre-fix.
#
# parse_fix_budget is pure (reads a labels string, echoes a number), so this
# sources the lib directly — no forge mocks needed.
# Run from the repo root: bash scripts/pre-fix-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fix-budget.lib.sh
source "${SCRIPT_DIR}/lib/fix-budget.lib.sh"
# shellcheck source=test-lib.sh
source "${SCRIPT_DIR}/test-lib.sh"
parse_script_test_args "$@"

PRE_SCRIPT="$(resolve_agent_script pre-fix "${SCRIPT_DIR}")"

FAILURES=0

# check EXPECTED LABELS...  — assert parse_fix_budget output equals EXPECTED.
check() {
  local expected="$1"; shift
  local labels="$1"; shift
  local got
  got="$(parse_fix_budget "${labels}")"
  if [[ "${got}" == "${expected}" ]]; then
    echo "ok: [${labels//$'\n'/\\n}] -> '${got}'"
  else
    echo "FAIL: [${labels//$'\n'/\\n}] expected '${expected}', got '${got}'"
    FAILURES=$((FAILURES + 1))
  fi
}

# Valid budget label among unrelated labels.
check "3" $'bug\nfullsend-fix-budget/3\narea/api'
# No budget label -> empty (cap unchanged).
check "" $'bug\narea/api'
# Empty input -> empty.
check "" ""
# Multiple budget labels -> smallest wins (tightest cap).
check "2" $'fullsend-fix-budget/7\nfullsend-fix-budget/2'
# Malformed values are ignored, not fatal.
check "" $'fullsend-fix-budget/0\nfullsend-fix-budget/-1\nfullsend-fix-budget/abc'
# A malformed value alongside a valid one keeps the valid one.
check "4" $'fullsend-fix-budget/x\nfullsend-fix-budget/4'
# Surrounding whitespace is trimmed.
check "5" $'  fullsend-fix-budget/5  '
# Prefix must be exact — a longer segment is not a budget label.
check "" $'fullsend-fix-budget/3/extra'
# An oversized value (would overflow Bash arithmetic) is ignored, not treated
# as a tighter budget; a valid label alongside it still wins.
check "" $'fullsend-fix-budget/18446744073709551616'
check "4" $'fullsend-fix-budget/18446744073709551616\nfullsend-fix-budget/4'
# The boundary: 5 digits ok, 6 digits rejected.
check "99999" $'fullsend-fix-budget/99999'
check "" $'fullsend-fix-budget/100000'
# Comma-joined labels (the upstream dispatcher format) are accepted.
check "3" 'bug,fullsend-fix-budget/3,area/api'
check "2" 'fullsend-fix-budget/7,fullsend-fix-budget/2'
# Mixed comma and newline separators.
check "2" $'bug,fullsend-fix-budget/5\nfullsend-fix-budget/2,area/api'
# Whitespace around a comma-separated budget label is trimmed.
check "5" 'bug, fullsend-fix-budget/5 ,area/api'

# Reads PR_LABELS env when no argument is given.
if [[ "$(PR_LABELS=$'fullsend-fix-budget/6' parse_fix_budget)" == "6" ]]; then
  echo "ok: reads PR_LABELS env"
else
  echo "FAIL: did not read PR_LABELS env"
  FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Cap enforcement — run the actual pre-fix script, not just the parser, to
# verify a label tightens the cap it enforces and that an iteration above the
# tightened cap exits through escalation.
# ---------------------------------------------------------------------------
REPO_STUB="$(mktemp -d)"  # empty repo dir -> pre-commit auto-install is skipped
trap 'rm -rf "${REPO_STUB}"' EXIT

# run_prefix TRIGGER ITERATION CAP_VAR CAP_VAL LABELS -> sets OUT, RC
run_prefix() {
  local trigger="$1" iteration="$2" cap_var="$3" cap_val="$4" labels="$5"
  OUT=""; RC=0
  OUT="$(
    env -i \
      PATH="${PATH}" HOME="${HOME}" \
      FULLSEND_FORGE=github \
      PR_NUMBER=1 REPO_FULL_NAME=o/r \
      REPO_DIR="${REPO_STUB}" \
      TRIGGER_SOURCE="${trigger}" \
      FIX_ITERATION="${iteration}" \
      "${cap_var}=${cap_val}" \
      PR_LABELS="${labels}" \
      bash "${PRE_SCRIPT}" 2>&1
  )" || RC=$?
}

# check_run DESC EXPECT_RC PATTERN
check_run() {
  local desc="$1" expect_rc="$2" pattern="$3"
  if [[ "${RC}" == "${expect_rc}" ]] && grep -qF "${pattern}" <<< "${OUT}"; then
    echo "ok: ${desc}"
  else
    echo "FAIL: ${desc} (rc=${RC}, expected ${expect_rc}; pattern '${pattern}' not found)"
    echo "----- output -----"; echo "${OUT}"; echo "------------------"
    FAILURES=$((FAILURES + 1))
  fi
}

BOT="fixbot[bot]"

# A lower label tightens the bot cap and the run is allowed within it.
run_prefix "${BOT}" 2 ITERATION_CAP 5 $'bug\nfullsend-fix-budget/2'
check_run "label tightens bot cap 5 -> 2" 0 "caps the autonomous fix loop at 2 iteration(s)"
check_run "tightened cap shows in summary" 0 "FIX_ITERATION=2 of 2"

# A higher label cannot raise the cap: no tightening notice, cap stays 5.
run_prefix "${BOT}" 5 ITERATION_CAP 5 $'fullsend-fix-budget/9'
check_run "higher label does not raise bot cap" 0 "FIX_ITERATION=5 of 5"
if grep -qF "caps the autonomous fix loop" <<< "${OUT}"; then
  echo "FAIL: higher label wrongly emitted a tighten notice"
  FAILURES=$((FAILURES + 1))
else
  echo "ok: higher label emits no tighten notice"
fi

# A label equal to the default bot cap does not tighten it: no notice.
run_prefix "${BOT}" 1 ITERATION_CAP 5 $'fullsend-fix-budget/5'
if grep -qF "caps the autonomous fix loop" <<< "${OUT}"; then
  echo "FAIL: label equal to default bot cap wrongly emitted a tighten notice"
  FAILURES=$((FAILURES + 1))
else
  echo "ok: label equal to default bot cap emits no notice"
fi

# An iteration above the tightened bot cap escalates (exit 1). The escalation
# names the label to remove and still points to the UNtightened human /fs-fix
# budget (the label never locks a human out).
run_prefix "${BOT}" 3 ITERATION_CAP 5 $'fullsend-fix-budget/2'
check_run "iteration above tightened bot cap escalates" 1 "exceeds bot cap of 2"
check_run "bot escalation names the budget label" 1 "set by the fullsend-fix-budget/2 PR label"
check_run "bot escalation keeps full human /fs-fix budget" 1 "up to 10 total iterations"

# The label never tightens the human cap: a human /fs-fix run above the bot
# budget but within the human cap is allowed, and still shows the tighten notice.
run_prefix "alice" 3 ITERATION_CAP_HUMAN 10 $'fullsend-fix-budget/2'
check_run "human run is not blocked by the bot budget label" 0 "FIX_ITERATION=3 of 10"
check_run "notice fires on human run too" 0 "caps the autonomous fix loop at 2 iteration(s)"

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All pre-fix tests passed"
