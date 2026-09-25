#!/usr/bin/env bash
# validate-code-output.src.sh — Validate code/fix agent output: schema +
# finding coverage (fix) + pre-commit.
#
# Wraps validate-output-schema.sh's schema check with an additional pre-commit
# gate run against TARGET_REPO_DIR.  Used as the validation_loop.script for the
# code and fix harnesses so that a lint or type-check failure consumes a retry
# iteration (with feedback) instead of ending the run terminally in the
# post-script. For the fix agent, also checks that every structured finding
# tag in REVIEW_BODY_FILE is covered by an actions[].finding value.
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
#   REVIEW_BODY_FILE       — raw review body (fix agent; finding-coverage check)
#   FULLSEND_FORGE         — "github"/"gitlab" (fix agent; gates the GitHub
#                            pointer-body recovery below)
#   REPO_FULL_NAME         — "owner/repo" (fix agent; pointer-body recovery)
#   PR_NUMBER              — PR number (fix agent; pointer-body recovery)
#   TRIGGER_SOURCE         — forge username that triggered the fix (fix agent;
#                            selects the review-agent comment to recover)
#   PUSH_TOKEN / GH_TOKEN  — GitHub auth for the recovery API call (same
#                            PUSH_TOKEN-as-GH_TOKEN pattern as post-fix.src.sh)
#
# Category gating:
#   pre-commit-blocked — agent-fixable; consumes a retry iteration
#   signed-off-by      — NOT agent-fixable; soft-pass (post-script strips it)
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
# Part 1.5: Fix-agent finding coverage (fix-result schema only)
# ============================================================================
# Counts `- **[category]**` bullets in the raw review body and requires each
# occurrence to appear as `[category]` in some actions[].finding. Runs against
# the review payload the agent received, not the agent's restated summary.
# Skip when the schema is not fix-result, REVIEW_BODY_FILE is unset/missing,
# or the body has no structured findings (empty human /fs-fix eval path).
#
# On GitHub, COMMENT/CHANGES_REQUESTED reviews post the full structured
# findings as a separate issue comment marked `<!-- fullsend:review-agent -->`
# (skills/fix-review/github/SKILL.md's "Review findings fallback"); the
# formal review body copied into REVIEW_BODY_FILE contains only a pointer
# sentence ("See the [review comment](...) for full details."). The
# sandbox-side skill recovers the full comment via the issue-comments API,
# but that recovery never reaches this runner-side file, so a naive read of
# REVIEW_BODY_FILE here would parse zero findings and silently skip the
# coverage check on the exact flow it exists to guard. Recover the same way
# here, and fail closed (not skip) when recovery is unavailable or comes up
# empty, so an unresolved pointer body cannot be mistaken for "no findings".

review_body_is_pointer_only() {
  local file="$1"
  # A genuinely empty/whitespace-only body is a legitimate "no review" case
  # (e.g. a human /fs-fix run with no prior review) already handled as a
  # skip by review-finding-coverage.py itself — leave that alone here.
  #
  # Unlike the sandbox-side skill's fallback trigger (which also treats any
  # body under 200 bytes as worth a fallback attempt — a cheap, safe guess
  # to make from inside the agent's own sandbox), this check intentionally
  # only matches the literal known pointer sentence. A blanket length
  # threshold here would misclassify genuinely short-but-real review bodies
  # (e.g. a terse structured review, or "LGTM") as pointer-only and either
  # overwrite them with an unrelated resolved comment or fail closed on
  # content that never needed resolving.
  grep -q '[^[:space:]]' "${file}" || return 1
  grep -qxE 'See the .*review comment.*for full details\.?' "${file}"
}

resolve_pointer_review_body() {
  # Prints the recovered review-agent comment body on success. Prints
  # nothing and returns 1 on any failure: non-GitHub forge, missing
  # PR/repo context, no gh/jq on the runner, an API error, or no matching
  # comment. Mirrors skills/fix-review/github/SKILL.md's fallback.
  if [ "${FULLSEND_FORGE:-}" != "github" ]; then
    return 1
  fi
  if [ -z "${REPO_FULL_NAME:-}" ] || [ -z "${PR_NUMBER:-}" ]; then
    return 1
  fi
  if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  local login_select
  case "${TRIGGER_SOURCE:-}" in
    *"[bot]") login_select='select(.user.login == $login)' ;;
    *) login_select='select(.user.login | endswith("-review[bot]"))' ;;
  esac

  local comments
  comments="$(GH_TOKEN="${PUSH_TOKEN:-${GH_TOKEN:-}}" gh api --paginate --slurp \
    "repos/${REPO_FULL_NAME}/issues/${PR_NUMBER}/comments" 2>/dev/null)" || return 1

  local comment
  comment="$(printf '%s' "${comments}" | jq -r --arg login "${TRIGGER_SOURCE:-}" \
    "add // [] | [.[] | ${login_select} | select(.body | contains(\"<!-- fullsend:review-agent -->\"))] | last | .body // empty" \
    2>/dev/null)" || return 1

  [ -n "${comment}" ] || return 1
  printf '%s' "${comment}"
}

_schema_base="$(basename "${FULLSEND_OUTPUT_SCHEMA}")"
case "${_schema_base}" in
  fix-result.schema.json)
    _coverage_py="${BASH_SOURCE[0]%/*}/review-finding-coverage.py"
    if [ -z "${REVIEW_BODY_FILE:-}" ]; then
      echo "REVIEW_BODY_FILE unset — skipping finding coverage"
    elif [ ! -f "${REVIEW_BODY_FILE}" ]; then
      echo "REVIEW_BODY_FILE not a file — skipping finding coverage"
    elif [ ! -f "${_coverage_py}" ]; then
      echo "FAIL: review-finding-coverage.py not found at ${_coverage_py}"
      exit 1
    else
      _coverage_body_file="${REVIEW_BODY_FILE}"
      if review_body_is_pointer_only "${REVIEW_BODY_FILE}"; then
        _resolved_body="$(resolve_pointer_review_body)" || _resolved_body=""
        if [ -n "${_resolved_body}" ]; then
          echo "REVIEW_BODY_FILE is pointer-only — resolved full findings via GitHub issue-comment API"
          _coverage_body_file="$(mktemp)"
          printf '%s' "${_resolved_body}" > "${_coverage_body_file}"
        else
          echo "FAIL: REVIEW_BODY_FILE is pointer-only (full findings posted as a separate issue comment) and could not be resolved via the GitHub issue-comment API fallback — cannot verify finding coverage"
          exit 1
        fi
      fi
      python3 "${_coverage_py}" "${RESULT_FILE}" "${_coverage_body_file}" || exit 1
    fi
    ;;
esac
unset _schema_base _coverage_py _coverage_body_file _resolved_body

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
#
# Soft-pass, same bucket as secret-scan: the post-scripts strip the trailer,
# so failing here would burn an iteration for something already repaired.
# A rewrite here is impossible anyway — TARGET_REPO_DIR is an extracted copy
# and PRECOMMIT_GATE_AUTOFIX="false" forbids git writes.
echo "Checking for Signed-off-by trailers..."
if git log --format='%B' "${SCAN_RANGE}" | grep -q '^Signed-off-by:'; then
  gha_echo warning "Signed-off-by trailer present — deferring to post-script (strips it); not consuming an iteration"
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
      pre-commit-blocked)
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
