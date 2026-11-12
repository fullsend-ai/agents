#!/usr/bin/env bash
# codex-v2-dispatch-contract-test.sh — Verify the Codex V2 dispatch gate.
#
# fullsend's runtime note carries the sentence below once fullsend admits
# collaboration V2 parents (fullsend-ai/fullsend#9085). The review and retro
# agents gate their V2 rules on it, so a wording change on either side must
# change both.
#
# Run from the repo root:
#   bash scripts/codex-v2-dispatch-contract-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MARKER='`Dispatch follows collaboration V2.`'
FAILURES=0

for f in agents/review.md agents/retro.md; do
  # Join lines so the check survives markdown re-wrapping.
  text="$(tr '\n' ' ' <"${REPO_ROOT}/${f}" | tr -s ' ')"
  if grep -qF -- "${MARKER}" <<<"${text}"; then
    echo "PASS: ${f} gates its V2 rules on ${MARKER}"
  else
    echo "FAIL: ${f} does not mention ${MARKER}"
    FAILURES=$((FAILURES + 1))
  fi
done

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} failure(s)"
  exit 1
fi
echo "All Codex V2 dispatch contract checks passed"
