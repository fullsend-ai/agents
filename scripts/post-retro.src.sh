#!/usr/bin/env bash
# post-retro.sh — File issues from retro agent proposals and post summary.
#
# Runs on the host after sandbox cleanup. Working directory is the fullsend
# run output directory.
#
# Required env vars:
#   ORIGINATING_URL — HTML URL of the originating PR or issue
#   FULLSEND_FORGE  — "github" or "gitlab"
#
# Optional env vars:
#   FULLSEND_TRACKER    — "jira", or the same value as FULLSEND_FORGE
#                         (defaults to FULLSEND_FORGE)
#   RETRO_MODE          — "all" (default), "summary_only", or "issues_only"
#   RETRO_JIRA_PROJECT  — Jira project key for created issues (when FULLSEND_TRACKER=jira)
#   FULLSEND_DIR        — .fullsend directory (when FULLSEND_TRACKER=jira)
#
# Forge-specific token env vars:
#   GH_TOKEN      — GitHub token (when FULLSEND_FORGE=github)
#   GITLAB_TOKEN  — GitLab token (when FULLSEND_FORGE=gitlab)
#   JIRA_TOKEN    — Jira token (when FULLSEND_TRACKER=jira)
#
# The agent writes its result to output/agent-result.json (relative to
# the iteration directory). This script finds the most recent iteration's output.

set -euo pipefail

: "${ORIGINATING_URL:?ORIGINATING_URL is required}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/retro-ops.lib.sh
source "${SCRIPT_DIR}/lib/retro-ops.lib.sh"

forge_validate_originating_url
forge_parse_originating_url

forge_require_token
forge_mask_token

# Find the retro result JSON — prefer the validated iteration when set.
# Trust boundary: FULLSEND_VALIDATED_ITERATION_DIR is set by the fullsend CLI
# on the runner — not by the sandbox or the agent. No containment check
# (realpath / prefix guard) is applied here; the value is trusted from the
# external harness. If the trust model changes, add a realpath prefix check.
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  if [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
  elif [[ -f "${FULLSEND_VALIDATED_ITERATION_DIR}/result.json" ]]; then
    RESULT_FILE="${FULLSEND_VALIDATED_ITERATION_DIR}/result.json"
  else
    echo "ERROR: FULLSEND_VALIDATED_ITERATION_DIR is set but contains neither agent-result.json nor result.json" >&2
    exit 1
  fi
else
  # Backward compatibility: scan iteration-N/ subdirectories for the last one's output.
  RESULT_FILE=""
  for dir in iteration-*/output; do
    if [[ -f "${dir}/agent-result.json" ]]; then
      RESULT_FILE="${dir}/agent-result.json"
    fi
  done
fi

if [[ -z "${RESULT_FILE}" ]]; then
  echo "ERROR: agent-result.json not found in any iteration output directory" >&2
  exit 1
fi

echo "Reading retro result from: ${RESULT_FILE}"

# Validate JSON is parseable.
if ! jq empty "${RESULT_FILE}" 2>/dev/null; then
  echo "ERROR: ${RESULT_FILE} is not valid JSON" >&2
  exit 1
fi

echo "Originating: ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}"

echo "Mode: ${RETRO_MODE}"

# Read the allowlist from config.yaml. The config repo is checked out
# at the forge-specific workspace directory by the reusable workflow. For a
# Jira tracker, the allowlist and primary project are read from FULLSEND_DIR,
# the directory the fullsend CLI and the Jira operations use, so the policy
# applied here is the policy the CLI enforces.
FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE}}"
TRACKER_PROVIDER="${FULLSEND_TRACKER}"
ALLOW_TARGETS_KEY="tracker.${TRACKER_PROVIDER}.allowed_targets"
if [[ "${FULLSEND_TRACKER}" == "jira" && -n "${FULLSEND_DIR:-}" ]]; then
  CONFIG_WORKSPACE="${FULLSEND_DIR}"
else
  CONFIG_WORKSPACE="$(forge_get_config_workspace)"
fi
CONFIG_FILE="${CONFIG_WORKSPACE}/config.yaml"
if [[ "${FULLSEND_TRACKER}" != "jira" && ! -f "${CONFIG_FILE}" && ! -f "${CONFIG_WORKSPACE}/config.base.yaml" ]]; then
  # Per-repo mode: config is under .fullsend/
  CONFIG_FILE="${CONFIG_WORKSPACE}/.fullsend/config.yaml"
fi
# For a Jira tracker there is no .fullsend/ fallback: the CLI treats
# --fullsend-dir as the directory that holds config.yaml, and the Jira REST
# routing reads the same path through _retro_jira_config_value. Accepting a
# nested config here alone would pass the allowlist with a config the CLI and
# the REST calls cannot see. Say so instead of denying every proposal with the
# allowlist warning.
if [[ "${FULLSEND_TRACKER}" == "jira" && ! -f "${CONFIG_FILE}" && ! -f "${CONFIG_WORKSPACE}/config.base.yaml" ]]; then
  echo "::warning::no config.yaml in FULLSEND_DIR (${CONFIG_WORKSPACE}) — FULLSEND_DIR must be the .fullsend directory itself, which holds config.yaml with the tracker.jira block; the fullsend CLI and Jira REST routing read that path. Cross-repo issue creation is disabled."
fi
# A configuration preset (config.base.yaml) sits beside the overlay. As in
# fullsend's layered config, an overlay that sets tracker replaces the base
# tracker as a whole object (an explicit empty target policy included);
# otherwise tracker is inherited from the base. A null or bare `tracker:` in
# the overlay counts as unset (it inherits the base), matching that merge.
BASE_CONFIG_FILE="$(dirname "${CONFIG_FILE}")/config.base.yaml"

# ALLOWED_SCOPES holds GitHub orgs or GitLab groups (a scope admits every
# repository under it, including GitLab subgroups); ALLOWED_REPOS holds
# repositories allowed by exact path (or Jira project keys when FULLSEND_TRACKER=jira).
# Jira's CLI accepts its primary project plus explicit additional target
# projects. Match that same policy here before invoking the CLI.
ALLOWED_SCOPES=""
ALLOWED_REPOS=""
JIRA_PRIMARY_PROJECT=""
JIRA_ALLOWLIST_STATE="unset"
if [[ -f "${CONFIG_FILE}" || -f "${BASE_CONFIG_FILE}" ]] && ! command -v yq &>/dev/null; then
  echo "::warning::yq not found — cannot read ${ALLOW_TARGETS_KEY} from config; cross-repo issue creation disabled"
  JIRA_ALLOWLIST_STATE="failed"
fi
if command -v yq &>/dev/null; then
  TRACKER_JSON="null"
  OVERLAY_TRACKER_NULL="false"
  for layer_file in "${CONFIG_FILE}" "${BASE_CONFIG_FILE}"; do
    [[ -f "${layer_file}" ]] || continue
    # Fail closed: an unparseable layer disables cross-repo issue creation.
    if ! layer_tracker=$(yq -o=json '.tracker' "${layer_file}" 2>/dev/null); then
      echo "::warning::cannot parse $(basename "${layer_file}") — cross-repo issue creation disabled"
      TRACKER_JSON="null"
      JIRA_ALLOWLIST_STATE="failed"
      break
    fi
    # The old create_issues.allow_targets key is no longer read.
    if yq -e '.create_issues.allow_targets' "${layer_file}" &>/dev/null; then
      echo "::warning::$(basename "${layer_file}") sets create_issues.allow_targets, which is no longer read — move its targets to ${ALLOW_TARGETS_KEY}"
    fi
    if [[ "${TRACKER_JSON}" == "null" ]]; then
      # An overlay that sets tracker to null inherits the base targets; say so
      # when that keeps cross-repo grants the operator may have meant to clear.
      if [[ "${OVERLAY_TRACKER_NULL}" == "true" ]] && jq -e '[.. | arrays | select(length > 0)] | length > 0' <<<"${layer_tracker}" &>/dev/null; then
        echo "::warning::config.yaml sets tracker to null, so cross-repo targets from $(basename "${layer_file}") are inherited — set an empty ${ALLOW_TARGETS_KEY} in config.yaml to revoke them"
      fi
      TRACKER_JSON="${layer_tracker}"
    fi
    if [[ "${layer_file}" == "${CONFIG_FILE}" && "${layer_tracker}" == "null" && "$(yq 'has("tracker")' "${layer_file}" 2>/dev/null)" == "true" ]]; then
      OVERLAY_TRACKER_NULL="true"
    fi
  done
  # Warn when a tracker mapping selects other or several providers, since it
  # then grants no cross-repo targets. For Jira the primary project is still
  # permitted, because it is not a cross-project grant.
  TRACKER_PROVIDERS=$(jq -r '
    (if type == "object" then . else {} end) as $t
    | [("github", "gitlab", "jira") | select($t[.] != null)] | join(",")
  ' <<<"${TRACKER_JSON}" 2>/dev/null || true)
  if [[ -n "${TRACKER_PROVIDERS}" && "${TRACKER_PROVIDERS}" != "${TRACKER_PROVIDER}" ]]; then
    echo "::warning::tracker mapping selects provider(s) '${TRACKER_PROVIDERS}' but FULLSEND_TRACKER requires only '${TRACKER_PROVIDER}' — no cross-repo targets granted"
    if [[ "${TRACKER_PROVIDER}" != "jira" && "${JIRA_ALLOWLIST_STATE}" != "failed" ]]; then
      JIRA_ALLOWLIST_STATE="failed"
    fi
  fi
  # Honor targets only when the tracker selects exactly one provider and it
  # is the forge issues are created on; otherwise nothing is granted.
  ALLOWED_TARGETS_JSON=$(jq -c --arg provider "${TRACKER_PROVIDER}" '
    (if type == "object" then . else {} end) as $t
    | [("github", "gitlab", "jira") | select($t[.] != null)] as $providers
    | if $providers == [$provider] then ($t[$provider].allowed_targets // {}) else {} end
    | if type == "object" then . else {} end
  ' <<<"${TRACKER_JSON}" 2>/dev/null || echo '{}')
  ALLOWED_SCOPES=$(jq -r --arg provider "${TRACKER_PROVIDER}" '
    (if $provider == "github" then .orgs elif $provider == "gitlab" then .groups else null end)
    | if type == "array" then .[] | strings else empty end
  ' <<<"${ALLOWED_TARGETS_JSON}" 2>/dev/null || true)
  ALLOWED_REPOS=$(jq -r --arg provider "${TRACKER_PROVIDER}" '
    (if type == "object" then . else {} end) as $t
    | [("github", "gitlab", "jira") | select($t[.] != null)] as $providers
    | if $provider == "jira" then
        if $providers == [$provider] and (.jira | type == "object") then
          ([.jira.project] + (if (.jira.allowed_targets.projects | type) == "array" then .jira.allowed_targets.projects else [] end) | map(select(type == "string")) | map(ascii_upcase) | unique)
        else
          []
        end | .[]
    else
      (if $providers == [$provider] then (($t[$provider].allowed_targets // {}).repos // []) else [] end)
      | if type == "array" then .[] | strings else empty end
    end
  ' <<<"${TRACKER_JSON}" 2>/dev/null || true)
  if [[ "${TRACKER_PROVIDER}" == "jira" && "${JIRA_ALLOWLIST_STATE}" != "failed" ]]; then
    if [[ "${TRACKER_JSON}" != "null" && -n "${TRACKER_JSON}" ]]; then
      # The primary project and the target policy both come from the already
      # resolved TRACKER_JSON, so the whole-object tracker merge is applied
      # once and this gate cannot resurrect a base-layer project.
      JIRA_PRIMARY_PROJECT=$(jq -r '
        if type == "object" and (.jira | type) == "object" and (.jira.project | type) == "string"
        then .jira.project | ascii_upcase
        else ""
        end
      ' <<<"${TRACKER_JSON}" 2>/dev/null || echo "")
      if [[ "${TRACKER_PROVIDERS}" != "jira" ]]; then
        # A mapping that also names another provider grants no cross-project
        # targets, but the Jira primary project is not a cross-project grant.
        JIRA_ALLOWLIST_STATE="unset"
        ALLOWED_REPOS=""
      else
        projects_status=$(jq -r '
          if type != "object" or (has("jira") | not) or (.jira | type != "object") then
            "failed"
          elif (.jira | has("allowed_targets")) then
            if (.jira.allowed_targets | type == "object") and (.jira.allowed_targets | has("projects")) then
              if (.jira.allowed_targets.projects | type == "array") then
                "configured"
              else
                "failed"
              end
            elif (.jira.allowed_targets == null) then
              "unset"
            elif (.jira.allowed_targets | type == "object") and ((.jira.allowed_targets | has("projects")) | not) then
              "unset"
            else
              "failed"
            end
          else
            "unset"
          end
        ' <<<"${TRACKER_JSON}" 2>/dev/null || echo "failed")
        if [[ "${projects_status}" == "configured" ]]; then
          JIRA_ALLOWLIST_STATE="configured"
        elif [[ "${projects_status}" == "failed" ]]; then
          JIRA_ALLOWLIST_STATE="failed"
        else
          JIRA_ALLOWLIST_STATE="unset"
        fi
      fi
    else
      JIRA_ALLOWLIST_STATE="failed"
    fi
  fi
fi

# The originating repo is always implicitly allowed.
is_target_allowed() {
  local target_repo="$1"
  local scope

  if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
    case "${JIRA_ALLOWLIST_STATE}" in
      failed)
        return 1
        ;;
      configured)
        if [[ -n "${ALLOWED_REPOS}" ]] && echo "${ALLOWED_REPOS}" | grep -qiFx "${target_repo}"; then
          return 0
        fi
        [[ -n "${JIRA_PRIMARY_PROJECT}" && "${JIRA_PRIMARY_PROJECT}" == "${target_repo^^}" ]] && return 0
        return 1
        ;;
      unset)
        [[ -n "${JIRA_PRIMARY_PROJECT}" && "${JIRA_PRIMARY_PROJECT}" == "${target_repo^^}" ]]
        return $?
        ;;
      *)
        return 1
        ;;
    esac
  fi

  # Source repo is always allowed.
  if [[ "${target_repo}" == "${ORIGINATING_REPO}" ]]; then
    return 0
  fi

  # Check org/group allowlist (a group also covers its subgroups' projects).
  while IFS= read -r scope; do
    if [[ -n "${scope}" && "${target_repo}" == "${scope}/"* ]]; then
      return 0
    fi
  done <<<"${ALLOWED_SCOPES}"

  # Check repo allowlist.
  if [[ -n "${ALLOWED_REPOS}" ]] && echo "${ALLOWED_REPOS}" | grep -qFx "${target_repo}"; then
    return 0
  fi

  return 1
}

# File an issue for each proposal.
PROPOSAL_COUNT=$(jq '.proposals | length' "${RESULT_FILE}")
echo "Found ${PROPOSAL_COUNT} proposal(s)"

# Resolve Jira REST routing and mint client-credentials tokens once, in this
# shell, before the proposal loop. The REST calls run in command substitutions,
# so doing this per call would exchange a new OAuth token and re-discover the
# cloud ID for every request. Skipped when there is nothing to file, so a run
# with no proposals makes no Jira calls at all.
#
# A failure here (for example a transient token-endpoint error) is not fatal to
# the run: it marks every proposal as not filed and still posts the summary
# comment, as the other Jira failures below do. Only issues_only exits non-zero,
# and it does so through the usual proposal-failure path.
JIRA_INIT_STATE="skipped"
if [[ "${FULLSEND_TRACKER}" == "jira" ]] && [[ "${RETRO_MODE}" != "summary_only" ]] \
  && [[ "${PROPOSAL_COUNT}" -gt 0 ]] && declare -f _retro_jira_init >/dev/null 2>&1; then
  if _retro_jira_init; then
    JIRA_INIT_STATE="ok"
  else
    JIRA_INIT_STATE="failed"
    echo "::warning::cannot initialize Jira REST access (token mint or routing) — no proposals will be filed; the summary comment is still posted"
  fi
fi

# Validate all proposals before filing any to avoid partial state.
# Guard on PROPOSAL_COUNT > 0: `seq 0 $((PROPOSAL_COUNT - 1))` with
# PROPOSAL_COUNT=0 becomes `seq 0 -1`, which some seq implementations treat
# as a descending range (0, -1) rather than empty, causing an out-of-bounds
# proposals[0] access when there are no proposals.
if [[ "${PROPOSAL_COUNT}" -gt 0 ]]; then
  for i in $(seq 0 $((PROPOSAL_COUNT - 1))); do
    TR=$(jq -r ".proposals[$i].target_repo" "${RESULT_FILE}")
    if [[ ! "${TR}" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)+$ ]]; then
      echo "ERROR: proposal[$i].target_repo is not a valid repo path: $(_gha_sanitize "${TR}")" >&2
      exit 1
    fi
    TI=$(jq -r ".proposals[$i].title // empty" "${RESULT_FILE}")
    if [[ -z "${TI}" ]]; then
      echo "ERROR: proposal[$i].title is missing or empty" >&2
      exit 1
    fi
    # The schema allows a whitespace-only title (minLength 1, no pattern), and
    # Jira normalization collapses it to "", which the filing loop rejects. Run
    # the same normalization here so that rejection happens before any proposal
    # is filed, not mid-loop after earlier proposals already exist in Jira.
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      if ! NORMALIZED_TITLE=$(_retro_jira_normalize_summary "${TI}"); then
        echo "ERROR: proposal[$i].title could not be normalized for the Jira summary limit" >&2
        exit 1
      fi
      if [[ -z "${NORMALIZED_TITLE}" ]]; then
        echo "ERROR: proposal[$i].title is empty after trimming for Jira" >&2
        exit 1
      fi
    fi
    jq -e ".proposals[$i] | .what_happened and .what_could_go_better and .proposed_change and .validation_criteria" "${RESULT_FILE}" >/dev/null 2>&1 || {
      echo "ERROR: proposal[$i] is missing required fields" >&2
      exit 1
    }
  done
fi
echo "All ${PROPOSAL_COUNT} proposal(s) validated"

# Three-state: "unknown" until tracker_validate_create runs, then "ok" or
# "failed". A failed check is not retried for the remaining proposals, so a
# misconfigured project costs one CLI/createmeta probe per run, not one per
# proposal.
JIRA_CREATEMETA_STATE="unknown"

# fullsend's `issues create --tracker jira` rejects a body over
# jira.MaxMarkdownBytes (32 KiB, checked as len(body) > 32768) before it
# converts the Markdown to ADF, and nothing trims the body first. The schema
# allows 8192 characters in each of four sections, so a schema-valid proposal
# can exceed the cap once the headings, the dedup receipt and the footer are
# added, and the create then fails with no issue filed.
RETRO_JIRA_BODY_MAX_BYTES=32768

# fullsend's `issues post-comment --tracker jira` caps a comment at
# jira.MaxMarkdownBytes (32768 bytes) too, but only on the update path: a new
# comment is neutralized (NeutralizeMarkersADF, which grows every fullsend
# marker opener by four bytes) and then converted with MarkdownToADF, which
# refuses a body over the limit. That error is not a 401/403, so an oversized
# summary fails the post after the issues were already filed. Stay under the
# cap with headroom for neutralization.
RETRO_JIRA_COMMENT_MAX_BYTES=32000

# Print $1 truncated to $2 bytes and append $3 (the truncation marker). The
# limits callers enforce are in bytes, so the over-limit test measures under
# LC_ALL=C, where string length counts bytes rather than characters. The cut
# itself steps over whole code points in jq, so a multi-byte character is
# never split.
_retro_fit_bytes() {
  local LC_ALL=C
  local text="$1" budget="$2" marker="$3" kept
  if [[ "${#text}" -le ${budget} ]]; then
    printf '%s' "${text}"
    return 0
  fi
  kept=$(printf '%s' "${text}" | jq -Rrs --argjson budget "${budget}" '
    # Keep the longest prefix whose UTF-8 encoding fits in $budget bytes. The
    # cumulative widths increase strictly, so counting the offsets inside the
    # budget gives the number of code points that fit; jq then slices strings
    # by code point, so the result is always valid UTF-8.
    . as $s
    | ([$s | explode[]
        | if . < 128 then 1 elif . < 2048 then 2 elif . < 65536 then 3 else 4 end]
       | [foreach .[] as $w (0; . + $w)]
       | map(select(. <= $budget))
       | length) as $n
    | $s[0:$n]')
  printf '%s%s' "${kept}" "${marker}"
}

# Print $1 truncated to RETRO_JIRA_BODY_MAX_BYTES bytes, re-appending $2 (the
# originating-URL footer) verbatim and marking where the text was cut.
_retro_jira_fit_body() {
  local LC_ALL=C
  local body="$1" footer="$2" marker budget
  if [[ "${#body}" -le "${RETRO_JIRA_BODY_MAX_BYTES}" ]]; then
    printf '%s' "${body}"
    return 0
  fi
  marker=$'\n\n_(truncated to fit the Jira issue body limit; see the originating PR/issue for the full text)_'
  budget=$((RETRO_JIRA_BODY_MAX_BYTES - ${#marker} - ${#footer}))
  _retro_fit_bytes "${body}" "${budget}" "${marker}"
  printf '%s' "${footer}"
}

# Print $1 truncated to RETRO_JIRA_COMMENT_MAX_BYTES bytes, appending $2 (the
# truncation suffix).
_retro_jira_fit_comment() {
  local LC_ALL=C
  local comment="$1" suffix="$2"
  _retro_fit_bytes "${comment}" "$((RETRO_JIRA_COMMENT_MAX_BYTES - ${#suffix}))" "${suffix}"
}

ISSUE_LINKS=""
EXISTING_ISSUES=""
EVIDENCE_NOTES=""
FILTERED_COUNT=0
SKIPPED_TARGETS=""
RECEIPT_SKIPPED=""
FAILED_PROPOSALS=""
SUMMARY_ONLY_PROPOSALS=""
if [[ "${PROPOSAL_COUNT}" -gt 0 ]]; then
  for i in $(seq 0 $((PROPOSAL_COUNT - 1))); do
    TARGET_REPO=$(jq -r ".proposals[$i].target_repo" "${RESULT_FILE}")
    TITLE=$(jq -r ".proposals[$i].title" "${RESULT_FILE}")
    # Jira Cloud rejects a summary over 255 characters or containing a line
    # break, and the schema permits both (maxLength 256, newlines allowed), so
    # normalize once here: the in-run title set, the duplicate search and the
    # create all then use the value Jira stores.
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      TITLE_RAW="${TITLE}"
      if ! TITLE=$(_retro_jira_normalize_summary "${TITLE_RAW}"); then
        echo "ERROR: proposal[$i].title could not be normalized for the Jira summary limit" >&2
        exit 1
      fi
      if [[ -z "${TITLE}" ]]; then
        echo "ERROR: proposal[$i].title is empty after trimming for Jira" >&2
        exit 1
      fi
      if [[ "${TITLE}" != "${TITLE_RAW}" ]]; then
        echo "::warning::proposal[$i] title normalized to the Jira summary limit (${RETRO_JIRA_SUMMARY_MAX_CHARS} characters, single line)"
      fi
    fi
    SAFE_TITLE=$(_gha_sanitize "${TITLE}")

    # Deterministic gate: reject "Evidence for" proposals.
    # The retro-analysis skill instructs the agent not to file these, but the
    # agent ignores the instruction frequently enough that a post-script gate
    # is needed. See fullsend-ai/fullsend#3881.
    TITLE_LOWER=$(printf '%s' "${TITLE}" | tr '[:upper:]' '[:lower:]')
    if [[ "${TITLE_LOWER}" =~ ^evidence[[:space:]]+(for|of)[[:space:]]+([\#!]) ]] || \
       [[ "${TITLE_LOWER}" =~ ^evidence: ]] || \
       [[ "${TITLE_LOWER}" =~ ^additional[[:space:]]+evidence ]]; then
      echo "::warning::proposal[$i] rejected — title matches evidence-for pattern: ${SAFE_TITLE}. Folding into summary."
      EVIDENCE_NOTES="${EVIDENCE_NOTES}
- **${TITLE}** (${TARGET_REPO}): $(jq -r ".proposals[$i].what_happened | split(\"\\n\")[0]" "${RESULT_FILE}")"
      FILTERED_COUNT=$((FILTERED_COUNT + 1))
      continue
    fi

    if [[ "${RETRO_MODE}" == "summary_only" ]]; then
      echo "Mode is summary_only — skipping issue creation for proposal[$i] (${SAFE_TITLE})"
      SUMMARY_ONLY_PROPOSALS="${SUMMARY_ONLY_PROPOSALS}
- **${TITLE}** (\`${TARGET_REPO}\`): $(jq -r ".proposals[$i].what_happened | split(\"\\n\")[0]" "${RESULT_FILE}")"
      continue
    fi

    # Allowlist gate: reject proposals targeting repos not in allowed_targets.
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      if ! is_target_allowed "${RETRO_JIRA_PROJECT}"; then
        echo "::warning::Skipping issue creation in Jira project '${RETRO_JIRA_PROJECT}' — not in ${ALLOW_TARGETS_KEY}"
        SKIPPED_TARGETS="${SKIPPED_TARGETS}
- **${TITLE}** (\`${RETRO_JIRA_PROJECT}\`)"
        continue
      fi
    else
      if ! is_target_allowed "${TARGET_REPO}"; then
        echo "::warning::Skipping issue creation in '${TARGET_REPO}' — not in ${ALLOW_TARGETS_KEY}"
        SKIPPED_TARGETS="${SKIPPED_TARGETS}
- **${TITLE}** (\`${TARGET_REPO}\`)"
        continue
      fi
    fi

    # Dedup-receipt gate: skip proposals without a well-formed duplicate-search
    # receipt. This is the enforcement for #1730 — related_issues is optional in
    # the schema (a missing/weak receipt must skip only its own proposal, not
    # fail whole-result validation and drop valid siblings and the summary), so
    # the gate validates the full receipt shape here, on both the validated and
    # fallback (no FULLSEND_VALIDATED_ITERATION_DIR) paths. The shape check is
    # exhaustive because the body builder below iterates searched and found and
    # concatenates note: a non-array searched or a non-string note would abort
    # BODY=$(...) under `set -e` mid-loop, after earlier proposals were filed.
    # Requirements: searched is an array of >= 2 distinct, non-blank strings;
    # found (if present) is an array; note (if present) is a string.
    if ! jq -e "
      .proposals[$i].related_issues as \$r |
      (\$r | type) == \"object\"
      and (\$r.searched | type) == \"array\"
      and (\$r.searched | length) >= 2
      and (\$r.searched | map(select(type == \"string\" and (gsub(\"^\\\\s+|\\\\s+\$\"; \"\") | length > 0))) | length) == (\$r.searched | length)
      and (\$r.searched | unique | length) == (\$r.searched | length)
      and ((\$r | has(\"found\") | not) or (\$r.found | type) == \"array\")
      and ((\$r | has(\"note\") | not) or (\$r.note | type) == \"string\")
    " "${RESULT_FILE}" >/dev/null 2>&1; then
      echo "::warning::proposal[$i] not filed — missing or malformed dedup receipt (related_issues.searched must be at least 2 distinct non-empty phrases). Folding into summary."
      RECEIPT_SKIPPED="${RECEIPT_SKIPPED}
- **${TITLE}** (${TARGET_REPO}): $(jq -r ".proposals[$i].what_happened | split(\"\\n\")[0]" "${RESULT_FILE}")"
      continue
    fi

    # Build the issue body from the four sections, plus the dedup receipt.
    # Numeric forge references become full URLs. On GitHub use the run's
    # server origin (GITHUB_SERVER_URL), so a GitHub Enterprise deployment
    # links to its own repos rather than github.com.
    GH_ORIGIN=""
    if [[ "${FULLSEND_FORGE}" == "github" ]]; then
      GH_ORIGIN=$(_github_server_url 2>/dev/null || echo "https://github.com")
    fi
    # Kept out of the jq program so the Jira size cap below can re-append the
    # same footer after truncating.
    BODY_FOOTER=$(printf '\n\n---\n_Generated by retro agent from %s_' "${ORIGINATING_URL}")
    BODY=$(jq -r --arg footer "${BODY_FOOTER}" --arg tracker "${FULLSEND_TRACKER}" --arg tr "${TARGET_REPO}" --arg forge "${FULLSEND_FORGE}" --arg gl_host "${GITLAB_HOST:-${CI_SERVER_HOST:-}}" --arg gh_origin "${GH_ORIGIN}" "
      .proposals[$i] |
      \"## What happened\n\n\" + .what_happened +
      \"\n\n## What could go better\n\n\" + .what_could_go_better +
      \"\n\n## Proposed change\n\n\" + .proposed_change +
      (if \$tracker == \"jira\" then \"\n\n**Target repository:** \" + \$tr else \"\" end) +
      \"\n\n## Validation criteria\n\n\" + .validation_criteria +
      \"\n\n## Related issues checked\n\nSearched: \" +
      (.related_issues.searched | join(\"; \")) +
      (if (.related_issues.found // []) | length > 0 then
        \"\nConsidered: \" + (.related_issues.found | map(
          if type == \"number\" then
            (if \$tracker == \"jira\" then
              (if \$forge == \"gitlab\" then
                (if (\$gl_host // \"\") != \"\" then \"https://\" + \$gl_host + \"/\" + \$tr + \"/-/issues/\" + tostring
                 else \$tr + \"#\" + tostring end)
               else (if \$gh_origin != \"\" then \$gh_origin else \"https://github.com\" end) + \"/\" + \$tr + \"/issues/\" + tostring end)
             else \"#\" + tostring end)
          else tostring end
        ) | join(\", \")) +
        (if .related_issues.note then \"\n\" + .related_issues.note else \"\" end)
      else
        \"\nNo overlapping issues found.\"
      end) +
      \$footer
    " "${RESULT_FILE}")

    # A body the CLI refuses is a proposal that never gets filed, so cap it at
    # the limit the CLI enforces rather than letting the create fail.
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      FITTED_BODY=$(_retro_jira_fit_body "${BODY}" "${BODY_FOOTER}")
      if [[ "${FITTED_BODY}" != "${BODY}" ]]; then
        echo "::warning::proposal[$i] body exceeded the Jira ${RETRO_JIRA_BODY_MAX_BYTES}-byte limit and was truncated (${SAFE_TITLE})"
      fi
      BODY="${FITTED_BODY}"
    fi

    # TODO(#833): Remove this warning once per-repo customization is stable.
    # Depends on: #195, #179, #419, PR #792, PR #799.
    if [[ "${TARGET_REPO}" == */.fullsend ]]; then
      echo "::warning::proposal[$i] targets a .fullsend repo (${TARGET_REPO}). Filing in .fullsend repos is discouraged until per-repo customization patterns are stable. Consider filing in the source repo or fullsend-ai/fullsend upstream instead."
    fi

    # Jira rerun protection: skip if an issue with the same summary exists.
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      if [[ "${JIRA_INIT_STATE}" != "ok" ]]; then
        echo "::warning::Jira REST access was not initialized — cannot create an issue for proposal[$i] (${SAFE_TITLE})"
        FAILED_PROPOSALS="${FAILED_PROPOSALS}
- **${TITLE}** (\`${RETRO_JIRA_PROJECT}\`)"
        continue
      fi
      if [[ "${JIRA_CREATEMETA_STATE}" == "unknown" ]]; then
        if tracker_validate_create; then
          JIRA_CREATEMETA_STATE="ok"
        else
          JIRA_CREATEMETA_STATE="failed"
        fi
      fi
      if [[ "${JIRA_CREATEMETA_STATE}" != "ok" ]]; then
        echo "::warning::Jira project validation failed for ${RETRO_JIRA_PROJECT} — cannot create issues"
        FAILED_PROPOSALS="${FAILED_PROPOSALS}
- **${TITLE}** (\`${RETRO_JIRA_PROJECT}\`)"
        continue
      fi

      # An issue this run already filed (or already found) is the one case the
      # duplicate search cannot see: /search/jql lags behind writes.
      if _retro_jira_title_seen "${TITLE}"; then
        EXISTING_URL=$(_retro_jira_title_url "${TITLE}")
        echo "Skipping proposal[$i] (${SAFE_TITLE}) — an issue with this summary was already filed or found in this run: ${EXISTING_URL}"
        EXISTING_ISSUES="${EXISTING_ISSUES}- [${TITLE}](${EXISTING_URL}) (in \`${RETRO_JIRA_PROJECT}\`)
"
        continue
      fi
      if ! EXISTING_URL=$(tracker_find_existing_issue "${TITLE}"); then
        echo "::warning::Jira duplicate check failed for proposal[$i] (${SAFE_TITLE}) — refusing to create issue"
        FAILED_PROPOSALS="${FAILED_PROPOSALS}
- **${TITLE}** (\`${RETRO_JIRA_PROJECT}\`)"
        continue
      fi
      if [[ -n "${EXISTING_URL}" ]]; then
        echo "Skipping proposal[$i] (${SAFE_TITLE}) — already exists in Jira: ${EXISTING_URL}"
        _retro_jira_record_title "${TITLE}" "${EXISTING_URL}"
        EXISTING_ISSUES="${EXISTING_ISSUES}- [${TITLE}](${EXISTING_URL}) (in \`${RETRO_JIRA_PROJECT}\`)
"
        continue
      fi
    fi

    # Ensure the label exists in the target repo before applying it.
    # Follows the same pattern as post-review.sh for ready-for-merge.
    # --force / idempotent creation makes this safe to repeat.
    if [[ "${FULLSEND_TRACKER}" != "jira" || ",${RETRO_JIRA_LABELS-ready-for-triage}," == *,ready-for-triage,* ]]; then
      forge_create_label "${TARGET_REPO}" "ready-for-triage" \
        "Triggers triage agent dispatch" "0E8A16"
    fi

    SAFE_TITLE=$(_gha_sanitize "${TITLE}")
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      echo "Filing issue in Jira ${RETRO_JIRA_PROJECT}: ${SAFE_TITLE}"
    else
      echo "Filing issue in ${TARGET_REPO}: ${SAFE_TITLE}"
    fi

    # A failed creation is non-fatal: record it, keep filing the remaining
    # proposals, and report it in the summary comment.
    CREATE_RC=0
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      ISSUE_LABELS="${RETRO_JIRA_LABELS-ready-for-triage}"
    else
      ISSUE_LABELS="ready-for-triage"
    fi
    ISSUE_URL=$(forge_create_issue "${TARGET_REPO}" "${TITLE}" "${BODY}" "${ISSUE_LABELS}") || CREATE_RC=$?
    if [[ ${CREATE_RC} -ne 0 ]]; then
      SAFE_OUTPUT=$(_gha_sanitize "${ISSUE_URL}")
      if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
        echo "::warning::Failed to create Jira issue in ${RETRO_JIRA_PROJECT} for proposal[$i] (${SAFE_TITLE}): ${SAFE_OUTPUT}"
        FAILED_PROPOSALS="${FAILED_PROPOSALS}
- **${TITLE}** (\`${RETRO_JIRA_PROJECT}\`)"
      else
        echo "::warning::Failed to create issue in ${TARGET_REPO} for proposal[$i] (${SAFE_TITLE}): ${SAFE_OUTPUT}"
        FAILED_PROPOSALS="${FAILED_PROPOSALS}
- **${TITLE}** (\`${TARGET_REPO}\`)"
      fi
      continue
    fi

    # Jira labels are applied here, in this shell, because Jira validates the
    # update against the issue edit screen: the probe behind it is cached for
    # the remaining proposals only if it runs outside the create's subshell.
    # A failed label update leaves the issue filed, so it is only a warning.
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      if ! tracker_apply_labels "${ISSUE_URL}" "${ISSUE_LABELS}"; then
        SAFE_URL=$(_gha_sanitize "${ISSUE_URL}")
        echo "::warning::Issue created but failed to apply label in Jira for proposal[$i] (${SAFE_TITLE}): ${SAFE_URL}"
      fi
    fi

    echo "Created: ${ISSUE_URL}"
    if [[ "${FULLSEND_TRACKER}" == "jira" ]]; then
      _retro_jira_record_title "${TITLE}" "${ISSUE_URL}"
      ISSUE_LINKS="${ISSUE_LINKS}- [${TITLE}](${ISSUE_URL}) (in \`${RETRO_JIRA_PROJECT}\`)
"
    else
      ISSUE_LINKS="${ISSUE_LINKS}- [${TITLE}](${ISSUE_URL}) (in \`${TARGET_REPO}\`)
"
    fi
  done
fi

# Post summary comment on the originating PR/issue.
SUMMARY=$(jq -r '.summary // empty' "${RESULT_FILE}")
if [[ -z "${SUMMARY}" ]]; then
  echo "ERROR: .summary is missing or empty in agent result" >&2
  exit 1
fi

if [[ ${FILTERED_COUNT} -gt 0 ]]; then
  echo "${FILTERED_COUNT} proposal(s) filtered (evidence-for pattern)"
fi

COMMENT="${SUMMARY}"
if [[ -n "${ISSUE_LINKS}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals filed\n\n%s' "${COMMENT}" "${ISSUE_LINKS}")
fi
if [[ -n "${EXISTING_ISSUES}" ]]; then
  # No issue was created for these: the duplicate check found an existing one,
  # or an earlier proposal in this run already filed the same summary.
  COMMENT=$(printf '%s\n\n### Already filed (existing issue)\n\nNo new issue was created for these; an issue with the same summary already exists:\n%s' "${COMMENT}" "${EXISTING_ISSUES}")
fi
if [[ -n "${SUMMARY_ONLY_PROPOSALS}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals (issue creation disabled)\n%s' "${COMMENT}" "${SUMMARY_ONLY_PROPOSALS}")
fi
if [[ -n "${FAILED_PROPOSALS}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals not filed (issue creation failed)\n\nFile manually; see the post-retro logs for the error:\n%s' "${COMMENT}" "${FAILED_PROPOSALS}")
fi
if [[ -n "${EVIDENCE_NOTES}" ]]; then
  COMMENT=$(printf '%s\n\n### Evidence notes (not filed as issues)\n%s' "${COMMENT}" "${EVIDENCE_NOTES}")
fi
if [[ -n "${SKIPPED_TARGETS}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals skipped (target repo not allowed)\n\nFile manually or update `%s` in config.yaml:\n%s' "${COMMENT}" "${ALLOW_TARGETS_KEY}" "${SKIPPED_TARGETS}")
fi
if [[ -n "${RECEIPT_SKIPPED}" ]]; then
  COMMENT=$(printf '%s\n\n### Proposals skipped (no dedup receipt)\n\nNot filed because they did not record a valid duplicate search (`related_issues`). Re-run retro, or search for duplicates and file manually:\n%s' "${COMMENT}" "${RECEIPT_SKIPPED}")
fi

if [[ "${RETRO_MODE}" != "issues_only" ]]; then
  # Truncate to the forge-specific comment limit. Jira's limit is enforced by
  # the CLI in bytes, so that path measures bytes and cuts on a code-point
  # boundary; the forge limits count characters.
  TRUNCATION_SUFFIX=$'\n\n...(truncated)'
  if [[ "${JIRA_ORIGINATING:-false}" == "true" ]]; then
    COMMENT=$(_retro_jira_fit_comment "${COMMENT}" "${TRUNCATION_SUFFIX}")
  else
    MAX_COMMENT_LEN=$(forge_get_comment_max_len)
    if [[ ${#COMMENT} -gt ${MAX_COMMENT_LEN} ]]; then
      COMMENT="${COMMENT:0:$((MAX_COMMENT_LEN - ${#TRUNCATION_SUFFIX}))}"${TRUNCATION_SUFFIX}
    fi
  fi

  echo "Posting summary comment on ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}"
  # Note: we handle 401/403 inline rather than relying on github-api-csma.sh
  # because the intent is different. CSMA retries rate-limited requests; here
  # we want graceful degradation when the token permanently lacks permission
  # to comment on a specific repo. Retrying a 403 permission error is futile.
  COMMENT_OUTPUT=""
  COMMENT_EXIT=0
  COMMENT_OUTPUT=$(forge_post_comment "${ORIGINATING_REPO}" "${ORIGINATING_NUMBER}" "${COMMENT}") || COMMENT_EXIT=$?

  if [[ ${COMMENT_EXIT} -ne 0 ]]; then
    # Treat 401/403 as non-fatal — the token lacks permission to comment on
    # this repo, but the core deliverables (analysis + proposal issues) are
    # already complete. See #2305. Match a standalone status code (not a digit
    # run, and not the -NNN suffix of an issue key) or the words the forge and
    # Jira CLIs use, since their error formats differ.
    if echo "${COMMENT_OUTPUT}" | grep -qiE '(^|[^A-Za-z0-9-])40[13]([^0-9]|$)|unauthorized|forbidden'; then
      # Sanitize before interpolating into GHA workflow command to prevent
      # injecting ::set-output or ::save-state directives via crafted responses.
      SAFE_OUTPUT=$(_gha_sanitize "${COMMENT_OUTPUT}")
      echo "::warning::Could not post summary comment to ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}: insufficient permissions (${SAFE_OUTPUT}). Skipping."
    else
      # Sanitize before echoing to prevent GHA workflow command injection.
      SAFE_OUTPUT=$(_gha_sanitize "${COMMENT_OUTPUT}")
      echo "ERROR: failed to post summary comment on ${ORIGINATING_REPO}#${ORIGINATING_NUMBER}: ${SAFE_OUTPUT}"
      exit 1
    fi
  fi
else
  echo "Mode is issues_only — skipping summary comment posting"
  if [[ -n "${FAILED_PROPOSALS}" || -n "${SKIPPED_TARGETS}" || -n "${RECEIPT_SKIPPED}" ]]; then
    echo "ERROR: issues_only mode encountered proposal failures or skipped targets without summary report" >&2
    exit 1
  fi
fi

# The context file carries the originating Jira issue text, and the harness only
# needs it while the sandbox runs. Remove it so a reused runner does not keep
# Jira content on disk between runs; pre-retro also removes any stale file at
# the start of every run.
if [[ -n "${RETRO_JIRA_CONTEXT_FILE:-}" ]]; then
  rm -f "${RETRO_JIRA_CONTEXT_FILE}" || true
fi

echo "Post-retro complete."
