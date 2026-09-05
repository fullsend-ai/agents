#!/usr/bin/env bash
# shellcheck shell=bash
# fix-budget.lib.sh — parse a per-PR fix-loop budget from PR labels.
#
# A label of the form `fullsend-fix-budget/N` (N a positive integer) lets a
# maintainer cap the review->fix loop for a single PR below the global
# iteration cap. The label can only TIGHTEN the cap, never raise it:
# enforcement lives in pre-fix, which applies min(label_budget, cap).
#
# Bundled into pre-fix.sh via bundle-sh.sh.
#
# Expected env vars (optional):
#   PR_LABELS — PR label names separated by commas and/or newlines. Absent/empty
#               is fine: parse_fix_budget then returns nothing and the cap is
#               unchanged. (The upstream dispatcher comma-joins labels; a
#               newline-joined value is also accepted.)

[[ -n "${FIX_BUDGET_SH_LOADED:-}" ]] && return 0
FIX_BUDGET_SH_LOADED=1

FIX_BUDGET_LABEL_PREFIX="fullsend-fix-budget/"

# parse_fix_budget [labels]
# Reads label names (arg 1, or PR_LABELS env when omitted) separated by commas
# and/or newlines. Echoes the smallest valid budget found, or nothing when no
# valid label is present. A malformed value (non-integer, zero, negative) is
# ignored, not fatal — a bad label must not silently drop the existing cap.
parse_fix_budget() {
  local labels="${1-${PR_LABELS:-}}"
  local best="" label n
  # Accept comma-joined labels (the upstream dispatcher format) as well as
  # newline-joined: normalize commas to newlines before splitting.
  labels="${labels//,/$'\n'}"
  while IFS= read -r label; do
    # Trim surrounding whitespace so " fullsend-fix-budget/3 " still matches.
    label="${label#"${label%%[![:space:]]*}"}"
    label="${label%"${label##*[![:space:]]}"}"
    [[ "${label}" == "${FIX_BUDGET_LABEL_PREFIX}"* ]] || continue
    n="${label#"${FIX_BUDGET_LABEL_PREFIX}"}"
    # Bound the digit count. An arbitrarily long value would overflow Bash's
    # signed 64-bit arithmetic in the `-lt` comparison (e.g. 2^64 evaluates as
    # 0), which would look "tighter" than any cap and block every fix run.
    # A budget above 99999 is meaningless next to caps of 5/10, so treat an
    # over-long value as malformed and ignore it.
    [[ "${n}" =~ ^[1-9][0-9]{0,4}$ ]] || continue
    if [[ -z "${best}" || "${n}" -lt "${best}" ]]; then
      best="${n}"
    fi
  done <<< "${labels}"
  [[ -n "${best}" ]] && printf '%s\n' "${best}"
  return 0
}
