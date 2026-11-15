#!/usr/bin/env bash
# skill-jira-token-file-test.sh — Verify the Jira skills read the sandbox
# token file on every call (#1926).
#
# With OAuth 2.0 client credentials, fullsend run mints the Jira access
# token and refreshes it during the run, keeping the current placeholder in
# /sandbox/fullsend-jira/token (fullsend-ai/fullsend#9233). The placeholder
# changes on every refresh, so every Jira curl snippet must read the file
# in the same code block, falling back to JIRA_TOKEN (static-token mode)
# when the file is absent or empty, and must never build JIRA_AUTH from
# JIRA_TOKEN directly.
#
# Run from the repo root: bash scripts/skill-jira-token-file-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0

assert_pass() { echo "PASS: $1"; }
assert_fail() {
  echo "FAIL: $1 — $2"
  FAILURES=$((FAILURES + 1))
}

TOKEN_FILE="/sandbox/fullsend-jira/token"
READ_LINE='JIRA_TOKEN_NOW="$(cat /sandbox/fullsend-jira/token 2>/dev/null)"; JIRA_TOKEN_NOW="${JIRA_TOKEN_NOW:-${JIRA_TOKEN}}"'
AUTH_LINE='JIRA_AUTH="${JIRA_EMAIL:+${JIRA_EMAIL}:}${JIRA_TOKEN_NOW}"'

SKILL_FILES=(
  skills/jira-forge/SKILL.md
  skills/jira-components/SKILL.md
  skills/issue-labels/jira/SKILL.md
  skills/code-implementation/SKILL.md
)

# Print one problem per line for a skill file; no output means it passes.
# Inside each fenced code block, a JIRA_AUTH= line and every curl that uses
# JIRA_AUTH must come after the token-file read in that same block.
scan_skill() {
  awk -v read_line="${READ_LINE}" -v auth_line="${AUTH_LINE}" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*```/ { inside = !inside; have_read = 0; next }
    !inside { next }
    {
      line = trim($0)
      if (line == read_line) { have_read = 1; reads++; next }
      if (line ~ /^JIRA_AUTH=/) {
        auths++
        if (line != auth_line) {
          printf "line %d: JIRA_AUTH is not built from JIRA_TOKEN_NOW: %s\n", NR, line
        } else if (!have_read) {
          printf "line %d: JIRA_AUTH without the token-file read earlier in the block\n", NR
        }
      }
      if (index(line, "${JIRA_AUTH}") > 0 && line ~ /curl / && !have_read) {
        printf "line %d: Jira curl without the token-file read earlier in the block\n", NR
      }
    }
    END {
      if (auths == 0) print "no JIRA_AUTH line found"
      if (reads < auths) printf "%d JIRA_AUTH line(s) but only %d token-file read(s)\n", auths, reads
    }
  ' "$1"
}

for rel in "${SKILL_FILES[@]}"; do
  file="${REPO_ROOT}/${rel}"
  name="$(basename "$(dirname "${rel}")")"
  if [[ ! -f "${file}" ]]; then
    assert_fail "skill-${name}-reads-token-file" "${rel} not found"
    continue
  fi
  problems="$(scan_skill "${file}")"
  if [[ -z "${problems}" ]]; then
    assert_pass "skill-${name}-reads-token-file"
  else
    assert_fail "skill-${name}-reads-token-file" "${rel}: ${problems//$'\n'/; }"
  fi
done

# No skill under skills/ builds JIRA_AUTH from JIRA_TOKEN directly.
if direct="$(grep -rnF -- '}${JIRA_TOKEN}"' "${REPO_ROOT}/skills" | grep -F 'JIRA_AUTH=')"; then
  assert_fail "skills-no-direct-jira-token-auth" "${direct//$'\n'/; }"
else
  assert_pass "skills-no-direct-jira-token-auth"
fi

# Behaviour of the read line itself: the file wins, and JIRA_TOKEN is the
# fallback when the file is absent or empty. The test points the line at a
# temporary file instead of the sandbox path.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
run_read_line() {
  local line="${READ_LINE//${TOKEN_FILE}/${tmp}/token}"
  JIRA_TOKEN="static-placeholder" bash -c "${line}"'; printf "%s" "${JIRA_TOKEN_NOW}"'
}

printf 'minted-placeholder-2\n' > "${tmp}/token"
got="$(run_read_line)"
if [[ "${got}" == "minted-placeholder-2" ]]; then
  assert_pass "read-line-prefers-token-file"
else
  assert_fail "read-line-prefers-token-file" "got '${got}', want 'minted-placeholder-2'"
fi

: > "${tmp}/token"
got="$(run_read_line)"
if [[ "${got}" == "static-placeholder" ]]; then
  assert_pass "read-line-falls-back-on-empty-file"
else
  assert_fail "read-line-falls-back-on-empty-file" "got '${got}', want 'static-placeholder'"
fi

rm -f "${tmp}/token"
got="$(run_read_line 2>&1)"
if [[ "${got}" == "static-placeholder" ]]; then
  assert_pass "read-line-falls-back-on-missing-file"
else
  assert_fail "read-line-falls-back-on-missing-file" "got '${got}', want 'static-placeholder' with no stderr"
fi

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All skill Jira token-file tests passed"
