#!/usr/bin/env bash
# Post-script: push the fix agent's commit and process structured output.
#
# Runs on the GitHub Actions / GitLab CI runner AFTER the sandbox is destroyed.
# This script has write access to the target repo — it is the most
# security-sensitive component in the fix pipeline.
#
# Security layers (defense-in-depth):
#   - Authoritative secret scan — final gate before any push
#   - Auto-install pre-commit tool deps (from .pre-commit-tools.yaml)
#   - Authoritative pre-commit — run repo hooks on changed files
#   - Branch validation — refuse to push main/master
#   - Token isolation — PUSH_TOKEN never enters the sandbox
#
# Protected-path enforcement lives in post-review.sh: the review agent
# cannot approve PRs that touch sensitive paths (e.g. .github/, CODEOWNERS,
# agents/). The fix agent is free to propose changes to any path.
#
# Steps:
#   0. Check for agent commits
#   1. Authoritative secret scan
#   2. Auto-install pre-commit tool deps (from .pre-commit-tools.yaml)
#   3. Authoritative pre-commit check
#   4. Push branch
#   5. Process structured output
#   6. Iteration-cap warning label
#   7. Summary
#
# After pushing, this script processes agent-result.json to:
#   - Post a summary comment on the PR documenting fixes and disagreements
#   - Apply labels (needs-human) if the iteration cap is approaching
#
# Required environment variables:
#   PUSH_TOKEN        — token with contents:write + issues:write + pull-requests:write
#                       on target repo (GitHub App installation token, PAT,
#                       or GitLab personal/project access token)
#   REPO_FULL_NAME    — owner/repo
#   PR_NUMBER         — PR number
#   REPO_DIR          — path to extracted repo (default: current directory)
#   TRIGGER_SOURCE    — forge username that triggered the fix (GitHub: [bot] suffix; GitLab: _bot suffix)
#
# Optional environment variables:
#   FIX_ITERATION     — current iteration count
#   ITERATION_CAP     — max iterations (default: 5); a live
#                       `fullsend-fix-budget/N` PR label can lower it
#   PUSH_TOKEN_SOURCE — "github-app" (for logging)
#   HUMAN_INSTRUCTION — the harness-captured /fs-fix comment text (only for
#                       human-triggered runs); used to confirm a rebase or
#                       squash/redo was actually requested before trusting
#                       rebased_onto_target / history_rewritten
#   FIX_CONFLICT_UPDATE_STRATEGY
#                     — merge (default) or rebase; how to publish a
#                       forge-reported merge conflict the agent reconciled
#   POST_FAILURE_DETAIL_MAX_LINES
#                     — max lines of failure detail in issue/PR comments (default: 30)
#
# Exit codes:
#   0  — branch pushed, PR updated
#   1  — validation failure or error (nothing pushed)
set -euo pipefail

SCRIPT_DIR_POST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
SCRIPT_DIR="${SCRIPT_DIR_POST}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE is required — set to 'github' or 'gitlab'}"
# shellcheck source=lib/fix-ops.lib.sh
source "${SCRIPT_DIR_POST}/lib/fix-ops.lib.sh"
# shellcheck source=lib/post-failure-report.lib.sh
source "${SCRIPT_DIR_POST}/lib/post-failure-report.lib.sh"
# shellcheck source=lib/gitleaks-install.lib.sh
source "${SCRIPT_DIR_POST}/lib/gitleaks-install.lib.sh"
# shellcheck source=lib/precommit-gate.lib.sh
source "${SCRIPT_DIR_POST}/lib/precommit-gate.lib.sh"
# shellcheck source=lib/branch-guard.lib.sh
source "${SCRIPT_DIR_POST}/lib/branch-guard.lib.sh"


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
REPO_DIR="${REPO_DIR:-repo}"
RUN_DIR="$(pwd)"

: "${PUSH_TOKEN:?PUSH_TOKEN is required}"
: "${REPO_FULL_NAME:?REPO_FULL_NAME is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${TRIGGER_SOURCE:?TRIGGER_SOURCE is required}"
trap 'report_post_failure_to_pr' ERR

[[ "${PR_NUMBER}" =~ ^[1-9][0-9]*$ ]] || \
  post_fail_to_pr setup-error "PR_NUMBER must be numeric, got '${PR_NUMBER}'"

if [ "${FULLSEND_FORGE:-}" = "github" ]; then
  [[ "${REPO_FULL_NAME}" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]] || \
    post_fail_to_pr setup-error "REPO_FULL_NAME must be owner/repo format, got '${REPO_FULL_NAME}'"
else
  [[ "${REPO_FULL_NAME}" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+$ ]] || \
    post_fail_to_pr setup-error "REPO_FULL_NAME must be owner/repo (or group/subgroup/project) format, got '${REPO_FULL_NAME}'"
fi
[[ ! "${REPO_FULL_NAME}" =~ (^|/)\.\.?(/|$) ]] || \
  post_fail_to_pr setup-error "REPO_FULL_NAME must not contain '.' or '..' path segments, got '${REPO_FULL_NAME}'"

if [ "${REPO_DIR}" != "." ]; then
  if [ ! -d "${REPO_DIR}" ]; then
    gha_echo error "Extracted repo not found at ${REPO_DIR}" >&2
    post_fail_to_pr setup-error "Extracted repo not found at ${REPO_DIR}"
  fi
  cd "${REPO_DIR}"
fi

TARGET_BRANCH="${TARGET_BRANCH:-main}"

forge_mask_token "${PUSH_TOKEN}"
if [ -n "${GITLAB_TOKEN:-}" ]; then
  forge_mask_token "${GITLAB_TOKEN}"
fi

# GitLab needs REPO_ENCODED and GITLAB_HOST for API calls.
# Always derive GITLAB_HOST from the validated PR_URL. If GITLAB_HOST is
# already set (e.g. by the harness), verify it matches the URL to prevent
# token exfiltration to a mismatched host.
if [ "${FULLSEND_FORGE:-}" = "gitlab" ]; then
  if [[ -z "${PR_URL:-}" ]]; then
    gha_echo error "PR_URL is required for GitLab forge"
    exit 1
  fi
  if ! forge_validate_pr_url "${PR_URL}"; then
    gha_echo error "PR_URL format invalid for GitLab: '${PR_URL}'"
    exit 1
  fi
  local_url_host="$(echo "${PR_URL}" | sed -E 's|^https://([^/:]+)/.*|\1|')"
  if [[ -n "${GITLAB_HOST:-}" && "${GITLAB_HOST}" != "${local_url_host}" ]]; then
    gha_echo error "GITLAB_HOST '${GITLAB_HOST}' does not match PR URL host '${local_url_host}'"
    exit 1
  fi
  GITLAB_HOST="${local_url_host}"
  _url_repo="$(echo "${PR_URL}" | sed -E 's|^https://[^/]+/(.+)/-/merge_requests/[0-9]+$|\1|')"
  _url_pr="$(basename "${PR_URL}")"
  if [[ -n "${_url_repo}" && "${_url_repo}" != "${REPO_FULL_NAME}" ]]; then
    gha_echo error "REPO_FULL_NAME does not match PR URL repo ('${REPO_FULL_NAME}' vs '${_url_repo}')"
    exit 1
  fi
  if [[ -n "${_url_pr}" && "${_url_pr}" != "${PR_NUMBER}" ]]; then
    gha_echo error "PR_NUMBER does not match PR URL number ('${PR_NUMBER}' vs '${_url_pr}')"
    exit 1
  fi
  REPO_ENCODED=$(printf '%s' "${REPO_FULL_NAME}" | jq -sRr @uri)
  export GITLAB_HOST REPO_ENCODED
fi

# Prefer the change request's actual base branch over a hardcoded default,
# but only while reconciling a real forge-reported conflict (issue #1518).
# TARGET_BRANCH otherwise feeds unrelated pre-existing logic (merge-base
# computation, precommit scan range, squash-request validation) that
# predates this feature and must keep using the harness-configured value —
# substituting the forge base branch on every run would change that
# logic's behavior far beyond issue #1518's stated scope. Empty API
# responses keep TARGET_BRANCH as-is.
if forge_pr_has_merge_conflict "${PR_NUMBER}" 2>/dev/null; then
  _forge_base="$(forge_get_pr_base_branch "${PR_NUMBER}" 2>/dev/null || true)"
  if [ -n "${_forge_base}" ]; then
    if [ "${TARGET_BRANCH}" != "${_forge_base}" ]; then
      echo "PR/MR base branch is ${_forge_base} (TARGET_BRANCH was ${TARGET_BRANCH})"
    fi
    TARGET_BRANCH="${_forge_base}"
  fi
fi

# ---------------------------------------------------------------------------
# 0. Check for agent commits
# ---------------------------------------------------------------------------
BRANCH="$(git branch --show-current)"

# Set by 1b, surfaced on the PR by process-fix-result.py. Declared here
# because 1b only runs when NO_PUSH=false.
SIGNOFF_STRIPPED=false
SIGNOFF_STRIPPED_COUNT=0

if [ -z "${BRANCH}" ] || [ "${BRANCH}" = "main" ] || [ "${BRANCH}" = "master" ]; then
  gha_echo warning "Agent did not produce a commit on a feature branch (current: '${BRANCH:-detached HEAD}')"
  gha_echo warning "Processing structured output only (no push)."
  # Still process agent-result.json to post a summary comment.
  NO_PUSH=true
else
  NO_PUSH=false
fi

# ---------------------------------------------------------------------------
# 0b. Verify branch matches the PR's head ref
#
# The fix agent is dispatched to modify a specific PR. Verify the agent's
# local branch matches that PR's head ref to prevent a compromised agent
# from pushing commits to a different PR's branch.
# ---------------------------------------------------------------------------
if [ "${NO_PUSH}" = "false" ]; then
  EXPECTED_BRANCH=""
  HEAD_REF_RC=1
  for _attempt in 1 2 3; do
    # shellcheck disable=SC2153
    if EXPECTED_BRANCH="$(forge_get_pr_head_ref "${PR_NUMBER}")"; then
      HEAD_REF_RC=0
      break
    fi
    sleep 2
  done
  if [ "${HEAD_REF_RC}" -ne 0 ] || [ -z "${EXPECTED_BRANCH}" ]; then
    post_fail_to_pr branch-mismatch \
      "Could not resolve PR #${PR_NUMBER} head ref after 3 attempts — refusing to push."
  fi
  if [ "$(classify_branch_vs_pr_head "${BRANCH}" "${EXPECTED_BRANCH}")" = "mismatch" ]; then
    post_fail_to_pr branch-mismatch \
      "Agent branch '${BRANCH}' does not match PR #${PR_NUMBER} head ref '${EXPECTED_BRANCH}'. Refusing to push."
  fi
fi

# ---------------------------------------------------------------------------
# 0c. Force-fetch the target branch and pin a trusted SHA (on demand).
#
# origin/${TARGET_BRANCH} is a local remote-tracking ref inside the runner's
# checkout of the sandbox's extracted repo. Unlike origin/${BRANCH} (force-
# fetched below, right before the push), nothing previously refreshed it
# before it got used for security-relevant computations: the DIFF_BASE
# rebase-detection fallback just below (which sizes the gitleaks/pre-commit
# SCAN_RANGE), the squash fork point, and the squash single-commit publish
# bound. A locally-moved ref (e.g. via a stray `git update-ref`) could
# silently shrink the scan range or satisfy the squash bound without the
# per-commit preservation check ever running (PR #1335). Fetch it fresh —
# via the same authenticated remote used for the origin/${BRANCH} fetch
# below (the extracted repo's origin has no working credentials until
# forge_set_push_remote runs) — and pin the resulting SHA once, then reuse
# that pinned value everywhere below instead of re-reading the mutable ref.
# Memoized and called lazily from each use site below: it is only needed
# on paths that actually consult the target branch (a detected history
# rewrite, or the squash/redo publish gate), not on every push.
# ---------------------------------------------------------------------------
TRUSTED_TARGET_SHA=""
fetch_trusted_target_sha() {
  local _trusted_target_restore_url TARGET_FETCH_OUTPUT TARGET_FETCH_RC
  if [ -n "${TRUSTED_TARGET_SHA}" ]; then
    return 0
  fi
  # Credential origin only for the duration of this fetch, then restore the
  # unauthenticated URL immediately — mirroring pre-fix.src.sh's own
  # conflict-branch fetch. This call can run as early as the merge-commit
  # secret scan below (whenever a forge-conflict merge is in range), which
  # is before section 2/3 (precommit_install_deps / precommit_run_gate) run
  # repo-defined, PR-controlled pre-commit hooks and tool installers. Those
  # must never see a credentialed origin remote (readable via
  # `git remote get-url origin`). Restore failure is fatal, not
  # warn-and-continue: leaving the credentialed URL in place would expose it
  # to that untrusted code.
  _trusted_target_restore_url="$(git remote get-url origin 2>/dev/null || true)"
  forge_set_push_remote "${PUSH_TOKEN}"
  echo "Fetching target branch ${TARGET_BRANCH}..."
  if TARGET_FETCH_OUTPUT="$(git fetch origin "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}" 2>&1)"; then
    TARGET_FETCH_RC=0
  else
    TARGET_FETCH_RC=$?
  fi
  if [ -n "${_trusted_target_restore_url}" ]; then
    if ! git remote set-url origin "${_trusted_target_restore_url}"; then
      gha_echo error "Could not restore original origin URL after fetching target branch '${TARGET_BRANCH}' — refusing to continue with a credentialed origin URL exposed to pre-commit hooks and tool installers"
      exit 1
    fi
  fi
  # Redact PUSH_TOKEN from the fetch output before it can reach a log line
  # or a posted failure message: print_sanitized_gha_log only strips GHA
  # workflow-command syntax, not credential values, and forge_mask_token's
  # ::add-mask:: is a documented no-op on GitLab CI.
  TARGET_FETCH_OUTPUT="$(_redact_literal_token "${TARGET_FETCH_OUTPUT}" "${PUSH_TOKEN}")"
  if [ "${TARGET_FETCH_RC}" -ne 0 ]; then
    print_sanitized_gha_log "${TARGET_FETCH_OUTPUT}" stderr
    post_fail_to_pr setup-error \
      "Could not fetch target branch '${TARGET_BRANCH}': ${TARGET_FETCH_OUTPUT}"
  fi
  print_sanitized_gha_log "${TARGET_FETCH_OUTPUT}"
  TRUSTED_TARGET_SHA="$(git rev-parse "refs/remotes/origin/${TARGET_BRANCH}" 2>/dev/null)" || TRUSTED_TARGET_SHA=""
  if [ -z "${TRUSTED_TARGET_SHA}" ]; then
    post_fail_to_pr setup-error \
      "Could not resolve freshly fetched target branch '${TARGET_BRANCH}' to a commit SHA."
  fi
}

# Scope to the agent's commit(s) only — not the entire branch. PRE_AGENT_HEAD
# is set by fix.yml to the HEAD SHA before the harness runs, so this diff
# captures every commit the agent made (including validation_loop retries).
# Falls back to HEAD~1 if PRE_AGENT_HEAD is unset (shouldn't happen in CI).
DIFF_BASE="${PRE_AGENT_HEAD:-$(git rev-parse HEAD~1 2>/dev/null || echo HEAD)}"

# After a rebase, PRE_AGENT_HEAD is no longer an ancestor of HEAD — the rebase
# rewrote history so the old SHA is not in the current branch. Using it as
# DIFF_BASE causes SCAN_RANGE to include upstream commits (false positives for
# Signed-off-by and gitleaks). Detect this and fall back to merge-base, which
# isolates only the branch's own commits — the same approach used for
# BRANCH_CHANGED_FILES below and for SCAN_RANGE in post-code.src.sh.
if ! git merge-base --is-ancestor "${DIFF_BASE}" HEAD 2>/dev/null; then
  if [ "${NO_PUSH}" = "false" ]; then
    fetch_trusted_target_sha
  fi
  _rebase_mb="$(git merge-base HEAD "${TRUSTED_TARGET_SHA}" 2>/dev/null)" || _rebase_mb=""
  if [ -n "${_rebase_mb}" ]; then
    echo "PRE_AGENT_HEAD is not an ancestor of HEAD (history rewrite detected) — using merge-base for DIFF_BASE"
    DIFF_BASE="${_rebase_mb}"
  else
    post_fail_to_pr setup-error \
      "PRE_AGENT_HEAD is not an ancestor of HEAD and merge-base failed — cannot determine safe DIFF_BASE"
  fi
fi

CHANGED_FILES="$(git diff --name-only "${DIFF_BASE}..HEAD" 2>/dev/null || true)"

# A forge-conflict merge commit is a real, publishable change even when this
# two-dot name-only diff is empty: for a merge commit, DIFF_BASE (still an
# ancestor of HEAD) makes this a final-tree comparison, and an "ours"-style
# conflict resolution that keeps the PR's own content over every incoming
# target change produces a merge tree identical to the first parent — an
# empty diff despite a genuine, publishable merge. Only treat "no diff" as
# "nothing to push" when no merge commit is present in the range (see the
# medium-severity logic-error finding on PR #1520).
if [ -z "${CHANGED_FILES}" ] && [ "${NO_PUSH}" = "false" ] \
  && [ -z "$(git rev-list --merges "${DIFF_BASE}..HEAD" 2>/dev/null)" ]; then
  gha_echo warning "No changed files in agent's commit(s) — nothing to push"
  NO_PUSH=true
fi

# Compute the branch's net changes relative to the target branch using
# merge-base. After a rebase, PRE_AGENT_HEAD..HEAD includes upstream
# changes (the rebase rewrites history so the old SHA is no longer an
# ancestor). The merge-base diff isolates only what the branch itself
# contributes — the same diff that will appear in the PR.
# Fallback chain mirrors post-code.sh: warn, try origin/TARGET..HEAD,
# then HEAD~1..HEAD. This keeps the two post-scripts aligned.
MERGE_BASE="$(git merge-base "origin/${TARGET_BRANCH}" HEAD 2>/dev/null)" || MERGE_BASE=""
if [ -n "${MERGE_BASE}" ]; then
  BRANCH_CHANGED_FILES="$(git diff --name-only "${MERGE_BASE}..HEAD")"
else
  gha_echo warning "Could not determine merge-base — trying origin/${TARGET_BRANCH}..HEAD"
  BRANCH_CHANGED_FILES="$(git diff --name-only "origin/${TARGET_BRANCH}..HEAD" 2>/dev/null \
    || git diff --name-only HEAD~1..HEAD 2>/dev/null || true)"
fi

if [ "${NO_PUSH}" = "false" ]; then
  echo "Changed files (agent commits):"
  echo "${CHANGED_FILES}" | sed 's/^/  /'

  if [ "${BRANCH_CHANGED_FILES}" != "${CHANGED_FILES}" ]; then
    echo "Branch-only changed files (merge-base-aware, used for pre-commit):"
    echo "${BRANCH_CHANGED_FILES}" | sed 's/^/  /'
  fi
fi

# ---------------------------------------------------------------------------
# 1. Authoritative secret scan (only if pushing)
# ---------------------------------------------------------------------------
if [ "${NO_PUSH}" = "false" ]; then
  echo "Running authoritative secret scan on agent's commit..."

  if ! install_gitleaks; then
    post_fail_to_pr setup-error "Failed to install gitleaks v${GITLEAKS_VERSION}"
  fi

  SCAN_RANGE="${DIFF_BASE}..HEAD"

  # A forge-conflict merge (issue #1518) keeps DIFF_BASE an ancestor of HEAD,
  # so the rebase/squash merge-base fallback above never fires and the
  # two-dot SCAN_RANGE still walks the merge commit's second parent —
  # historical target-branch commits unrelated to this PR. Detect any merge
  # commit in range and scope the gitleaks scan to first-parent history
  # only, mirroring the isolation the rebase/squash path already gets.
  #
  # Collect the merge SHAs themselves with --first-parent too: a plain
  # two-dot `rev-list --merges` also walks the second-parent side and can
  # surface historical merges on the target branch that only became
  # reachable through this merge's second parent. Those are not agent-
  # introduced content and must not feed the per-merge scan below.
  GITLEAKS_LOG_OPTS="${SCAN_RANGE}"
  MERGE_COMMITS_IN_RANGE="$(git rev-list --first-parent --merges "${SCAN_RANGE}" 2>/dev/null || true)"
  if [ -n "${MERGE_COMMITS_IN_RANGE}" ]; then
    echo "Merge commit(s) found in ${SCAN_RANGE} — scoping secret scan to first-parent history"
    GITLEAKS_LOG_OPTS="--first-parent ${SCAN_RANGE}"
  fi

  if ! GITLEAKS_OUTPUT="$(gitleaks detect --source . --log-opts="${GITLEAKS_LOG_OPTS}" --redact 2>&1)"; then
    print_sanitized_gha_log "${GITLEAKS_OUTPUT}" stderr
    post_fail_to_pr secret-scan "${POST_FAILURE_SECRET_SCAN_MESSAGE}"
  fi

  # gitleaks drives `git log -p` under the hood without `-m`; it never emits
  # a patch for a commit with a "Merge:" header, even when --first-parent
  # forces git itself to print one (the diff against the merge's first
  # parent). Content that only exists because of the merge itself — i.e. the
  # forge-conflict resolution — is therefore invisible to the scan above.
  # Scan each merge's *combined* diff — `git show`'s default format for a
  # merge commit (equivalent to `--cc`), which includes only blobs that
  # differ from every parent — so only the actual conflict-resolution
  # content is checked. A pairwise `-m --first-parent` diff dumps the entire
  # incoming-target tree delta (every file the merge brought in, whether or
  # not it was touched by conflict resolution), including target-branch
  # content this PR never modified — a secret already on the target branch
  # would then false-fail this authoritative gate and block publishing a
  # legitimate conflict merge.
  #
  # `--cc` is only safe when EVERY non-first parent of the merge is actually
  # part of trusted target-branch history: combined-diff format omits any
  # path whose merge-result blob matches *any* parent, not just the one
  # checked. Checking only `^2` is incomplete for a merge with more than two
  # parents — a third (or later) parent that cleanly adds a file (no
  # conflict) would never appear in `--cc` output even though it was never
  # verified as trusted. MERGE_COMMITS_IN_RANGE is limited to the agent's
  # own first-parent merge(s), but nothing else guarantees every parent of a
  # given merge actually IS trusted target-branch history — a compromised
  # sandboxed agent could create a different (possibly octopus) merge during
  # the same session (e.g. of a throwaway branch carrying a planted secret)
  # and `--cc` would silently miss a cleanly-added file. Walk every non-first
  # parent (`^2`, `^3`, ... until `git rev-parse` fails) and require each one
  # to be an ancestor of TRUSTED_TARGET_SHA (fetched fresh, not the mutable
  # local ref) before trusting `--cc`; fall back to the full pairwise
  # first-parent diff whenever any extra parent is missing, unresolvable, or
  # not trusted-target history, since that diff captures everything the
  # merge brought in regardless of conflict status.
  # Materialize the diff to a file rather than piping `git show` straight
  # into `gitleaks --pipe`: with `set -o pipefail` (enabled at the top of
  # this script), a downstream reader that exits before draining stdin can
  # SIGPIPE the upstream `git show`, which would then fail the pipeline
  # regardless of what gitleaks itself reported.
  if [ -n "${MERGE_COMMITS_IN_RANGE}" ]; then
    fetch_trusted_target_sha
    MERGE_DIFF_TMP="$(mktemp)"
    _any_merge_used_cc=false
    while IFS= read -r _merge_sha; do
      [ -z "${_merge_sha}" ] && continue
      MERGE_SHOW_ARGS=(-m --first-parent)
      _merge_extra_parents_trusted=false
      _merge_parent_n=2
      while _merge_parent="$(git rev-parse "${_merge_sha}^${_merge_parent_n}" 2>/dev/null)" \
        && [ -n "${_merge_parent}" ]; do
        if ! git merge-base --is-ancestor "${_merge_parent}" "${TRUSTED_TARGET_SHA}" 2>/dev/null; then
          _merge_extra_parents_trusted=false
          break
        fi
        _merge_extra_parents_trusted=true
        _merge_parent_n=$((_merge_parent_n + 1))
      done
      if [ "${_merge_extra_parents_trusted}" = true ]; then
        MERGE_SHOW_ARGS=(--cc)
        _any_merge_used_cc=true
      fi
      if ! git show "${MERGE_SHOW_ARGS[@]}" "${_merge_sha}" > "${MERGE_DIFF_TMP}" 2>&1; then
        MERGE_SHOW_OUTPUT="$(cat "${MERGE_DIFF_TMP}")"
        rm -f "${MERGE_DIFF_TMP}"
        print_sanitized_gha_log "${MERGE_SHOW_OUTPUT}" stderr
        post_fail_to_pr setup-error "Could not read merge commit ${_merge_sha} for the authoritative secret scan"
      fi
      if ! MERGE_GITLEAKS_OUTPUT="$(gitleaks detect --pipe --redact < "${MERGE_DIFF_TMP}" 2>&1)"; then
        rm -f "${MERGE_DIFF_TMP}"
        print_sanitized_gha_log "${MERGE_GITLEAKS_OUTPUT}" stderr
        post_fail_to_pr secret-scan "${POST_FAILURE_SECRET_SCAN_MESSAGE}"
      fi
    done <<< "${MERGE_COMMITS_IN_RANGE}"
    # `--cc` omits any path whose merge-result blob matches *any* parent —
    # including an older-but-still-trusted target commit whose tree already
    # differs from the current TRUSTED_TARGET_SHA tip (e.g. a secret since
    # deleted from the tip). The ancestor check above only proves each extra
    # parent is *somewhere* in the target's history, not that its content
    # matches the current tip, so a resurrected blob can hide behind `--cc`.
    # Close that gap with a direct diff of the current tip against HEAD:
    # anything HEAD carries that the tip does not (including a resurrected
    # blob) shows up here regardless of which parent's content it matches.
    if [ "${_any_merge_used_cc}" = true ]; then
      echo "Combined-diff (--cc) used for at least one merge — additionally scanning content in HEAD not on the current target tip"
      if ! git diff "${TRUSTED_TARGET_SHA}" HEAD > "${MERGE_DIFF_TMP}" 2>&1; then
        MERGE_SHOW_OUTPUT="$(cat "${MERGE_DIFF_TMP}")"
        rm -f "${MERGE_DIFF_TMP}"
        print_sanitized_gha_log "${MERGE_SHOW_OUTPUT}" stderr
        post_fail_to_pr setup-error "Could not diff HEAD against the trusted target for the authoritative secret scan"
      fi
      if ! MERGE_GITLEAKS_OUTPUT="$(gitleaks detect --pipe --redact < "${MERGE_DIFF_TMP}" 2>&1)"; then
        rm -f "${MERGE_DIFF_TMP}"
        print_sanitized_gha_log "${MERGE_GITLEAKS_OUTPUT}" stderr
        post_fail_to_pr secret-scan "${POST_FAILURE_SECRET_SCAN_MESSAGE}"
      fi
    fi
    rm -f "${MERGE_DIFF_TMP}"
  fi
  echo "Secret scan passed — no leaks in agent's commit(s)"

  # -------------------------------------------------------------------------
  # 1b. Strip Signed-off-by trailers
  #
  # Agents must not sign off: DCO waives bot authors, and the bot noreply
  # address makes the trailer ~90 chars, failing gitlint body-max-line-length.
  # Strip it and continue; fail only if one survives the rewrite.
  # -------------------------------------------------------------------------
  echo "Checking for Signed-off-by trailers in agent's commit(s)..."
  # SCAN_RANGE widens to merge-base on the rebase path, so it can cover human
  # commits; the helpers scope count and rewrite to agent-authored ones.
  _signoff_count="$(signoff_count_range "${SCAN_RANGE}")"
  if [ "${_signoff_count}" -gt 0 ]; then
    gha_echo warning "Found Signed-off-by trailer(s) in ${_signoff_count} agent commit(s) — stripping"

    if ! SIGNOFF_STRIP_ERROR="$(signoff_strip_range "${SCAN_RANGE}" 2>&1 >/dev/null)"; then
      post_fail_to_pr signoff-rewrite-failed \
        "Failed to strip Signed-off-by trailer(s) from agent commit(s): ${SIGNOFF_STRIP_ERROR}"
    fi

    # Re-scan: fail only if a trailer survives a rewrite that reported success
    if signoff_present_in_range "${SCAN_RANGE}"; then
      post_fail_to_pr signed-off-by \
        "Signed-off-by trailer persists after rewrite attempt. Manual intervention required."
    fi
    SIGNOFF_STRIPPED=true
    SIGNOFF_STRIPPED_COUNT="${_signoff_count}"
    echo "Signed-off-by trailer(s) removed from ${_signoff_count} agent commit(s)"
  else
    echo "Signed-off-by scan passed — no trailers in agent's commit(s)"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Auto-install pre-commit tool dependencies
# ---------------------------------------------------------------------------
precommit_install_deps "${TARGET_BRANCH}"
export PATH="${HOME}/.local/bin:${PATH}"

# ---------------------------------------------------------------------------
# 3. Authoritative pre-commit check (only if pushing)
# ---------------------------------------------------------------------------
if [ "${NO_PUSH}" = "false" ]; then
  echo "Running authoritative pre-commit on agent's changed files..."

  changed_array=()
  while IFS= read -r _changed_line; do
    changed_array+=("${_changed_line}")
  done <<< "${BRANCH_CHANGED_FILES}"

  SCAN_RANGE="${DIFF_BASE}..HEAD"

  # Pass GITLEAKS_LOG_OPTS (computed in section 1, same SCAN_RANGE) rather
  # than the raw two-dot SCAN_RANGE: a forge-conflict merge (issue #1518)
  # keeps DIFF_BASE an ancestor of HEAD, so the autofix re-scan inside
  # precommit_run_gate would otherwise walk the merge's second parent and
  # can fail on historical target-branch secrets unrelated to this PR.
  precommit_run_gate changed_array "${GITLEAKS_LOG_OPTS}" "${TARGET_BRANCH}" "${MERGE_BASE}"

  if [ "${PRECOMMIT_GATE_SECRET_FAIL}" = "true" ]; then
    post_fail_to_pr secret-scan "${POST_FAILURE_SECRET_SCAN_MESSAGE}"
  fi
  if [ "${PRECOMMIT_GATE_SIGNOFF_FAIL}" = "true" ]; then
    post_fail_to_pr "${PRECOMMIT_GATE_CATEGORY}" "${PRECOMMIT_GATE_DETAIL}"
  fi
  if [ "${PRECOMMIT_GATE_RESULT}" = "fail" ]; then
    post_fail_to_pr "${PRECOMMIT_GATE_CATEGORY}" "${PRECOMMIT_GATE_DETAIL}"
  fi
fi

# Find agent-result.json — prefer the validated iteration when set.
# RUN_DIR is the original cwd (runDir = <outputBase>/<sandboxName>), saved
# before we cd'd into REPO_DIR. The agent writes its structured output to
# iteration-<N>/output/agent-result.json within runDir.
#
# Trust boundary: FULLSEND_VALIDATED_ITERATION_DIR is set by the fullsend CLI
# on the runner — not by the sandbox or the agent. No containment check
# (realpath / prefix guard) is applied here; the value is trusted from the
# external harness. If the trust model changes, add a realpath prefix check.
#
# Located here (before the push section) rather than down in "5. Process
# structured output" because the rebase-skip check below needs
# rebased_onto_target from this same file — see issue #565.
if [ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]; then
  if [ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json" ]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
  else
    gha_echo error "FULLSEND_VALIDATED_ITERATION_DIR is set but does not contain agent-result.json"
    exit 1
  fi
else
  # Backward compatibility: scan iteration-N/ subdirectories for the last
  # iteration's output (glob order = naturally ascending iteration numbers).
  RESULT_FILE=""
  for dir in "${RUN_DIR}"/iteration-*/output; do
    if [ -f "${dir}/agent-result.json" ]; then
      RESULT_FILE="${dir}/agent-result.json"
    fi
  done
fi

# Did this run's fix agent actually execute `git rebase origin/<target>` to
# completion (agents/fix.md's "How to rebase" step 4/5, human-requested only)?
# Read straight from agent-result.json rather than inferring from branch
# topology: a GitLab MR reconstruction produces the exact same ancestry
# (target branch reachable from HEAD, HEAD diverged from the real remote PR
# tip) whenever the target has moved past the commit the remote branch was
# built from — the ordinary "stale PR" case — with no rebase ever requested.
# jq failures (missing file, invalid JSON, field absent) all fall through to
# "false", the fail-closed default — see issue #565.
AGENT_REBASED_ONTO_TARGET=false
AGENT_HISTORY_REWRITTEN=false
AGENT_MERGED_TARGET=false
if [ -n "${RESULT_FILE}" ] && [ -f "${RESULT_FILE}" ]; then
  AGENT_REBASED_ONTO_TARGET="$(jq -r 'if .rebased_onto_target == true then "true" else "false" end' "${RESULT_FILE}" 2>/dev/null || echo false)"
  [ "${AGENT_REBASED_ONTO_TARGET}" = "true" ] || AGENT_REBASED_ONTO_TARGET=false
  AGENT_HISTORY_REWRITTEN="$(jq -r 'if .history_rewritten == true then "true" else "false" end' "${RESULT_FILE}" 2>/dev/null || echo false)"
  [ "${AGENT_HISTORY_REWRITTEN}" = "true" ] || AGENT_HISTORY_REWRITTEN=false
  AGENT_MERGED_TARGET="$(jq -r 'if .merged_target == true then "true" else "false" end' "${RESULT_FILE}" 2>/dev/null || echo false)"
  [ "${AGENT_MERGED_TARGET}" = "true" ] || AGENT_MERGED_TARGET=false
fi

# A non-bot TRIGGER_SOURCE only proves a human triggered *this run* — it
# says nothing about whether that run's /fs-fix instruction actually asked
# for a rebase. Any other human instruction (or a bot/no-instruction run)
# must not be able to authorize the origin/BRANCH rebase skip below, even
# if rebased_onto_target:true was set (by a confused agent or prompt
# injection) — see the medium-severity auth-bypass finding on PR #1296.
# HUMAN_INSTRUCTION is set by the triggering workflow from the literal PR/MR
# comment before the sandbox exists, so — unlike agent-result.json — the
# sandboxed fix agent cannot influence it during its own run.
HUMAN_REBASE_REQUESTED=false
if ! is_bot_user "${TRIGGER_SOURCE}" && is_human_rebase_request "${HUMAN_INSTRUCTION:-}"; then
  HUMAN_REBASE_REQUESTED=true
fi

# Runner-side forge conflict query (issue #1518). agent-result.json is
# sandbox-written; the skip below must not trust merged_target /
# rebased_onto_target from a bot-triggered run unless this independently
# verified signal is true. Approval/check gating, a stale branch, and
# unknown API responses are not conflicts.
FIX_CONFLICT_STRATEGY="$(fix_conflict_update_strategy)"
FORGE_PR_HAS_CONFLICT=false
FORGE_PR_MERGE_STATE="$(forge_get_pr_merge_state "${PR_NUMBER}" 2>/dev/null || echo unknown)"
if forge_pr_has_merge_conflict "${PR_NUMBER}"; then
  FORGE_PR_HAS_CONFLICT=true
fi
echo "Forge mergeability: state=${FORGE_PR_MERGE_STATE} conflict=${FORGE_PR_HAS_CONFLICT} strategy=${FIX_CONFLICT_STRATEGY}"

# Same trust boundary for squash/redo: history_rewritten in agent-result.json
# is sandbox-written. Only a harness-captured human squash or redo instruction
# may authorize skipping replay onto origin/BRANCH (issue #1332).
HUMAN_HISTORY_REWRITE_REQUESTED=false
if ! is_bot_user "${TRIGGER_SOURCE}" && is_human_history_rewrite_request "${HUMAN_INSTRUCTION:-}"; then
  HUMAN_HISTORY_REWRITE_REQUESTED=true
fi

# Squash and redo/reset verify differently below (agents/fix.md "Rewrite
# fix-agent history"): a squash now targets the whole PR and must land as a
# single commit, so per-commit preservation no longer applies to it, while
# redo/reset still only discards the contiguous fix-agent suffix and must
# still preserve every commit below it. Compute both independently — never
# both true at once from a real single-phrase instruction, but an agent that
# misreads an ambiguous combined request as history_rewritten:true must still
# fall through to the stricter (preservation) path below, not the looser one.
HUMAN_SQUASH_REQUESTED=false
HUMAN_RESET_REQUESTED=false
if ! is_bot_user "${TRIGGER_SOURCE}"; then
  if is_human_squash_request "${HUMAN_INSTRUCTION:-}"; then
    HUMAN_SQUASH_REQUESTED=true
  fi
  if is_human_reset_request "${HUMAN_INSTRUCTION:-}"; then
    HUMAN_RESET_REQUESTED=true
  fi
fi

# The fix agent's own git identity (harness/fix.yaml sets GIT_AUTHOR_NAME to
# this literal for the sandbox). GIT_BOT_EMAIL alone is not sufficient to
# identify fix-agent commits: harness/code.yaml gives the code agent the
# same ${GIT_BOT_EMAIL}, differing only by name (fullsend-code). This
# script runs on the runner, which does not inherit the sandbox's
# GIT_AUTHOR_NAME, so the fix-agent identity is hardcoded here rather than
# read from the environment.
FIX_AGENT_GIT_NAME="fullsend-fix"

# history_rewrite_preserves_remote_human_commits — 0 when every commit on
# origin/BRANCH since it diverged from origin/TARGET_BRANCH that is NOT
# authored by this fix agent (email + name, not email alone — see
# FIX_AGENT_GIT_NAME above) is still present in local HEAD, either as an
# exact-SHA ancestor, or as an equivalent commit recognized by one of two
# fallbacks:
#   - same tree + same author identity — tolerates GitLab MR reconstruction,
#     where local history is rebuilt from API content and gets different
#     commit SHAs even when the tree/author content is identical.
#   - same author identity + same patch-id — tolerates a genuine rebase,
#     which reapplies the commit's patch onto a new base tree. The
#     resulting commit's full tree then differs from the original whenever
#     the new base touched other files, even though the author's own change
#     was preserved intact; patch-id (the diff the commit introduces) is
#     the quantity a rebase actually preserves, unlike the full tree.
# Fail closed when the agent identity is unknown (cannot tell humans/code-
# agent from this fix agent) or when a non-fix-agent commit would be lost
# by publishing the rewrite.
#
# Sets the global HISTORY_REWRITE_PATCH_ID_ONLY_MATCH to "true" when at
# least one remote commit was only recognized via the patch-id fallback
# (never as an exact-SHA ancestor nor via the same-tree fallback). The
# patch-id fallback alone is consistent with a genuine rebase having
# happened, not merely a reconstruction or merge — callers that trust this
# function to authorize a *merge*-only skip must additionally require
# explicit rebase authorization (FIX_CONFLICT_STRATEGY=rebase or
# HUMAN_REBASE_REQUESTED) whenever this flag is "true", or a rebase could
# be disguised as a merge (see the auth-bypass class of finding on PR
# #1296, and the merged_target GitLab-reconstruction fallback below).
history_rewrite_preserves_remote_human_commits() {
  local bot remote_ref target_ref mb sha author_email author_name tree patch_id candidate candidate_name candidate_email candidate_patch_id candidate_tree
  HISTORY_REWRITE_PATCH_ID_ONLY_MATCH=false
  bot="$(signoff_bot_email)"
  if [ -z "${bot}" ]; then
    echo "history-rewrite: agent git identity unavailable; refusing to publish rewrite" >&2
    return 1
  fi
  remote_ref="origin/${BRANCH}"
  target_ref="origin/${TARGET_BRANCH}"
  mb="$(git merge-base "${target_ref}" "${remote_ref}" 2>/dev/null)" || {
    echo "history-rewrite: could not compute merge-base of ${target_ref} and ${remote_ref}" >&2
    return 1
  }
  for sha in $(git rev-list "${mb}..${remote_ref}" 2>/dev/null || true); do
    author_email="$(git log -1 --format='%ae' "${sha}" 2>/dev/null)"
    author_name="$(git log -1 --format='%an' "${sha}" 2>/dev/null)"
    if [ "${author_email}" != "${bot}" ] || [ "${author_name}" != "${FIX_AGENT_GIT_NAME}" ]; then
      if git merge-base --is-ancestor "${sha}" HEAD 2>/dev/null; then
        continue
      fi
      tree="$(git log -1 --format='%T' "${sha}" 2>/dev/null)"
      if [ -n "${tree}" ]; then
        # Candidates are restricted to the range being published
        # (target_ref..HEAD), not all of HEAD's ancestry — same rationale
        # as the patch-id loop below: HEAD also contains target-branch
        # history up to the fork point (the caller requires that fork
        # point to be an ancestor of HEAD), and a same-tree-and-author
        # commit already inherited from the target branch proves nothing
        # about whether this PR's own commit survived the rewrite.
        # Matching is done with exact field equality rather than
        # `grep -qF` against a bare "tree name email" string, which is an
        # unanchored substring match.
        while IFS=$'\t' read -r candidate_tree candidate_name candidate_email; do
          [ -n "${candidate_tree}" ] || continue
          [ "${candidate_tree}" = "${tree}" ] || continue
          [ "${candidate_name}" = "${author_name}" ] || continue
          [ "${candidate_email}" = "${author_email}" ] || continue
          continue 2
        done < <(git log --format='%T%x09%an%x09%ae' "${target_ref}..HEAD" 2>/dev/null)
      fi
      patch_id="$(git show "${sha}" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')"
      if [ -n "${patch_id}" ]; then
        # Candidates are restricted to the range being published
        # (target_ref..HEAD), not all of HEAD's ancestry: HEAD also
        # contains target-branch history up to the fork point (the
        # caller requires that fork point to be an ancestor of HEAD),
        # and a same-author commit already inherited from the target
        # branch proves nothing about whether this PR's own commit
        # survived the rewrite. Matching is done with exact string
        # equality on %an/%ae rather than `git log --author=`, which
        # treats the name as an unanchored regex.
        while IFS=$'\t' read -r candidate candidate_name candidate_email; do
          [ -n "${candidate}" ] || continue
          [ "${candidate_name}" = "${author_name}" ] || continue
          [ "${candidate_email}" = "${author_email}" ] || continue
          candidate_patch_id="$(git show "${candidate}" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')"
          if [ -n "${candidate_patch_id}" ] && [ "${candidate_patch_id}" = "${patch_id}" ]; then
            HISTORY_REWRITE_PATCH_ID_ONLY_MATCH=true
            continue 2
          fi
        done < <(git log --format='%H%x09%an%x09%ae' "${target_ref}..HEAD" 2>/dev/null)
      fi
      echo "history-rewrite: commit ${sha} (author ${author_name} <${author_email}>) on ${remote_ref} is not an ancestor of HEAD and has no equivalent (tree+author or patch-id+author) commit in HEAD" >&2
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# 4. Push branch (only if we have commits)
# ---------------------------------------------------------------------------
if [ "${NO_PUSH}" = "false" ]; then
  forge_set_push_remote "${PUSH_TOKEN}"

  # Ensure local branch is up-to-date with the remote. On GitLab, the
  # sandbox cannot git-fetch the source branch, so the agent reconstructs
  # it from API content — the resulting commit history diverges from the
  # remote. Fetching and rebasing here makes the push a fast-forward.
  # Fetching also gives --force-with-lease a valid remote-tracking baseline
  # (without it the lease has stale/empty info and is rejected).
  # On GitHub this is a no-op when history already matches.
  #
  # The + refspec force-updates the tracking ref: a reconstructed local
  # origin/<branch> is not an ancestor of the real remote tip, so a
  # non-forced fetch of the tracking ref would fail.
  echo "Fetching remote branch ${BRANCH} before push..."
  FETCH_OUTPUT="$(git fetch origin "+refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}" 2>&1)" && FETCH_RC=0 || FETCH_RC=$?
  if [ "${FETCH_RC}" -eq 0 ]; then
    print_sanitized_gha_log "${FETCH_OUTPUT}"
    # If the agent already rebased onto the PR target (issue #565), replaying
    # local commits onto the stale remote PR tip would undo that rebase.
    # Require the agent's own record of having run the rebase
    # (AGENT_REBASED_ONTO_TARGET, computed above from agent-result.json) —
    # ancestry alone cannot be trusted here; a GitLab MR reconstruction built
    # against a target that has since moved on produces this same topology
    # (HEAD based on origin/TARGET_BRANCH, diverged from origin/BRANCH, target
    # ahead of the remote PR tip) with no rebase ever requested. The ancestry
    # checks stay as a secondary guard: GitLab reconstruction of an
    # up-to-date PR does not match (target is still an ancestor of
    # origin/BRANCH), so issue #1228 is unchanged.
    #
    # AGENT_REBASED_ONTO_TARGET alone is not sufficient: agent-result.json is
    # written inside the sandbox, which is influenceable by prompt injection
    # in PR/issue text or a confused agent. agents/fix.md only prompt-instructs
    # the agent never to set this field on a bot-triggered run — that is not
    # an enforced control. HUMAN_REBASE_REQUESTED (computed above), by
    # contrast, is derived from TRIGGER_SOURCE and HUMAN_INSTRUCTION — both
    # harness-set env vars the sandbox does not control — and is true only
    # when a human's own /fs-fix text actually asked for a rebase. A merely
    # non-bot trigger is not enough: an unrelated human /fs-fix instruction
    # must not authorize this skip (see "Rebase onto the target branch" in
    # agents/fix.md).
    SKIP_REMOTE_REBASE=false
    if [ "${AGENT_REBASED_ONTO_TARGET}" = "true" ] \
      && [ "${HUMAN_REBASE_REQUESTED}" = "true" ] \
      && git rev-parse --verify "origin/${TARGET_BRANCH}" >/dev/null 2>&1 \
      && git merge-base --is-ancestor "origin/${TARGET_BRANCH}" HEAD 2>/dev/null \
      && ! git merge-base --is-ancestor "origin/${BRANCH}" HEAD 2>/dev/null \
      && ! git merge-base --is-ancestor "origin/${TARGET_BRANCH}" "origin/${BRANCH}" 2>/dev/null; then
      SKIP_REMOTE_REBASE=true
      echo "Local HEAD is already based on origin/${TARGET_BRANCH} and has diverged from origin/${BRANCH} (target is ahead of the remote PR tip) — skipping rebase onto origin/${BRANCH} to preserve the agent rebase onto the target"
    fi
    # Forge-reported conflict (issue #1518). Bot-triggered runs are not
    # human rebase requests, so HUMAN_REBASE_REQUESTED cannot authorize the
    # rebase branch below on its own — it only widens that branch's
    # strategy gate to a human-requested override. The runner re-queries
    # the forge independently of the sandbox-written merged_target /
    # rebased_onto_target flags; ancestry still has to show that HEAD
    # already contains the target. Replaying onto origin/BRANCH would
    # re-hit the conflict the agent just resolved (a merge commit is
    # dropped by a default git rebase; a rebase onto the target is undone
    # by replaying onto the stale PR tip).
    if [ "${SKIP_REMOTE_REBASE}" = "false" ] && [ "${FORGE_PR_HAS_CONFLICT}" = "true" ]; then
      if [ "${AGENT_MERGED_TARGET}" = "true" ] || [ "${AGENT_REBASED_ONTO_TARGET}" = "true" ]; then
        fetch_trusted_target_sha
        if [ -n "${TRUSTED_TARGET_SHA}" ]; then
          # Do not require TRUSTED_TARGET_SHA (the *current* target tip,
          # force-fetched fresh above) to be an ancestor of HEAD. The agent
          # merged/rebased onto whatever the target tip was when it ran
          # (fetched by pre-fix.src.sh); if the target fast-forwarded again
          # during the sandbox's run (up to timeout_minutes), this fetch
          # observes a newer tip HEAD never saw. Requiring that newer tip in
          # HEAD would bounce a legitimate merge/rebase into the default
          # rebase below, which drops the merge commit / undoes the rebase.
          # Each arm below instead verifies HEAD's own merge/rebase is still
          # on the current target's line, which tolerates the target moving
          # further ahead in the meantime.
          #
          # merged_target: some first-parent merge introduced since the real
          # remote PR tip (origin/${BRANCH}, freshly fetched above — not
          # MERGE_COMMITS_IN_RANGE from section 1, which is scoped to
          # DIFF_BASE..HEAD and, when PRE_AGENT_HEAD is unset, falls back to
          # HEAD~1 and can exclude the agent's own merge commit entirely) has
          # a second parent that is an ancestor of the current
          # TRUSTED_TARGET_SHA — the merged content is still on the target's
          # line, even if the target has since advanced further.
          MERGE_TARGET_ANCESTOR_OK=false
          if [ "${AGENT_MERGED_TARGET}" = "true" ]; then
            _merged_target_merges="$(git rev-list --first-parent --merges "origin/${BRANCH}..HEAD" 2>/dev/null || true)"
            while IFS= read -r _pfm_sha; do
              [ -z "${_pfm_sha}" ] && continue
              _pfm_parent2="$(git rev-parse "${_pfm_sha}^2" 2>/dev/null)" || continue
              [ -n "${_pfm_parent2}" ] || continue
              if git merge-base --is-ancestor "${_pfm_parent2}" "${TRUSTED_TARGET_SHA}" 2>/dev/null; then
                MERGE_TARGET_ANCESTOR_OK=true
                break
              fi
            done <<< "${_merged_target_merges}"
          fi
          # rebased_onto_target: HEAD and the current target tip must share
          # real history at all (fails closed only when the two histories
          # are actually unrelated — a resolvable merge-base is always an
          # ancestor of HEAD).
          REBASE_TARGET_ANCESTOR_OK=false
          if [ "${AGENT_REBASED_ONTO_TARGET}" = "true" ]; then
            _rebase_target_mb="$(git merge-base HEAD "${TRUSTED_TARGET_SHA}" 2>/dev/null)" || _rebase_target_mb=""
            if [ -n "${_rebase_target_mb}" ] \
              && git merge-base --is-ancestor "${_rebase_target_mb}" HEAD 2>/dev/null; then
              REBASE_TARGET_ANCESTOR_OK=true
            fi
          fi
          # merged_target: also require the real remote PR tip
          # (origin/${BRANCH}, freshly fetched above) to be an ancestor of
          # HEAD. Containing the target SHA alone is not enough — a GitLab
          # reconstruction can start from the target branch and trivially
          # satisfy that check without ever containing the real remote
          # commits, which the force-push fallback would then drop.
          if [ "${AGENT_MERGED_TARGET}" = "true" ] \
            && [ "${MERGE_TARGET_ANCESTOR_OK}" = "true" ] \
            && git merge-base --is-ancestor "origin/${BRANCH}" HEAD 2>/dev/null; then
            SKIP_REMOTE_REBASE=true
            echo "Local HEAD already contains origin/${TARGET_BRANCH} via a forge-conflict merge — skipping rebase onto origin/${BRANCH} to preserve the merge commit"
          # rebased_onto_target: only trust the sandbox-written flag when
          # the runner-computed strategy actually authorizes a rebase, or a
          # human's own /fs-fix text explicitly asked for one. Without this,
          # a bot-triggered run (or an unrelated human /fs-fix instruction)
          # could force-push over the remote PR tip via this flag even
          # though the configured strategy is the conservative "merge"
          # default (see the auth-bypass class of finding on PR #1296).
          #
          # REBASE_TARGET_ANCESTOR_OK alone is not sufficient: for related
          # histories merge-base(HEAD, TRUSTED_TARGET_SHA) is always an
          # ancestor of HEAD (it only fails for genuinely unrelated
          # histories, per its own comment above), so it proves HEAD shares
          # history with the target, not that HEAD still contains the PR's
          # own commits from origin/${BRANCH}. A sandbox that reset HEAD onto
          # the bare target tip plus a tree-changing follow-up commit would
          # satisfy every check above (and the empty-CHANGED_FILES guard
          # only blocks a bare reset with no follow-up commit) while
          # dropping every PR commit. Require
          # history_rewrite_preserves_remote_human_commits, fail closed, the
          # same content-preservation guarantee the GitLab merged_target
          # fallback and the squash/redo publish gate already require (see
          # the high-severity auth-bypass finding on PR #1520).
          elif [ "${AGENT_REBASED_ONTO_TARGET}" = "true" ] \
            && [ "${REBASE_TARGET_ANCESTOR_OK}" = "true" ] \
            && { [ "${FIX_CONFLICT_STRATEGY}" = "rebase" ] || [ "${HUMAN_REBASE_REQUESTED}" = "true" ]; } \
            && ! git merge-base --is-ancestor "origin/${BRANCH}" HEAD 2>/dev/null \
            && ! git merge-base --is-ancestor "${TRUSTED_TARGET_SHA}" "origin/${BRANCH}" 2>/dev/null \
            && history_rewrite_preserves_remote_human_commits; then
            SKIP_REMOTE_REBASE=true
            echo "Local HEAD is already based on origin/${TARGET_BRANCH} after a forge-conflict rebase — skipping rebase onto origin/${BRANCH} to preserve the agent rebase onto the target"
          # merged_target / GitLab reconstruction fallback: on GitLab the
          # sandbox cannot git-fetch the real source branch, so it
          # reconstructs BRANCH from API content and the resulting merge
          # commit's ancestry never lines up with origin/${BRANCH}'s real
          # SHAs, even though the content is equivalent — the ancestor
          # check above (line 690) can never pass for a genuine GitLab
          # conflict-merge. A default `git rebase origin/${BRANCH}` below
          # would then silently drop the merge commit and the conflict
          # resolution it carries. Detect the reconstruction case without
          # relying on SHA ancestry into HEAD: PRE_AGENT_HEAD is set by the
          # runner before the sandbox ever ran (harness/fix.yaml), so it is
          # not sandbox-influenceable. If origin/${BRANCH} (the real,
          # freshly-fetched remote tip) is unchanged since PRE_AGENT_HEAD,
          # nobody pushed anything new to the remote branch during this
          # run. That alone only proves the remote tip did not move — it
          # does NOT prove HEAD's reconstruction actually contains what
          # origin/${BRANCH} has (the same target-SHA-in-HEAD gap the
          # merged_target ancestry check above exists to close): a
          # reconstruction that starts from the target, or an API replay
          # that omits PR-unique commits, would satisfy every check above
          # without ever containing the real remote commits. Require the
          # same content-preservation guarantee the squash/redo publish
          # gate relies on before trusting this fallback; fall through to
          # the default rebase when it fails.
          #
          # This fallback exists only for GitLab's reconstructed-history
          # model (its justification above is entirely GitLab-specific); a
          # genuine GitHub merge already satisfies the ancestor-based arm
          # earlier in this if-chain. Gate on FULLSEND_FORGE=gitlab so a
          # GitHub run cannot reach it.
          #
          # history_rewrite_preserves_remote_human_commits alone is not
          # sufficient here: it also tolerates a genuine rebase via its
          # same-author-identity + same-patch-id fallback (documented at
          # its definition above), which is the exact operation the
          # sibling rebased_onto_target arm two cases above gates behind
          # an explicit FIX_CONFLICT_STRATEGY=rebase ||
          # HUMAN_REBASE_REQUESTED check. Without an equivalent gate here,
          # a confused or compromised sandboxed agent could actually
          # rebase onto the target instead of merging, falsely report
          # merged_target: true, and still satisfy this fallback via the
          # patch-id path — reaching SKIP_REMOTE_REBASE=true (and the
          # force-with-lease push path) under the default merge strategy
          # with no rebase authorization. Require explicit rebase
          # authorization whenever HISTORY_REWRITE_PATCH_ID_ONLY_MATCH
          # (set by the helper) shows the patch-id fallback — not the
          # tree fallback, which is what a genuine reconstruction/merge
          # actually produces — was needed to preserve a remote commit.
          #
          # history_rewrite_preserves_remote_human_commits only proves
          # origin/${BRANCH}'s own pre-existing human commits survive in
          # HEAD — it says nothing about whether TRUSTED_TARGET_SHA's
          # content was ever actually merged in. A reconstruction that
          # faithfully recreates the original PR branch without
          # incorporating the target at all can satisfy every conjunct
          # above (nobody pushed to the remote, the reconstruction's own
          # commits are preserved) while leaving the conflict unresolved on
          # the remote. Require MERGE_TARGET_ANCESTOR_OK (computed above,
          # same as the merged_target ancestor-based arm two cases up) so a
          # real merge commit whose second parent lands on the trusted
          # target's line must be present — see the medium-severity
          # logic-error finding on PR #1520.
          elif [ "${AGENT_MERGED_TARGET}" = "true" ] \
            && [ "${MERGE_TARGET_ANCESTOR_OK}" = "true" ] \
            && [ "${FULLSEND_FORGE}" = "gitlab" ] \
            && [ "${FIX_CONFLICT_STRATEGY}" = "merge" ] \
            && [ -n "${PRE_AGENT_HEAD:-}" ] \
            && [ "$(git rev-parse "origin/${BRANCH}" 2>/dev/null)" = "${PRE_AGENT_HEAD}" ] \
            && ! git merge-base --is-ancestor "${TRUSTED_TARGET_SHA}" "origin/${BRANCH}" 2>/dev/null \
            && history_rewrite_preserves_remote_human_commits \
            && { [ "${HISTORY_REWRITE_PATCH_ID_ONLY_MATCH}" = "false" ] || [ "${HUMAN_REBASE_REQUESTED}" = "true" ]; }; then
            SKIP_REMOTE_REBASE=true
            echo "origin/${BRANCH} has not advanced past PRE_AGENT_HEAD (GitLab reconstruction detected) and HEAD preserves origin/${BRANCH}'s content — skipping rebase onto origin/${BRANCH} to preserve the forge-conflict merge"
          fi
        fi
      fi
    fi
    # Squash/redo (issue #1332): the agent rewrote the contiguous fix-agent
    # suffix, so origin/BRANCH is no longer an ancestor of HEAD. Replaying
    # onto the pre-rewrite remote tip would restore the discarded commits.
    # Unlike the rebase skip above, this is valid even when the target has
    # not moved — a squash of an up-to-date PR still diverges. Fail closed
    # if a human-authored commit on the remote PR would be lost.
    #
    # Unlike the rebase skip's origin/TARGET_BRANCH-is-ancestor-of-HEAD
    # requirement, a squash/redo does not rebase onto the target — it only
    # rewrites the fix-agent suffix in place on top of the PR's original
    # fork point. Requiring the (possibly since-advanced) TARGET_BRANCH to
    # be an ancestor of HEAD would wrongly fail here whenever the target
    # has moved on, falling through to a rebase onto the stale remote tip
    # and silently undoing the requested rewrite. Use the PR's recorded
    # fork point instead — the merge-base of the two remote refs, which is
    # unaffected both by the local rewrite and by TARGET_BRANCH's later
    # advancement.
    #
    # This block is NOT gated on SKIP_REMOTE_REBASE = false: when a human
    # asks for a rebase and a squash together, the rebase-skip block above
    # can already have set SKIP_REMOTE_REBASE = true (its ancestry
    # requirement — target has advanced past the remote PR tip — is the
    # ordinary reason a human asks for a rebase in the first place). Gating
    # this block on SKIP_REMOTE_REBASE = false would skip
    # history_rewrite_preserves_remote_human_commits entirely on that
    # combined path, force-pushing a squash/redo with no preservation check
    # at all (high-severity finding on PR #1335). The preservation check
    # must run — and be able to refuse publication — whenever the agent
    # recorded a history rewrite and a human asked for one, regardless of
    # what the rebase-skip block already decided.
    fetch_trusted_target_sha
    REWRITE_FORK_POINT="$(git merge-base "${TRUSTED_TARGET_SHA}" "origin/${BRANCH}" 2>/dev/null)" || REWRITE_FORK_POINT=""
    if [ "${AGENT_HISTORY_REWRITTEN}" = "true" ] \
      && [ "${HUMAN_HISTORY_REWRITE_REQUESTED}" = "true" ] \
      && [ -n "${REWRITE_FORK_POINT}" ] \
      && git merge-base --is-ancestor "${REWRITE_FORK_POINT}" HEAD 2>/dev/null \
      && ! git merge-base --is-ancestor "origin/${BRANCH}" HEAD 2>/dev/null; then
      # This topology alone (diverged from origin/BRANCH, still contains
      # the fork point) is also what a GitLab MR reconstruction produces
      # with no rewrite at all — reconstructed commits get new SHAs even
      # when nothing actually changed. Copying the rebase skip's "target
      # moved past the remote tip" check would reject legitimate
      # up-to-date squashes, so require a rewrite-specific structural
      # signal instead: either the rewritten range has fewer commits than
      # the remote range (a squash) or HEAD's final tree differs from
      # origin/BRANCH's (a redo). If neither holds, local HEAD is
      # structurally indistinguishable from a reconstruction of
      # origin/BRANCH — nothing was actually rewritten, so there is
      # nothing to verify or skip on this path.
      REWRITE_LOCAL_COUNT="$(git rev-list --count "${REWRITE_FORK_POINT}..HEAD" 2>/dev/null)" || REWRITE_LOCAL_COUNT="0"
      REWRITE_REMOTE_COUNT="$(git rev-list --count "${REWRITE_FORK_POINT}..origin/${BRANCH}" 2>/dev/null)" || REWRITE_REMOTE_COUNT="0"
      REWRITE_LOCAL_TREE="$(git rev-parse "HEAD^{tree}" 2>/dev/null)" || REWRITE_LOCAL_TREE=""
      REWRITE_REMOTE_TREE="$(git rev-parse "origin/${BRANCH}^{tree}" 2>/dev/null)" || REWRITE_REMOTE_TREE=""
      if [ "${REWRITE_LOCAL_COUNT}" -lt "${REWRITE_REMOTE_COUNT}" ] \
        || [ "${REWRITE_LOCAL_TREE}" != "${REWRITE_REMOTE_TREE}" ]; then
        # A genuine rewrite is on HEAD. What "safe" means depends on which
        # rewrite was requested:
        #
        #   - Squash (and not also reset — an ambiguous combined phrase
        #     falls through to the stricter redo/reset check below) now
        #     targets the whole PR: fix-agent, code-agent, and human commits
        #     alike are intentionally combined into one commit (agents/fix.md
        #     "Rewrite fix-agent history" — "the end result should be a
        #     single-commit PR"). Per-commit preservation is structurally
        #     impossible to satisfy for a real squash of more than one
        #     commit, so it is not the right safety property here. The
        #     property that matters is that the promised outcome actually
        #     happened: exactly one commit sits between the target branch
        #     and HEAD. This also bounds what a "manual squash" (reset to
        #     the merge base and hand-reimplement, used when squash+rebase
        #     conflicts make a mechanical `git reset --soft` impractical)
        #     could smuggle in: whatever it is, it is confined to the one
        #     commit that already passed the secret scan and pre-commit
        #     gate above.
        #   - Redo/reset only discards the contiguous fix-agent suffix, so
        #     every non-fix-agent commit below it must still be preserved
        #     intact — same check as before.
        # Refuse to publish on failure regardless — even if the rebase-skip
        # above already authorized skipping replay for an unrelated reason
        # (target-advance rebase).
        if [ "${HUMAN_SQUASH_REQUESTED}" = "true" ] && [ "${HUMAN_RESET_REQUESTED}" = "false" ]; then
          REWRITE_TARGET_COUNT="$(git rev-list --count "${TRUSTED_TARGET_SHA}..HEAD" 2>/dev/null)" || REWRITE_TARGET_COUNT="-1"
          if [ "${REWRITE_TARGET_COUNT}" = "1" ]; then
            if [ "${SKIP_REMOTE_REBASE}" = "false" ]; then
              SKIP_REMOTE_REBASE=true
              echo "Local HEAD has rewritten authorized agent history and has diverged from origin/${BRANCH} — skipping rebase onto origin/${BRANCH} to preserve the agent history rewrite"
            fi
          else
            post_fail_to_pr push-rejected \
              "Refusing to publish squash: a human /fs-fix squash request must produce exactly one commit ahead of origin/${TARGET_BRANCH} (the whole PR as a single commit), but found ${REWRITE_TARGET_COUNT}."
          fi
        elif history_rewrite_preserves_remote_human_commits; then
          if [ "${SKIP_REMOTE_REBASE}" = "false" ]; then
            SKIP_REMOTE_REBASE=true
            echo "Local HEAD has rewritten authorized agent history and has diverged from origin/${BRANCH} — skipping rebase onto origin/${BRANCH} to preserve the agent history rewrite"
          fi
        else
          post_fail_to_pr push-rejected \
            "Refusing to publish history rewrite: a human-authored commit on origin/${BRANCH} is not an ancestor of local HEAD, or the agent git identity is unavailable. The authorized range is the contiguous fix-agent suffix at HEAD; human-authored commits must be preserved."
        fi
      elif [ "${SKIP_REMOTE_REBASE}" = "false" ]; then
        echo "history_rewritten is set but local HEAD is structurally indistinguishable from origin/${BRANCH} (same commit count and tree) — treating as a GitLab reconstruction rather than a genuine rewrite, and falling through to rebase onto origin/${BRANCH}"
      fi
    fi
    if [ "${SKIP_REMOTE_REBASE}" = "false" ]; then
      echo "Rebasing local ${BRANCH} onto origin/${BRANCH}..."
      REBASE_OUTPUT="$(git rebase "origin/${BRANCH}" 2>&1)" && REBASE_RC=0 || REBASE_RC=$?
      if [ "${REBASE_RC}" -ne 0 ]; then
        print_sanitized_gha_log "${REBASE_OUTPUT}"
        git rebase --abort 2>/dev/null || true
        post_fail_to_pr push-rejected \
          "Could not rebase local '${BRANCH}' onto origin/${BRANCH}: the remote branch has commits that conflict with the agent's changes. Resolve the conflict on the PR/MR and re-run /fs-fix.
${REBASE_OUTPUT}"
      fi
      print_sanitized_gha_log "${REBASE_OUTPUT}"
    fi
  elif echo "${FETCH_OUTPUT}" | grep -qi "couldn't find remote ref"; then
    echo "Remote branch ${BRANCH} not found — skipping rebase"
    print_sanitized_gha_log "${FETCH_OUTPUT}"
  else
    print_sanitized_gha_log "${FETCH_OUTPUT}"
    post_fail_to_pr push-rejected \
      "Could not fetch remote branch '${BRANCH}' before rebase: ${FETCH_OUTPUT}"
  fi

  # Plain push first. Falls back to --force-with-lease when the push
  # is rejected (non-fast-forward), which happens after a rebase, squash,
  # or reset — the agent rewrote history so the remote branch diverged.
  # force-with-lease is safe: it still rejects if someone else pushed in
  # the meantime.
  echo "Pushing branch ${BRANCH}..."
  PUSH_OUTPUT="$(git push -u origin -- "${BRANCH}" 2>&1)" && PUSH_RC=0 || PUSH_RC=$?
  print_sanitized_gha_log "${PUSH_OUTPUT}"

  if [ "${PUSH_RC}" -ne 0 ]; then
    if echo "${PUSH_OUTPUT}" | grep -qi "non-fast-forward\|rejected\|fetch first"; then
      gha_echo warning "Plain push failed (non-fast-forward) — retrying with --force-with-lease"
      FORCE_PUSH_OUTPUT=""
      if ! FORCE_PUSH_OUTPUT="$(git push --force-with-lease -u origin -- "${BRANCH}" 2>&1)"; then
        print_sanitized_gha_log "${FORCE_PUSH_OUTPUT}"
        PUSH_CATEGORY="$(categorize_push_failure "${PUSH_OUTPUT}
${FORCE_PUSH_OUTPUT}")"
        post_fail_to_pr "${PUSH_CATEGORY}" "${PUSH_OUTPUT}
${FORCE_PUSH_OUTPUT}"
      fi
      print_sanitized_gha_log "${FORCE_PUSH_OUTPUT}"
    else
      PUSH_CATEGORY="$(categorize_push_failure "${PUSH_OUTPUT}")"
      post_fail_to_pr "${PUSH_CATEGORY}" "${PUSH_OUTPUT}"
    fi
  fi
  echo "Branch ${BRANCH} pushed successfully"
fi

# ---------------------------------------------------------------------------
# 5. Process structured output (agent-result.json)
# ---------------------------------------------------------------------------
forge_setup_push_token "${PUSH_TOKEN}"

# Locate process-fix-result.py relative to this script, with workspace fallback
# (see the "Auto-install pre-commit tool dependencies" comment above — this
# companion script was never migrated into this repo either).
PROCESS_SCRIPT="${SCRIPT_DIR_POST}/process-fix-result.py"

if [ ! -f "${PROCESS_SCRIPT}" ]; then
  if [ -n "${WORKSPACE_DIR:-}" ]; then
    for _ws_candidate in "${WORKSPACE_DIR}/scripts" "${WORKSPACE_DIR}/.fullsend/scripts"; do
      if [ -f "${_ws_candidate}/process-fix-result.py" ]; then
        PROCESS_SCRIPT="${_ws_candidate}/process-fix-result.py"
        break
      fi
    done
  fi
fi

# RESULT_FILE was already located above (before section 4) so the rebase-skip
# check could consult rebased_onto_target — see issue #565.

# The summary comment normally carries the strip note; when it is skipped, post
# the note on its own so the rewrite still leaves a trace on the PR.
signoff_note_fallback() {
  if [ "${SIGNOFF_STRIPPED}" = "true" ] && declare -F forge_post_pr_comment >/dev/null; then
    forge_post_pr_comment "${PR_NUMBER}" \
      "Removed a Signed-off-by trailer from ${SIGNOFF_STRIPPED_COUNT} agent commit(s)." \
      || gha_echo warning "Could not post the Signed-off-by strip note to PR #${PR_NUMBER}"
  fi
}

if [ -z "${RESULT_FILE}" ] || [ ! -f "${RESULT_FILE}" ]; then
  gha_echo warning "No agent-result.json found — skipping summary comment"
  signoff_note_fallback
elif [ ! -f "${PROCESS_SCRIPT}" ]; then
  gha_echo warning "process-fix-result.py not found at ${PROCESS_SCRIPT} — skipping"
  signoff_note_fallback
else
  # Scan agent-result.json for secrets before posting content as a PR comment.
  # The agent could have been tricked into embedding sensitive data in the
  # structured output via prompt injection in the review body.
  if command -v gitleaks >/dev/null 2>&1; then
    echo "Scanning agent-result.json for secrets before posting..."
    SCAN_DIR="$(mktemp -d)"
    cp "${RESULT_FILE}" "${SCAN_DIR}/agent-result.json"
    if ! gitleaks detect --source "${SCAN_DIR}" --no-git --redact 2>/dev/null; then
      rm -rf "${SCAN_DIR}"
      post_fail_to_pr secret-scan "${POST_FAILURE_SECRET_SCAN_MESSAGE}"
    fi
    rm -rf "${SCAN_DIR}"
  fi

  echo "Processing agent-result.json: ${RESULT_FILE}"
  PROCESS_EXIT=0
  SIGNOFF_STRIPPED_COUNT="${SIGNOFF_STRIPPED_COUNT}" \
    python3 "${PROCESS_SCRIPT}" "${RESULT_FILE}" "${REPO_FULL_NAME}" "${PR_NUMBER}" || PROCESS_EXIT=$?
  if [ "${PROCESS_EXIT}" -eq 1 ]; then
    post_fail_to_pr process-output-failed \
      "process-fix-result.py failed with exit code 1 (bad input) for PR #${PR_NUMBER} in ${REPO_FULL_NAME}"
  elif [ "${PROCESS_EXIT}" -ne 0 ]; then
    gha_echo warning "process-fix-result.py exited ${PROCESS_EXIT} — continuing with labels/summary"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Iteration-cap warning label
# ---------------------------------------------------------------------------
ITERATION="${FIX_ITERATION:-1}"
BOT_CAP="${ITERATION_CAP:-5}"

# Per-PR automatic fix budget (issue #1680): mirror pre-fix so the
# needs-human warning and summary use the same tightened bot cap that
# pre-fix enforces. Read live; a failed read keeps the configured cap.
FIX_BUDGET=""
if is_bot_user "${TRIGGER_SOURCE}"; then
  if PR_LABELS_LIVE="$(forge_get_pr_labels "${PR_NUMBER}")"; then
    FIX_BUDGET="$(fix_budget_from_labels "${PR_LABELS_LIVE}" "${BOT_CAP}")"
  else
    gha_echo warning "Could not read PR labels — any fullsend-fix-budget/N label is ignored for this run"
  fi
fi
BOT_CAP="${FIX_BUDGET:-${BOT_CAP}}"
WARN_THRESHOLD=$(( BOT_CAP - 1 ))

# The needs-human label is based on the bot cap — it signals that the
# autonomous review→fix loop needs human direction. Human-triggered /fs-fix
# runs have a separate, higher cap (ITERATION_CAP_HUMAN).
if [ "${ITERATION}" -ge "${WARN_THRESHOLD}" ] && is_bot_user "${TRIGGER_SOURCE}"; then
  if [ -n "${FIX_BUDGET}" ]; then
    gha_echo warning "Fix iteration ${ITERATION} is approaching the per-PR automatic fix budget of ${BOT_CAP} set by label fullsend-fix-budget/${FIX_BUDGET}"
  else
    gha_echo warning "Fix iteration ${ITERATION} is approaching bot cap of ${BOT_CAP}"
  fi
  forge_create_label "needs-human" "Agent loop needs human intervention" "D93F0B"
  # shellcheck disable=SC2153
  forge_add_pr_label "${PR_NUMBER}" "needs-human"
fi

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
echo ""
echo "Fix post-script complete:"
echo "  Branch: ${BRANCH:-none}"
echo "  PR: #${PR_NUMBER}"
if [ "${NO_PUSH}" = "true" ]; then echo "  Pushed: no"; else echo "  Pushed: yes"; fi
echo "  Trigger: ${TRIGGER_SOURCE}"
if is_bot_user "${TRIGGER_SOURCE}" && [ -n "${FIX_BUDGET}" ]; then
  echo "  Iteration: ${ITERATION} of ${BOT_CAP} (bot cap, lowered by label fullsend-fix-budget/${FIX_BUDGET})"
elif is_bot_user "${TRIGGER_SOURCE}"; then
  echo "  Iteration: ${ITERATION} of ${BOT_CAP} (bot cap)"
else
  echo "  Iteration: ${ITERATION} of ${ITERATION_CAP_HUMAN:-10} (human cap, total across bot+human)"
fi
