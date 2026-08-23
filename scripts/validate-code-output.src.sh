#!/usr/bin/env bash
# validate-code-output.src.sh — Validate code/fix agent output: schema + pre-commit.
#
# Wraps validate-output-schema.sh's schema check with an additional pre-commit
# gate run against TARGET_REPO_DIR.  Used as the validation_loop.script for the
# code and fix harnesses so that a lint or type-check failure consumes a retry
# iteration (with feedback) instead of ending the run terminally in the
# post-script.
#
# The pre-commit check runs on the runner (not in the sandbox), so it has
# full network access and the repo's pre-commit tool dependencies are already
# installed by the pre-script.
#
# Required env vars:
#   FULLSEND_OUTPUT_SCHEMA — path to the JSON Schema file
#
# Optional env vars:
#   FULLSEND_OUTPUT_FILE   — filename to validate (default: agent-result.json)
#   TARGET_REPO_DIR        — path to the target repo (empty on sweep path)
#   TARGET_BRANCH          — branch the PR targets (for merge-base derivation)
#
# Category gating:
#   pre-commit-blocked — agent-fixable; consumes a retry iteration
#   signed-off-by      — agent-fixable; consumes a retry iteration
#   secret-scan        — NOT agent-fixable; soft-pass (post-script handles terminally)
#   infra/transient    — NOT agent-fixable; soft-pass

set -euo pipefail

# shellcheck source=lib/post-failure-report.lib.sh
source "${BASH_SOURCE[0]%/*}/lib/post-failure-report.lib.sh"
# shellcheck source=lib/gitleaks-install.lib.sh
source "${BASH_SOURCE[0]%/*}/lib/gitleaks-install.lib.sh"
# shellcheck source=lib/precommit-gate.lib.sh
source "${BASH_SOURCE[0]%/*}/lib/precommit-gate.lib.sh"

# ============================================================================
# Part 1: Schema validation (inline from validate-output-schema.sh)
# ============================================================================

: "${FULLSEND_OUTPUT_SCHEMA:?FULLSEND_OUTPUT_SCHEMA must be set}"

OUTPUT_DIR="output"
if [[ ! -d "${OUTPUT_DIR}" ]]; then
  echo "FAIL: output directory not found"
  exit 1
fi

_output_file="${FULLSEND_OUTPUT_FILE:-agent-result.json}"
_output_file="$(basename "${_output_file}")"
RESULT_FILE="${OUTPUT_DIR}/${_output_file}"
if [[ ! -f "${RESULT_FILE}" ]]; then
  echo "FAIL: ${RESULT_FILE} not found"
  exit 1
fi
echo "Validating: ${RESULT_FILE} against ${FULLSEND_OUTPUT_SCHEMA}"

if ! python3 -m json.tool "${RESULT_FILE}" > /dev/null 2>&1; then
  echo "FAIL: ${RESULT_FILE} is not valid JSON"
  exit 1
fi

if ! python3 -c "import jsonschema" 2>/dev/null; then
  echo "FAIL: python3 jsonschema package is not installed (required by ADR 0022)"
  exit 1
fi

if ! python3 -c "
import json, sys
from jsonschema import validate, ValidationError

with open(sys.argv[1]) as f:
    instance = json.load(f)
with open(sys.argv[2]) as f:
    schema = json.load(f)
try:
    validate(instance=instance, schema=schema)
    print('PASS: output validated against schema')
except ValidationError as e:
    print(f'FAIL: schema validation error: {e.message}')
    if e.path:
        print(f'  at: {\".\".join(str(p) for p in e.path)}')
    if 'properties' in e.schema:
        allowed = ', '.join(sorted(e.schema['properties'].keys()))
        print(f'  allowed properties: {allowed}')
    sys.exit(1)
" "${RESULT_FILE}" "${FULLSEND_OUTPUT_SCHEMA}"; then
  exit 1
fi

# ============================================================================
# Part 2: Pre-commit gate against TARGET_REPO_DIR
# ============================================================================

# Soft-pass when TARGET_REPO_DIR is empty or absent.  The post-loop sweep
# re-validates earlier iterations with the repo dir unavailable — the
# schema half is still valuable, but the pre-commit half has nothing to
# check.
if [ -z "${TARGET_REPO_DIR:-}" ] || [ ! -d "${TARGET_REPO_DIR}" ]; then
  echo "TARGET_REPO_DIR empty or absent — skipping pre-commit gate (sweep path)"
  exit 0
fi

# Resolve the branch to diff against BEFORE leaving the iteration directory.
# The agent declares its target in the structured output Part 1 just
# validated, and that is the branch post-code.src.sh will gate against; the
# TARGET_BRANCH env var is the workflow's default (hard-coded "main" for the
# code harness) and only a fallback. Diffing against the wrong base here
# would lint a different file set from the authoritative post-script gate,
# and the two must agree. Allowlist policy stays in post-code — this is
# just "which ref do I diff against", and an unknown ref falls through the
# merge-base fallback chain below.
AGENT_TARGET="$(jq -r '.target_branch // empty' "${RESULT_FILE}" 2>/dev/null || true)"
TARGET_BRANCH="${AGENT_TARGET:-${TARGET_BRANCH:-main}}"

# The validation script starts in the iteration directory, not the repo.
cd "${TARGET_REPO_DIR}"

# --- Derive changed files (merge-base fallback chain per post-code.src.sh) ---

MERGE_BASE="$(git merge-base "origin/${TARGET_BRANCH}" HEAD 2>/dev/null)" \
  || MERGE_BASE=""
if [ -n "${MERGE_BASE}" ]; then
  CHANGED_FILES="$(git diff --name-only "${MERGE_BASE}..HEAD")"
  SCAN_RANGE="${MERGE_BASE}..HEAD"
else
  gha_echo warning "Could not determine merge-base — trying origin/${TARGET_BRANCH}..HEAD"
  CHANGED_FILES="$(git diff --name-only "origin/${TARGET_BRANCH}..HEAD" 2>/dev/null \
    || git diff --name-only HEAD~1..HEAD 2>/dev/null || true)"
  SCAN_RANGE="HEAD~1..HEAD"
fi

if [ -z "${CHANGED_FILES}" ]; then
  echo "No changed files — skipping pre-commit gate"
  exit 0
fi

echo "Changed files for pre-commit gate:"
echo "${CHANGED_FILES}" | sed 's/^/  /'

# --- Check for Signed-off-by trailers ---
echo "Checking for Signed-off-by trailers..."
if git log --format='%b' "${SCAN_RANGE}" | grep -q '^Signed-off-by:'; then
  echo "FAIL: signed-off-by: Agent commit contains a Signed-off-by trailer. Agents must not use 'git commit -s' or append Signed-off-by trailers."
  exit 1
fi

# --- Install pre-commit tool dependencies ---
precommit_install_deps "${TARGET_BRANCH}"
export PATH="${HOME}/.local/bin:${PATH}"

# --- Run pre-commit gate (check-only, no auto-fix) ---
# The validation loop feeds failures back to the agent via feedback_mode:
# append.  Auto-fix + amend is not appropriate here because TARGET_REPO_DIR
# is an extracted copy — changes would be invisible to the sandbox agent.
# shellcheck disable=SC2034
PRECOMMIT_GATE_AUTOFIX="false"

changed_array=()
while IFS= read -r _line; do
  changed_array+=("${_line}")
done <<< "${CHANGED_FILES}"

precommit_run_gate changed_array "${SCAN_RANGE}" "${TARGET_BRANCH}" "${MERGE_BASE}"

# --- Category gating ---
#
# In check-only mode the lib never reaches its auto-fix branch, which is the
# only place it sets a category other than pre-commit-blocked. So the
# classification the header promises (secret-scan and infra soft-pass) has
# to be derived here, from the hook output itself:
#
#   secret-scan — every failed hook is a secret scanner. The agent cannot
#                 usefully act on a gitleaks/detect-secrets verdict inside a
#                 retry, and the post-script owns terminal handling of it.
#   infra       — pre-commit itself failed before running any hook (no
#                 "- hook id:" lines): bad manifest/config, or a hook-repo
#                 fetch failure on the runner. Nothing the agent can fix.
#
# A hook that fails with "Executable ... not found" still carries a hook id
# and is deliberately NOT soft-passed here: it usually sits alongside
# fixable failures, and dropping the whole iteration would lose those.
# That case is #3746's to classify.
classify_checkonly_failure() {
  local detail="$1"
  local hook_ids
  hook_ids="$(printf '%s\n' "${detail}" | sed -n 's/^- hook id: //p')"
  if [ -z "${hook_ids}" ]; then
    if printf '%s' "${detail}" | grep -qE \
         'An unexpected error has occurred|Invalid(Manifest|Config)Error|Could not resolve host|unable to access|Failed to fetch|failed to clone'; then
      echo "infra"; return 0
    fi
    echo "pre-commit-blocked"; return 0
  fi
  if ! printf '%s\n' "${hook_ids}" | grep -qvE 'gitleaks|detect-secrets|detect-private-key|secret'; then
    echo "secret-scan"; return 0
  fi
  echo "pre-commit-blocked"
}

case "${PRECOMMIT_GATE_RESULT}" in
  pass|skip)
    # All good — nothing to gate.
    ;;
  fail)
    CATEGORY="${PRECOMMIT_GATE_CATEGORY}"
    if [ "${CATEGORY}" = "pre-commit-blocked" ]; then
      CATEGORY="$(classify_checkonly_failure "${PRECOMMIT_GATE_DETAIL}")"
    fi
    case "${CATEGORY}" in
      pre-commit-blocked|signed-off-by)
        # Agent-fixable: consume a retry iteration with feedback. The lib
        # already printed the sanitised hook output above — do not echo it
        # again: this stream is truncated to 10 KiB before it becomes the
        # next iteration's prompt, and a second copy halves what the agent
        # gets to see of a verbose linter.
        echo "FAIL: ${CATEGORY} — fix the hook failures reported above"
        exit 1
        ;;
      secret-scan)
        gha_echo warning "secret-scan hook failure — deferring to post-script (terminal); not consuming an iteration"
        ;;
      infra)
        gha_echo warning "pre-commit itself failed before running hooks (infra/transient) — soft-pass; not consuming an iteration"
        ;;
    esac
    ;;
esac
