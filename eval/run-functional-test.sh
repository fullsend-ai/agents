#!/usr/bin/env bash
# run-functional-test.sh — Test the cross-repo review skip in run-functional.sh.
#
# Run from the repo root:
#   bash eval/run-functional-test.sh
#
# The skip must fire only for AGENT=review under a cross-repo GitHub Actions
# caller (#1573). Every other case must get past the guard: a stub `yq` that
# exits 97 marks "reached the first real step", so no live suite ever runs.

set -euo pipefail

EVAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUB_BIN="$(mktemp -d)"
trap 'rm -rf "${STUB_BIN}"' EXIT

for tool in bash dirname mktemp rm; do
  ln -s "$(command -v "$tool")" "${STUB_BIN}/${tool}"
done
printf '#!/bin/sh\nexit 97\n' > "${STUB_BIN}/yq"
chmod +x "${STUB_BIN}/yq"

FAILURES=0

# run_case <name> <want-exit> <want-notice:yes|no> <agent> [VAR=value ...]
run_case() {
  local name="$1" want_exit="$2" want_notice="$3" agent="$4"
  shift 4
  local out rc=0
  out=$(env -i PATH="${STUB_BIN}" "$@" \
    bash "${EVAL_DIR}/run-functional.sh" "$agent" 2>&1) || rc=$?

  local got_notice=no
  if [[ "$out" == *"::notice::Skipping review functional tests"* ]]; then
    got_notice=yes
  fi

  if [[ "$rc" -ne "$want_exit" || "$got_notice" != "$want_notice" ]]; then
    echo "FAIL: ${name}: exit=${rc} (want ${want_exit}), notice=${got_notice} (want ${want_notice})"
    echo "      output: ${out}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${name}"
  fi
}

run_case "review from cross-repo caller is skipped" 0 yes review \
  GITHUB_ACTIONS=true GITHUB_REPOSITORY=fullsend-ai/fullsend
run_case "review on agents itself runs" 97 no review \
  GITHUB_ACTIONS=true GITHUB_REPOSITORY=fullsend-ai/agents
run_case "review run locally runs" 97 no review \
  GITHUB_REPOSITORY=fullsend-ai/fullsend
run_case "review with no repository set runs" 97 no review \
  GITHUB_ACTIONS=true
run_case "triage from cross-repo caller runs" 97 no triage \
  GITHUB_ACTIONS=true GITHUB_REPOSITORY=fullsend-ai/fullsend

# No stray runtime eval config may be left behind by any case.
shopt -s nullglob
leftovers=("${EVAL_DIR}"/*/eval-runtime-*.yaml)
shopt -u nullglob
if [[ ${#leftovers[@]} -gt 0 ]]; then
  echo "FAIL: leftover runtime configs: ${leftovers[*]}"
  FAILURES=$((FAILURES + 1))
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All run-functional tests passed"
