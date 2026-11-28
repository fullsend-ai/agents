#!/usr/bin/env bash
# env-files-test.sh — Tests that the env/ files parse as data.
#
# The fullsend runner reads .env and .env.d files as data, not as shell
# (fullsend's internal/runtime/env_data.go). It keeps blank lines, `#`
# comments, `[export ]NAME=VALUE` assignments and `export NAME...` lines, and
# drops every other line (if/else/fi blocks, `;`-joined commands, command
# substitution) with a warning. A dropped line sets nothing, so a variable
# written inside one never reaches the sandbox.
#
# Run from the repo root:
#   bash scripts/env-files-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_DIR="${REPO_ROOT}/env"

FAILURES=0

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1"
  shift
  for line in "$@"; do
    echo "  ${line}"
  done
  FAILURES=$((FAILURES + 1))
}

# dropped_lines FILE prints "LINE: TEXT" for each line the data grammar drops.
# Values in env/ are single-line, so a line is a statement.
dropped_lines() {
  awk '
    /^[ \t]*$/ { next }
    /^[ \t]*#/ { next }
    /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/ { next }
    /^[ \t]*export([ \t]+[A-Za-z_][A-Za-z0-9_]*)+[ \t]*$/ { next }
    { printf "%d: %s\n", NR, $0 }
  ' "$1"
}

# Test 1: every env file parses as data, with no line dropped.
while IFS= read -r -d '' file; do
  rel="${file#"${REPO_ROOT}/"}"
  dropped="$(dropped_lines "${file}")"
  if [[ -z "${dropped}" ]]; then
    pass "parses-as-data ${rel}"
  else
    mapfile -t lines <<< "${dropped}"
    fail "parses-as-data ${rel}: lines the runner drops" "${lines[@]}"
  fi
done < <(find "${ENV_DIR}" -type f -name '*.env' -print0 | sort -z)

# Test 2: ssl-cainfo.env sets GIT_SSL_CAINFO to the OpenShell CA bundle as a
# plain assignment, the one form the runner keeps.
ssl_file="${ENV_DIR}/ssl-cainfo.env"
value="$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?GIT_SSL_CAINFO=//p' "${ssl_file}" | tail -n 1)"
if [[ "${value}" == "/etc/openshell-tls/ca-bundle.pem" ]]; then
  pass "ssl-cainfo-sets-git-ssl-cainfo"
else
  fail "ssl-cainfo-sets-git-ssl-cainfo" \
    "expected: GIT_SSL_CAINFO=/etc/openshell-tls/ca-bundle.pem as a NAME=value line" \
    "actual:   ${value:-<no NAME=value assignment of GIT_SSL_CAINFO>}"
fi

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
