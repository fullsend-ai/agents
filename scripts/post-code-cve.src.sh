#!/usr/bin/env bash
# post-code-cve.sh — DRAFT. Host check behind the code agent for a work item
# labelled `cve`, before anything is pushed. Selected by an overlay in
# harness/code.yaml; hands over to the ordinary post-script when it passes.
#
# Checks the change against the receipt pre-code-cve admitted:
#   1. the pull request targets the branch that was assessed;
#   2. every changed file is one the plan named. A plan entry ending in "/"
#      covers that directory (a re-vendored tree, for example).
# A failure exits non-zero, so nothing is pushed and no pull request opens.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cve-receipt.lib.sh
source "${SCRIPT_DIR}/lib/cve-receipt.lib.sh"

RECEIPT_FILE="$(cve_receipt_staging_dir)/receipt.json"
[[ -f "${RECEIPT_FILE}" ]] \
  || { echo "::error::cve code check: no admitted receipt at ${RECEIPT_FILE}; pre-code-cve did not run"; exit 1; }
RECEIPT=$(cve_receipt_valid < "${RECEIPT_FILE}") \
  || { echo "::error::cve code check: the admitted receipt is not valid"; exit 1; }
REF=$(jq -r .ref <<<"${RECEIPT}"); COMMIT=$(jq -r .commit <<<"${RECEIPT}")

RESULT=""
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  RESULT="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
else
  for dir in iteration-*/output; do
    [[ -f "${dir}/agent-result.json" ]] && RESULT="${dir}/agent-result.json"
  done
fi

REPO="${REPO_DIR:-repo}"
FILES=""
if [[ -d "${REPO}" ]]; then
  BASE=$(git -C "${REPO}" merge-base "origin/${REF}" HEAD 2>/dev/null) || BASE="${COMMIT}"
  FILES=$(git -C "${REPO}" diff --name-only "${BASE}" HEAD 2>/dev/null) || FILES=""
fi

if [[ -n "${FILES}" ]]; then
  TARGET=""
  [[ -n "${RESULT}" && -f "${RESULT}" ]] && TARGET=$(jq -r '.target_branch // empty' "${RESULT}")
  if [[ "${TARGET}" != "${REF}" ]]; then
    echo "::error::cve code check: the change targets '${TARGET:-<unset>}' but the verdict is for branch '${REF}'; nothing was pushed"
    exit 1
  fi
  OUTSIDE=$(jq -rn --arg files "${FILES}" --argjson r "${RECEIPT}" '
    ($files | split("\n") | map(select(length > 0))) as $f
    | $f[] | . as $p
    | select(any($r.change_paths[]; . as $d | ($d == $p) or (($d | endswith("/")) and ($p | startswith($d)))) | not)')
  if [[ -n "${OUTSIDE}" ]]; then
    echo "::error::cve code check: the change touches file(s) the assessed plan did not name; nothing was pushed"
    sed 's/^/  outside the plan: /' <<<"${OUTSIDE}" | head -n 20
    echo "The plan named: $(jq -r '.change_paths | join(", ")' <<<"${RECEIPT}")"
    echo "Re-run /fs-cve if the plan needs to grow; the code agent may not widen it."
    exit 1
  fi
  echo "::notice::cve code check: $(wc -l <<<"${FILES}" | tr -d ' ') changed file(s), all inside the assessed plan, targeting ${REF}"
fi

exec bash "${SCRIPT_DIR}/post-code.sh" "$@"
