#!/usr/bin/env bash
# shellcheck shell=bash
# triage-ops.lib.sh — Tracker-dispatch wrapper for triage operations.
#
# Sources the correct tracker-specific ops based on FULLSEND_TRACKER
# (falling back to FULLSEND_FORGE if FULLSEND_TRACKER is unset).
# Bundled inline by bundle-sh.sh at build time.

[[ -n "${TRIAGE_OPS_SH_LOADED:-}" ]] && return 0
TRIAGE_OPS_SH_LOADED=1

_gha_sanitize() { printf '%s' "$1" | tr -d '\n\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/%/%25/g; s/::/%3A%3A/g'; }

# --- Candidate URL visibility (defense in depth) ---
#
# `redacted: true` on a pull_requests/prerequisites.existing entry is a
# signal the triage agent sets after checking visibility itself
# (agents/triage.md's Visibility check) — it is not something this script
# can trust alone: an agent that omits the field, sets it false, or could
# not determine visibility would otherwise let a private candidate
# PR/MR/issue URL reach the automated "Addressed by:"/"Blocked by:"
# footer, which post-triage.sh appends unconditionally regardless of what
# `comment` says. Before interpolating any candidate URL into either
# footer, resolve the candidate's own repo/project visibility straight
# from the URL. This dispatches on the URL's own host rather than
# FULLSEND_TRACKER, since a Jira- or GitLab-triaged issue can still
# reference a GitHub PR, and vice versa.
#
# Prints one of: public | private | internal | unknown. Fails closed: any
# lookup failure, missing credential/tool, or unrecognized URL shape
# reports "unknown". Callers must treat anything other than "public" as
# not safe to publish. Jira issue URLs have no repo-visibility concept in
# this pipeline, so they are reported "public" (not redacted by this
# check) — the leak this check closes is specifically candidate
# GitHub/GitLab repos, per agents/triage.md's Visibility check.
_candidate_url_visibility() {
  local url="$1"
  case "${url}" in
    https://github.com/*)
      local repo vis
      repo=$(echo "${url}" | sed -E 's#^https://github\.com/([^/]+/[^/]+)/.*#\1#')
      if [[ -z "${repo}" ]] || ! command -v gh >/dev/null 2>&1; then
        echo "unknown"
        return
      fi
      vis=$(gh repo view "${repo}" --json visibility --jq '.visibility' 2>/dev/null) || {
        echo "unknown"
        return
      }
      # GitHub's GraphQL RepositoryVisibility enum is uppercase
      # (PUBLIC/PRIVATE/INTERNAL); case-fold so the caller's lowercase
      # "public" comparison actually matches.
      vis=$(printf '%s' "${vis}" | tr '[:upper:]' '[:lower:]')
      echo "${vis:-unknown}"
      ;;
    https://*/-/merge_requests/*|https://*/-/issues/*)
      local host project encoded vis
      host=$(echo "${url}" | sed -E 's#^https://([^/]+)/.*#\1#')
      project=$(echo "${url}" | sed -E 's#^https://[^/]+/(.+)/-/(merge_requests|issues)/[0-9]+$#\1#')
      if [[ -z "${host}" || -z "${project}" || -z "${GITLAB_TOKEN:-}" ]] || ! declare -F _validate_gitlab_host >/dev/null 2>&1; then
        echo "unknown"
        return
      fi
      _validate_gitlab_host "${host}" >/dev/null 2>&1 || {
        echo "unknown"
        return
      }
      encoded=$(printf '%s' "${project}" | jq -sRr @uri)
      vis=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "https://${host}/api/v4/projects/${encoded}" 2>/dev/null | jq -r '.visibility // empty') || {
        echo "unknown"
        return
      }
      echo "${vis:-unknown}"
      ;;
    https://*.atlassian.net/browse/*)
      echo "public"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# True (exit 0) only when the candidate URL's visibility resolves to
# "public". Private, internal, unknown, and lookup failures all count as
# not public — the caller treats them the same as an agent-set `redacted`.
_candidate_url_is_public() {
  [[ "$(_candidate_url_visibility "$1")" == "public" ]]
}

# Strips literal occurrences of a withheld candidate URL from freeform text.
#
# _candidate_url_is_public (and the agent's own `redacted` flag) only gate
# whether a URL reaches the automated "Blocked by:"/"Addressed by:" footer.
# The agent-authored `comment` field is a separate, untrusted channel:
# agents/triage.md instructs the agent not to name a withheld candidate's
# repo/title/URL there, but that's a prompt instruction, not an enforced
# boundary, and the fetched PR/MR content that informs `comment` is itself
# untrusted input. Call this for every withheld URL before the comment is
# posted so a withheld identity can't leak through prose that echoes it.
#
# Escaping matches the sed-based marker-escaping used elsewhere in this
# codebase (e.g. gitlab-triage-ops.lib.sh's sticky-comment stripping):
# escape basic-regex metacharacters, then escape "/" since sed uses it as
# the delimiter.
_redact_url_from_text() {
  local text="$1"
  local url="$2"
  if [[ -z "${url}" ]]; then
    printf '%s' "${text}"
    return
  fi
  local escaped_url
  escaped_url=$(printf '%s' "${url}" | sed 's/[].[*^$()+?{|\\]/\\&/g; s|/|\\/|g')
  printf '%s' "${text}" | sed "s/${escaped_url}/[link withheld]/g"
}

FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE:-}}"

case "${FULLSEND_TRACKER:-}" in
  github)
    source "${SCRIPT_DIR}/lib/github-triage-ops.lib.sh"
    ;;
  gitlab)
    source "${SCRIPT_DIR}/lib/gitlab-triage-ops.lib.sh"
    ;;
  jira)
    source "${SCRIPT_DIR}/lib/jira-triage-ops.lib.sh"
    ;;
  *)
    echo "ERROR: invalid FULLSEND_TRACKER: '${FULLSEND_TRACKER:-}' — pass --tracker <github|gitlab|jira> or set FULLSEND_TRACKER" >&2
    exit 1
    ;;
esac
