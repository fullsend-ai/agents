#!/usr/bin/env bash
# write-approval-check.lib.sh — Shared enforcement for fullsend-ai/fullsend#5687.
#
# A PR whose issue/PR timeline ever recorded a needs-write-approval label
# (applied by post-code.sh/post-fix.sh when the dispatching user held only
# GitHub's triage role, not write+) must not be enqueued/merged without a
# live APPROVE review, on the PR's current head commit, from a human
# collaborator whose CURRENT permission is admin/maintain/write.
#
# Source from enqueue-pr.sh / await-and-enqueue.sh:
#   source "${SCRIPT_DIR}/lib/write-approval-check.lib.sh"
#
# Design notes:
#   - "Ever recorded", not "currently labeled": GitHub's triage role includes
#     repo-wide label management, so a triage-role user could otherwise strip
#     needs-write-approval from their own bot-authored PR and skip this check
#     entirely. The issue events timeline records the labeled event
#     permanently; removing the label later does not erase it.
#   - Pinned to the current head commit: an APPROVE review does not
#     automatically become stale when new commits land unless a repo's
#     branch protection specifically enables that — which this check cannot
#     assume is configured. Re-deriving "is the latest approval for the
#     current code" here closes that gap independent of branch protection.
#   - Bot/App reviewers never count: even though nothing in this pipeline
#     currently submits an automated APPROVE review, this stays correct if
#     that ever changes.
#   - This must be enforced at the actual enqueue call site (enqueue-pr.sh),
#     not only in a polling wrapper — await-and-enqueue.sh is one of two
#     documented entry points and simply execs enqueue-pr.sh at the end, so
#     putting the check there alone would not cover a direct enqueue-pr.sh
#     invocation.

[[ -n "${WRITE_APPROVAL_CHECK_SH_LOADED:-}" ]] && return 0
WRITE_APPROVAL_CHECK_SH_LOADED=1

# Whether needs-write-approval was ever applied to this PR, per the issue
# events timeline (immutable to a later label removal). Prints "true"/"false".
write_approval_ever_required() {
  local repo="$1" number="$2"
  gh api "repos/${repo}/issues/${number}/events" --paginate 2>/dev/null \
    | jq -s -r '
        [add // [] | .[] | select(.event == "labeled" and .label.name == "needs-write-approval")]
        | length > 0
      ' 2>/dev/null || echo "true"
}

# At least one APPROVE review, on the PR's current head commit, from a human
# (non-bot) collaborator whose current permission is admin/maintain/write.
has_write_plus_approval() {
  local repo="$1" number="$2" head_sha="$3"
  local reviews approved_users user role
  reviews="$(gh api "repos/${repo}/pulls/${number}/reviews" --paginate 2>/dev/null)" || return 1
  approved_users="$(echo "${reviews}" | jq -s -r --arg head "${head_sha}" '
    add // []
    | group_by(.user.login)
    | map(max_by(.submitted_at))
    | map(select(.state == "APPROVED" and .commit_id == $head))
    | map(select((.user.login // "") | test("\\[bot\\]$") | not))
    | map(select(.user.login != "dependabot"))
    | .[].user.login
  ')"
  [[ -z "${approved_users}" ]] && return 1
  while IFS= read -r user; do
    [[ -z "${user}" ]] && continue
    role="$(gh api "repos/${repo}/collaborators/${user}/permission" --jq '.role_name' 2>/dev/null || echo "")"
    case "${role}" in
      admin|maintain|write) return 0 ;;
    esac
  done <<< "${approved_users}"
  return 1
}

# Fails closed: on any error resolving the requirement, treat the gate as
# required and unsatisfied rather than silently permitting enqueue.
# Args: repo, pr_number, head_sha. Prints a message and returns 1 on failure.
enforce_write_approval_gate() {
  local repo="$1" number="$2" head_sha="$3"
  local ever_required
  ever_required="$(write_approval_ever_required "${repo}" "${number}")"
  if [[ "${ever_required}" != "true" ]]; then
    return 0
  fi
  if has_write_plus_approval "${repo}" "${number}" "${head_sha}"; then
    return 0
  fi
  echo "PR #${number} required needs-write-approval at some point (GitHub triage-role trigger, fullsend-ai/fullsend#5687) but has no APPROVE review, on its current head commit, from a currently admin/maintain/write human collaborator." >&2
  return 1
}
