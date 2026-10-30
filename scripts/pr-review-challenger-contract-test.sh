#!/usr/bin/env bash
# pr-review-challenger-contract-test.sh — Verify challenger result guidance.
#
# Run from the repo root:
#   bash scripts/pr-review-challenger-contract-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/pr-review/SKILL.md"
CHALLENGER="${REPO_ROOT}/skills/pr-review/sub-agents/challenger.md"
FAILURES=0

CHALLENGER_SECTION="$(awk '
  /^#### 6d\. Challenger pass/ { found = 1 }
  found && /^#### 6e\. / { exit }
  found { print }
' "${SKILL}")"

if [[ -z "${CHALLENGER_SECTION}" ]]; then
  echo "FAIL: could not extract the '#### 6d. Challenger pass' section from ${SKILL}"
  exit 1
fi

# Normalize to a single space-separated line so assertions survive markdown
# re-wrapping.
CHALLENGER_SECTION="$(printf '%s\n' "${CHALLENGER_SECTION}" | tr '\n' ' ' | tr -s ' ')"
TARGET="${CHALLENGER_SECTION}"

assert_contains() {
  local name="$1" expected="$2"
  if grep -qF -- "${expected}" <<<"${TARGET}"; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name} — missing '${expected}' in challenger guidance"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_not_contains() {
  local name="$1" unexpected="$2"
  if grep -qF -- "${unexpected}" <<<"${TARGET}"; then
    echo "FAIL: ${name} — found forbidden '${unexpected}' in challenger guidance"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${name}"
  fi
}

assert_contains "structured response requires both arrays" \
  "Require a parsed object with both arrays."
assert_contains "challenged findings are accounted exactly once" \
  "Account for every challenged finding exactly once"
assert_contains "accounting applies regardless of empty adjudication" \
  'whether or not `adjudicated_findings` is empty'
assert_contains "accounting matches one-to-one" \
  "Match one-to-one on identity:"
assert_contains "removed findings match on original identity fields" \
  '`original_category` + `original_file` + `original_line`'
assert_contains "line-less removals match on original description" \
  '`original_description` when line-less'
assert_contains "adjudicated findings match on category file line" \
  '`category` + `file` + `line`'
assert_contains "line-less findings match on verbatim original description" \
  'Match line-less inputs on the verbatim original description'
assert_contains "merged findings list consolidated inputs in merged_from" \
  '`merged_from` list'
assert_contains "removed findings never apply to withheld findings" \
  'never apply to withheld findings'
assert_contains "removal reasons cite specific evidence" \
  '`removal_reason` must cite evidence.'
assert_contains "adjudicated findings replace the challenged subset" \
  'Replace the challenged subset with `adjudicated_findings`'
assert_contains "withheld findings are re-appended" \
  're-append withheld findings'
assert_contains "sub-agent-failure findings are never challenged" \
  'the `sub-agent-failure` findings, never challenged'

assert_contains "ambiguous or incomplete accounting is a failure" \
  "Missing, incomplete, duplicated, ambiguous, unmatched, or evidence-free accounting is a failure."
assert_contains "merge forbids correctness plus security" \
  'never combine a `correctness`-dimension input with a `security`-dimension input'
assert_contains "severity violation is invalid accounting" \
  'Any violation is invalid adjudication accounting'
assert_contains "severity and category lookups anchor to the input set" \
  'looked up in the 6a–6c set'
assert_contains "merged dimension resolved via category mapping" \
  'resolve the dimension from the input'
assert_not_contains "empty adjudication is no longer an unconditional failure" \
  "treat this as a challenger failure"
assert_contains "genuine challenger failures use fallback" \
  "has a timeout or tool error, returns malformed output"
assert_contains "invalid adjudication accounting uses fallback" \
  "invalid adjudication accounting"
assert_contains "failure fallback restores the pre-challenger set" \
  "fall back to the pre-challenger merged finding set"

assert_contains "time-budget skip keeps the merged set" \
  "skip the challenger: keep the merged finding set from"
assert_contains "time-budget skip records a low finding" \
  'record the item-4 `low` finding with the reason `time budget:'

assert_contains "prompt-size guard withholds low and info findings" \
  'tokens, withhold `low` and `info` findings from the challenger'
assert_contains "prompt-size guard restores withheld findings" \
  "input and re-append them, unchallenged, after step 3."
assert_contains "sub-agent-failure findings are always withheld from the challenger" \
  '`sub-agent-failure` findings are always withheld'
assert_contains "sub-agent-failure findings are re-appended unchanged" \
  're-appended unchanged after step 3'
assert_contains "removed findings are logged but excluded" \
  'Log `removed_findings`, but exclude them from the final review.'
assert_contains "challenger input excludes sub-agent-failure findings" \
  'EXCLUDING `sub-agent-failure` findings'
assert_contains "adjudicated set includes re-appended withheld findings" \
  'plus the re-appended withheld findings'

assert_contains "challenger failure finding is low severity" \
  '"severity": "low"'
assert_contains "challenger failure uses sub-agent-failure category" \
  '"category": "sub-agent-failure"'
assert_contains "challenger failure preserves the original findings" \
  'Using pre-challenger finding set.'
assert_contains "challenger failure is non-actionable" \
  '"actionable": false'

CHALLENGER_SCHEMA="$(printf '%s\n' "$(cat "${CHALLENGER}")" | tr '\n' ' ' | tr -s ' ')"
TARGET="${CHALLENGER_SCHEMA}"
assert_contains "removed_findings schema emits original_category" \
  '"original_category":'
assert_contains "removed_findings schema emits original_file" \
  '"original_file":'
assert_contains "removed_findings schema emits original_line" \
  '"original_line":'
assert_contains "removed_findings schema emits original_description" \
  '"original_description":'
assert_contains "removed_findings schema emits removal_reason" \
  '"removal_reason":'
assert_contains "adjudicated_findings schema emits original_identity" \
  '"original_identity":'
assert_contains "adjudicated_findings schema emits merged_from" \
  '"merged_from":'
assert_contains "challenger_action enum is kept|downgraded|merged" \
  '"challenger_action": "kept|downgraded|merged"'
assert_contains "identity line is required when the finding has a line" \
  'required when the finding has a line'
assert_contains "constraints state every input appears exactly once" \
  'Every challenged input finding appears exactly once'
assert_contains "merged entry top-level includes severity" \
  'top-level `severity`, `category`, `file`, `line`, and `description`'
assert_contains "constraints mirror kept identity equality" \
  '`severity` and `category` must equal its `original_identity` input'
assert_contains "constraints mirror merged severity and category equality" \
  '`severity` and `category` must equal those of the highest-severity input'
assert_contains "challenger step 3 forbids correctness-security merge" \
  'never merge a correctness-category finding with a security-category finding'
assert_contains "constraints mirror merge dimension ban" \
  'must never combine a correctness-category input with a security-category input'
assert_contains "constraints inline correctness categories" \
  'correctness = `logic-error`, `nil-deref`'
assert_contains "constraints inline security categories" \
  'security = `auth-bypass`, `rbac-violation`'
assert_contains "constraints mirror downgrade strictly lower" \
  '`severity` must be strictly lower than its input'
assert_contains "constraints mirror severity ordering" \
  '(critical > high > medium > low > info)'
assert_contains "constraints mirror downgrade category unchanged" \
  'its `category` unchanged'
assert_contains "constraints mirror downgrade reason evidence" \
  'its `challenger_reason` must cite evidence'
assert_contains "constraints mirror merged tie-break" \
  '(ties broken on the more specific remediation)'
assert_not_contains "merged entry no longer omits severity" \
  'top-level `category`, `file`, `line`, and `description`'
assert_contains "denied spawn never adjudicates in the parent" \
  "after a denied spawn, do not adjudicate any findings."
assert_contains "denied spawn returns the fixed non-JSON result" \
  'Return `Challenger unavailable: isolated context required.`'
assert_contains "denied spawn falls through to step 6d item 4" \
  'as a failure under `pr-review` step 6d item 4.'

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi

echo "All PR review challenger contract tests passed"
