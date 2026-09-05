#!/usr/bin/env bash
# precommit-gate.lib.sh — Shared pre-commit gate for validation loop and post-scripts.
#
# Source from validate-code-output.src.sh / post-code.src.sh / post-fix.src.sh:
#   source "${SCRIPT_DIR}/lib/precommit-gate.lib.sh"
#
# Provides:
#   precommit_install_deps  — Auto-install pre-commit tool dependencies
#   precommit_run_gate      — Run pre-commit with optional auto-fix retry
#
# Output contract (set by precommit_run_gate, read by callers):
#   PRECOMMIT_GATE_RESULT       — "pass" | "fail" | "skip"
#   PRECOMMIT_GATE_CATEGORY     — failure category
#   PRECOMMIT_GATE_DETAIL       — failure detail text
#   PRECOMMIT_GATE_SECRET_FAIL  — "true" if secret-scan failed after auto-fix
#   PRECOMMIT_GATE_SIGNOFF_FAIL — "true" if signed-off-by failed after auto-fix
#
# Optional controls (set by callers before calling precommit_run_gate):
#   PRECOMMIT_GATE_AUTOFIX      — "true" (default) to auto-fix + amend;
#                                  "false" to check-only (no git writes)

# shellcheck shell=bash

[[ -n "${PRECOMMIT_GATE_SH_LOADED:-}" ]] && return 0
PRECOMMIT_GATE_SH_LOADED=1

# ---------------------------------------------------------------------------
# precommit_install_deps <target_branch>
#
# Auto-install pre-commit tool dependencies from .pre-commit-tools.yaml.
# Looks for resolve-precommit-tools.py and install-precommit-tools.sh
# relative to the calling script, then in workspace fallback paths.
# ---------------------------------------------------------------------------
precommit_install_deps() {
  local _pid_target_branch="${1:-main}"

  if [ ! -f .pre-commit-config.yaml ]; then
    return 0
  fi

  # Locate companion scripts.  The BASH_SOURCE-relative lookup covers the
  # case where the caller (post-code.sh, post-fix.sh) sits next to them;
  # the workspace fallback covers the common CI layout.
  local _pid_resolve="" _pid_install=""
  local _pid_script_dir
  # BASH_SOURCE[1] is the direct caller of this function (the sourcing
  # script).  Fall back to BASH_SOURCE[0] (this lib itself, which the
  # bundler inlines into the caller).
  _pid_script_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"

  if [ -f "${_pid_script_dir}/resolve-precommit-tools.py" ] \
     && [ -f "${_pid_script_dir}/install-precommit-tools.sh" ]; then
    _pid_resolve="${_pid_script_dir}/resolve-precommit-tools.py"
    _pid_install="${_pid_script_dir}/install-precommit-tools.sh"
  fi

  # Workspace fallback — these companion scripts were never migrated into
  # this repo, so the BASH_SOURCE lookup above usually misses.
  if [ -z "${_pid_resolve}" ] || [ -z "${_pid_install}" ]; then
    local _pid_ws="${CI_PROJECT_DIR:-${GITHUB_WORKSPACE:-}}"
    if [ -n "${_pid_ws}" ]; then
      local _pid_cand
      for _pid_cand in "${_pid_ws}/scripts" "${_pid_ws}/.fullsend/scripts"; do
        if [ -f "${_pid_cand}/resolve-precommit-tools.py" ] \
           && [ -f "${_pid_cand}/install-precommit-tools.sh" ]; then
          _pid_resolve="${_pid_cand}/resolve-precommit-tools.py"
          _pid_install="${_pid_cand}/install-precommit-tools.sh"
          break
        fi
      done
    fi
  fi

  if [ -z "${_pid_resolve}" ] || [ -z "${_pid_install}" ]; then
    gha_echo warning "Pre-commit tool auto-install skipped: companion scripts not found"
    gha_echo warning "Pre-commit hooks requiring system tools (e.g. lychee) may fail"
    return 0
  fi

  local _pid_manifest _pid_local_reg
  _pid_manifest="$(mktemp)"
  _pid_local_reg="$(mktemp)"
  local _pid_args=(".")
  if git show "origin/${_pid_target_branch}:.pre-commit-tools.yaml" \
       > "${_pid_local_reg}" 2>/dev/null; then
    _pid_args+=("--local-registry" "${_pid_local_reg}")
  fi
  if python3 "${_pid_resolve}" "${_pid_args[@]}" > "${_pid_manifest}"; then
    if [ -s "${_pid_manifest}" ] \
       && jq -e '.tools | length > 0' "${_pid_manifest}" >/dev/null 2>&1; then
      bash "${_pid_install}" "${_pid_manifest}"
    fi
  else
    gha_echo warning "Pre-commit tool resolution failed — continuing without auto-install"
  fi
  rm -f "${_pid_manifest}" "${_pid_local_reg}"
}

# ---------------------------------------------------------------------------
# precommit_run_gate <changed_files_var> <scan_range> <target_branch> <merge_base>
#
# Run pre-commit on changed files with optional auto-fix retry.
#
# Parameters:
#   $1 — name of a bash array variable holding changed file paths (nameref)
#   $2 — git range for gitleaks re-scan after auto-fix (e.g. "abc123..HEAD")
#   $3 — target branch name (for fallback diff derivation)
#   $4 — merge-base commit (for diff derivation after auto-fix)
#
# The function always returns 0.  Callers inspect the output variables to
# decide what to do (post_fail_to_issue, exit 1, etc.).
#
# When PRECOMMIT_GATE_AUTOFIX is "false", no git writes occur — the
# function runs pre-commit once and reports the result.  This is the
# mode used by the validation-loop script, where the repo is an
# extracted copy and git amends would be invisible to the sandbox agent.
# ---------------------------------------------------------------------------
precommit_run_gate() {
  local -n _pg_files=$1
  local _pg_scan_range="$2"
  local _pg_target_branch="$3"
  local _pg_merge_base="$4"

  # Output contract — callers read these after the function returns.
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_RESULT="skip"
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_CATEGORY=""
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_DETAIL=""
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_SECRET_FAIL="false"
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_SIGNOFF_FAIL="false"

  if [ ! -f .pre-commit-config.yaml ]; then
    echo "No .pre-commit-config.yaml — skipping pre-commit check"
    return 0
  fi

  if ! command -v pre-commit >/dev/null 2>&1; then
    echo "Installing pre-commit..."
    pip install "pre-commit==4.5.1" 2>/dev/null \
      || pip3 install "pre-commit==4.5.1" 2>/dev/null \
      || pipx install "pre-commit==4.5.1" 2>/dev/null \
      || gha_echo warning "Failed to install pre-commit"
  fi

  if ! command -v pre-commit >/dev/null 2>&1; then
    gha_echo warning "pre-commit not available — skipping authoritative check"
    return 0
  fi

  echo "Running pre-commit on changed files..."
  local _pg_output=""
  if _pg_output="$(pre-commit run --files "${_pg_files[@]}" 2>&1)"; then
    print_sanitized_gha_log "${_pg_output}"
    echo "Pre-commit passed — all hooks clean"
    # shellcheck disable=SC2034
    PRECOMMIT_GATE_RESULT="pass"
    return 0
  fi

  print_sanitized_gha_log "${_pg_output}"

  # --- Auto-fix retry (only when PRECOMMIT_GATE_AUTOFIX is not "false") ---
  if [ "${PRECOMMIT_GATE_AUTOFIX:-true}" != "false" ] \
     && git diff --name-only -- "${_pg_files[@]}" | grep -q .; then
    gha_echo warning "Pre-commit hooks auto-fixed files — re-staging and retrying"
    echo "Auto-fixed files:"
    git diff --name-only -- "${_pg_files[@]}" | sed 's/^/  /'
    git diff --name-only -z -- "${_pg_files[@]}" | xargs -0 -r git add --
    git commit --amend --no-edit

    # Re-run secret scan on the amended commit.
    echo "Re-running secret scan on amended commit..."
    local _pg_gl_output=""
    if ! _pg_gl_output="$(gitleaks detect --source . \
           --log-opts="${_pg_scan_range}" --redact 2>&1)"; then
      print_sanitized_gha_log "${_pg_gl_output}" stderr
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_SECRET_FAIL="true"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_RESULT="fail"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_CATEGORY="secret-scan"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_DETAIL="${POST_FAILURE_SECRET_SCAN_MESSAGE}"
      return 0
    fi

    # Re-check signed-off-by trailers — strip if present (defense-in-depth).
    if git log --format='%b' "${_pg_scan_range}" | grep -q '^Signed-off-by:'; then
      gha_echo warning "Signed-off-by trailer found after auto-fix amend — stripping"
      _pg_signoff_tmpfile="$(mktemp)"
      git log -1 --format='%B' HEAD | sed '/^Signed-off-by:/d' > "${_pg_signoff_tmpfile}"
      git commit --amend -F "${_pg_signoff_tmpfile}"
      rm -f "${_pg_signoff_tmpfile}"
      # Re-scan: fail only if trailer survives the rewrite
      if git log --format='%b' "${_pg_scan_range}" | grep -q '^Signed-off-by:'; then
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_SIGNOFF_FAIL="true"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_RESULT="fail"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_CATEGORY="signed-off-by"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_DETAIL="Signed-off-by trailer persists after rewrite attempt."
        return 0
      fi
      echo "Signed-off-by trailer removed after auto-fix amend"
    fi

    # Re-derive changed files after the amend.
    local _pg_new_changed=""
    if [ -n "${_pg_merge_base}" ]; then
      _pg_new_changed="$(git diff --name-only "${_pg_merge_base}..HEAD")"
    else
      _pg_new_changed="$(git diff --name-only \
        "origin/${_pg_target_branch}..HEAD" 2>/dev/null \
        || git diff --name-only HEAD~1..HEAD 2>/dev/null || true)"
    fi

    if [ -z "${_pg_new_changed}" ]; then
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_RESULT="fail"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_CATEGORY="pre-commit-blocked"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_DETAIL="Pre-commit hooks removed all changes; commit is now empty."
      return 0
    fi

    # Rebuild the caller's array with the updated file list.
    _pg_files=()
    while IFS= read -r _pg_line; do
      _pg_files+=("${_pg_line}")
    done <<< "${_pg_new_changed}"

    # Single retry.
    local _pg_retry_output=""
    if _pg_retry_output="$(pre-commit run --files "${_pg_files[@]}" 2>&1)"; then
      print_sanitized_gha_log "${_pg_retry_output}"
      if git diff --name-only -- "${_pg_files[@]}" | grep -q .; then
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_RESULT="fail"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_CATEGORY="pre-commit-blocked"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_DETAIL="Retry pre-commit left additional unstaged changes; committed content would diverge from what pre-commit validated."
        return 0
      fi
      echo "Pre-commit passed after auto-fix re-stage"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_RESULT="pass"
      return 0
    else
      print_sanitized_gha_log "${_pg_retry_output}"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_RESULT="fail"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_CATEGORY="pre-commit-blocked"
      # shellcheck disable=SC2034
      PRECOMMIT_GATE_DETAIL="${_pg_retry_output}"
      return 0
    fi
  fi

  # No auto-fix attempted (either disabled or no files were modified by hooks).
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_RESULT="fail"
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_CATEGORY="pre-commit-blocked"
  # shellcheck disable=SC2034
  PRECOMMIT_GATE_DETAIL="${_pg_output}"
}
