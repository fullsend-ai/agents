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
# Signed-off-by trailer helpers
#
# The post-scripts strip an agent's trailer instead of discarding the run.
# SCAN_RANGE can cover human commits (post-fix widens it to merge-base after a
# rebase), and a human's sign-off is a DCO attestation that must survive, so
# every helper is scoped to agent-authored commits.
# ---------------------------------------------------------------------------

# signoff_bot_email — agent's git identity, exported by the dispatch workflow.
# Empty means unknown: detection stays broad so a trailer is still noticed, but
# signoff_strip_range refuses to rewrite rather than risk a human's sign-off.
signoff_bot_email() {
  printf '%s' "${GIT_BOT_EMAIL:-${GIT_COMMITTER_EMAIL:-}}"
}

# signoff_is_bot_commit <sha> — 0 when the commit is in scope for rewriting.
# Author, not committer: a rebase re-stamps the committer onto commits the
# human wrote. Author is also what the DCO app checks when it waives bots.
signoff_is_bot_commit() {
  local _sb_bot
  _sb_bot="$(signoff_bot_email)"
  [ -z "${_sb_bot}" ] && return 0
  [ "$(git log -1 --format='%ae' "$1" 2>/dev/null)" = "${_sb_bot}" ]
}

# signoff_count_range <range> — number of in-scope commits carrying a trailer.
signoff_count_range() {
  local _sc_n=0 _sc_sha
  for _sc_sha in $(git rev-list "$1" 2>/dev/null); do
    if signoff_is_bot_commit "${_sc_sha}" \
       && git log -1 --format='%B' "${_sc_sha}" | grep -q '^Signed-off-by:'; then
      _sc_n=$((_sc_n + 1))
    fi
  done
  printf '%s' "${_sc_n}"
}

# signoff_present_in_range <range> — 0 when an in-scope commit carries one.
signoff_present_in_range() {
  [ "$(signoff_count_range "$1")" -gt 0 ]
}

# signoff_strip_range <range> — drop the trailer from in-scope messages.
# Diagnoses to stderr and returns non-zero on rewrite failure so callers fail
# closed. Never touches commits below the range's base.
signoff_strip_range() {
  local _ss_range="$1" _ss_bot _ss_tmp _ss_sed _ss_sha
  local _ss_base="" _ss_tip_n=0 _ss_in_tip=1 _ss_below=0
  _ss_bot="$(signoff_bot_email)"
  # Skip line 1 so a message whose subject IS the trailer keeps a subject.
  _ss_sed='1!{/^Signed-off-by:/d;}'

  # Without an identity every commit looks like the agent's, and the range can
  # hold a human's DCO sign-off. Refuse rather than guess.
  if [ -z "${_ss_bot}" ]; then
    echo "signoff-strip: agent git identity unavailable (GIT_BOT_EMAIL unset)" >&2
    return 1
  fi

  # Narrow the rewrite to the contiguous run of agent commits at the tip.
  # filter-branch re-creates every commit it is handed even when the filter is
  # cat, and commit-tree cannot reproduce gpgsig, so a human commit inside the
  # range would lose its signature and change SHA. Agent commits sit at the
  # tip in practice; an in-scope trailer below a human commit fails closed.
  for _ss_sha in $(git rev-list "${_ss_range}" 2>/dev/null); do
    if [ "${_ss_in_tip}" -eq 1 ] && signoff_is_bot_commit "${_ss_sha}"; then
      _ss_tip_n=$((_ss_tip_n + 1))
      _ss_base="${_ss_sha}"
    else
      _ss_in_tip=0
      if signoff_is_bot_commit "${_ss_sha}" \
         && git log -1 --format='%B' "${_ss_sha}" | grep -q '^Signed-off-by:'; then
        _ss_below=1
      fi
    fi
  done
  if [ "${_ss_below}" -eq 1 ]; then
    echo "signoff-strip: an agent commit with a trailer sits below a non-agent commit; refusing to rewrite past it" >&2
    return 1
  fi
  [ "${_ss_tip_n}" -eq 0 ] && return 0

  # filter-branch refuses on unstaged changes; refresh first because
  # diff-files is stat-based and a fresh checkout can look dirty.
  git update-index -q --refresh >/dev/null 2>&1 || true
  if ! git diff-files --quiet; then
    echo "signoff-strip: worktree has unstaged changes to tracked files" >&2
    return 1
  fi

  if [ "${_ss_tip_n}" -eq 1 ]; then
    _ss_tmp="$(mktemp)"
    if ! git log -1 --format='%B' HEAD | sed "${_ss_sed}" > "${_ss_tmp}"; then
      rm -f "${_ss_tmp}"
      echo "signoff-strip: could not read the commit message" >&2
      return 1
    fi
    # --amend re-stamps the committer, so carry the original across.
    # --only keeps it to the message; a bare --amend would sweep staged
    # files in past the secret scan.
    if ! GIT_COMMITTER_NAME="$(git log -1 --format='%cn' HEAD)" \
         GIT_COMMITTER_EMAIL="$(git log -1 --format='%ce' HEAD)" \
         GIT_COMMITTER_DATE="$(git log -1 --format='%cD' HEAD)" \
         git commit --amend --only --no-verify -F "${_ss_tmp}" >/dev/null; then
      rm -f "${_ss_tmp}"
      echo "signoff-strip: git commit --amend failed" >&2
      return 1
    fi
    rm -f "${_ss_tmp}"
    return 0
  fi

  # filter-branch also refuses on a dirty index. The single-commit path above
  # tolerates one, because --only keeps staged files out of the commit.
  if ! git diff-index --quiet --cached HEAD; then
    echo "signoff-strip: index has staged changes" >&2
    return 1
  fi

  # The narrowed range is agent-only by construction; the author check in the
  # filter is a second line of defence. filter-branch exports each original
  # commit's identity, so $GIT_AUTHOR_EMAIL is the commit being rewritten. The
  # bot address goes through the environment, not the filter text: it
  # contains "[bot]" and "+".
  if ! FILTER_BRANCH_SQUELCH_WARNING=1 SIGNOFF_BOT_EMAIL="${_ss_bot}" \
       git filter-branch -f \
       --msg-filter 'if [ "${GIT_AUTHOR_EMAIL}" = "${SIGNOFF_BOT_EMAIL}" ]; then sed '"'${_ss_sed}'"'; else cat; fi' \
       -- "${_ss_base}^..HEAD" >/dev/null; then
    echo "signoff-strip: git filter-branch failed" >&2
    return 1
  fi
  return 0
}

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
    # The auto-fix amend above can only have re-added a trailer to HEAD (a repo
    # commit-msg hook); section 3b already cleaned the rest of the range.
    if signoff_present_in_range "${_pg_scan_range}"; then
      gha_echo warning "Signed-off-by trailer found after auto-fix amend — stripping"
      if ! signoff_strip_range "${_pg_scan_range}"; then
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_SIGNOFF_FAIL="true"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_RESULT="fail"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_CATEGORY="signoff-rewrite-failed"
        # shellcheck disable=SC2034
        PRECOMMIT_GATE_DETAIL="Could not strip the Signed-off-by trailer added after pre-commit auto-fix."
        return 0
      fi
      # Re-scan: fail only if a trailer survives a rewrite that reported success
      if signoff_present_in_range "${_pg_scan_range}"; then
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
