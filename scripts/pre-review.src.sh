#!/usr/bin/env bash
# pre-review.sh — Validate review inputs before the agent runs.
#
# Runs on the host via the harness pre_script mechanism.
#
# Required environment variables (set by the harness forge section):
#   PR_URL         — HTML URL of the PR/MR
#   FULLSEND_FORGE — "github" or "gitlab"
#
# Optional environment variables:
#   REVIEW_TOKEN        — token for PR state checks and comments
#   REVIEW_SKIP_AUTHORS — comma-separated author list to skip
#   PRIOR_REVIEW_FILE   — prior sticky review body; rewritten to validated JSON
#   PRIOR_REVIEW_PROVENANCE — authenticated provenance for the prior review
set -euo pipefail

: "${PR_URL:?PR_URL must be set}"
: "${FULLSEND_FORGE:?FULLSEND_FORGE must be set}"

# shellcheck disable=SC2034 # SCRIPT_DIR used by source in .src.sh; unused in bundled .sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/review-ops.lib.sh
source "${SCRIPT_DIR}/lib/review-ops.lib.sh"

forge_validate_pr_url
echo "::notice::🔗 Review target: $(_gha_sanitize "${PR_URL}")"
forge_parse_pr_url

echo "Input validation passed:"
echo "  PR_NUMBER=${PR_NUMBER}"
echo "  REPO=${REPO}"
echo "  PR_URL=${PR_URL}"

# Assign opaque ids to prior findings that predate the ledger, before the
# sandbox reads this file. Same mint as post-review: f_ plus 16 hex chars
# from /dev/urandom. Existing valid ids are left alone.
mint_missing_prior_ids() {
  local prior_file="$1"
  local missing mint_ids tmp
  missing="$(jq '[.findings[] | select(.id == null)] | length' "${prior_file}")"
  if [[ ! "${missing}" =~ ^[1-9][0-9]*$ ]]; then
    return 0
  fi
  mint_ids="$(
    od -An -N"$((missing * 8))" -tx1 /dev/urandom | tr -d ' \n' | fold -w16 | head -n "${missing}" | sed 's/^/f_/' \
      | jq -R . | jq -sc .
  )"
  tmp="$(mktemp "${prior_file}.mint.XXXXXX")"
  if jq -ce --argjson mints "${mint_ids}" '
    def valid_id: type == "string" and test("^f_[A-Za-z0-9]+$");
    .findings = (
      reduce .findings[] as $f ({out:[], i:0};
        if ($f.id | valid_id) then .out += [$f]
        elif ($mints[.i] | valid_id | not) then error("ran out of finding ids")
        else .out += [$f + {id: $mints[.i]}] | .i += 1
        end
      ) | .out
    )
  ' "${prior_file}" > "${tmp}"; then
    mv "${tmp}" "${prior_file}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# ---------------------------------------------------------------------------
# Replace the human-readable sticky review with a mechanically validated,
# structured projection before host_files copies it into the sandbox. The
# projection is appended by post-review.sh from schema-validated findings.
# Anything missing, malformed, unauthenticated, or projection-invalid fails closed to
# an empty file, which makes the agent perform a full first-review dispatch.
# ---------------------------------------------------------------------------
validate_prior_review_projection() {
  local prior_file="$1"
  local marker marker_version encoded decoded tmp_file
  local -a markers

  tmp_file="$(mktemp "${prior_file}.validated.XXXXXX")"
  # The poster preserves old markers in sticky history. Only the current
  # section can describe the reviewed SHA; history is never a fallback.
  # Comments edited on the forge can come back with CRLF line endings.
  mapfile -t markers < <(awk '/<!-- sticky:history-start -->/{exit} {sub(/\r$/, ""); print}' \
    "${prior_file}" \
    | grep -E '^<!-- fullsend:review-findings-v[12]:[A-Za-z0-9+/=]+ -->$' || true)
  if [[ ${#markers[@]} -ne 1 ]]; then
    : > "${prior_file}"
    rm -f "${tmp_file}"
    echo "::warning::Prior review projection rejected — using full first-review dispatch"
    return
  fi
  marker="${markers[0]}"
  marker_version="${marker#<!-- fullsend:review-findings-v}"
  marker_version="${marker_version%%:*}"
  encoded="${marker#<!-- fullsend:review-findings-v"${marker_version}":}"
  encoded="${encoded% -->}"
  decoded="$(printf '%s' "${encoded}" | base64 --decode 2>/dev/null || true)"

  if printf '%s' "${decoded}" | jq -ce --argjson marker_version "${marker_version}" '
    def allowed_category:
      IN(
        "logic-error", "nil-deref", "off-by-one", "edge-case", "api-contract", "missing-test", "test-inadequate", "pattern-violation", "test-weakened", "test-removed", "mock-loosened", "assertion-weakened", "coverage-reduced", "test-poisoning", "split-payload", "stale-reference",
        "auth-bypass", "rbac-violation", "data-exposure", "privilege-escalation", "injection-vuln", "sandbox-escape", "xss", "ssrf", "insecure-deserialization", "prompt-injection", "unicode-steganography", "bidi-override", "homoglyph-attack", "instruction-smuggling", "fail-open", "permission-expansion", "permission-reduction", "role-escalation", "workflow-permission", "secret-exposure",
        "scope-exceeded", "tier-mismatch", "unauthorized-change", "scope-creep", "missing-authorization", "misleading-label", "design-direction", "complexity-ratio", "misplaced-abstraction", "architectural-conflict", "design-smell", "over-engineering", "under-engineering",
        "naming-convention", "error-handling-idiom", "api-shape", "code-organization", "doc-style", "pattern-inconsistency",
        "stale-doc", "missing-doc", "incorrect-doc", "incomplete-doc",
        "breaking-api", "breaking-schema", "breaking-config", "breaking-cli", "missing-deprecation", "missing-version-bump", "backward-incompatible"
      );
    def safe_path:
      type == "string" and length > 0 and . != "N/A" and
      test("^[ -~]+$") and
      (test("(^/|/$|//|(^|/)\\.\\.?(/|$)|[\\\\\\r\\n<>])") | not);
    .version as $projection_version
    | if (
      type == "object" and
      ((keys - ["version", "findings", "dispositions"]) | length == 0) and
      (.version | IN(1, 2)) and
      .version == $marker_version and
      (.findings | type == "array") and
      all(.findings[];
        type == "object" and
        ((keys - ["severity", "category", "file", "line", "id"]) | length == 0) and
        (.severity | IN("info", "low", "medium", "high", "critical")) and
        (.category | type == "string" and allowed_category) and
        ((.file == null and $projection_version == 2) or (.file | safe_path)) and
        (.line == null or (.line | type == "number" and . > 0 and floor == .)) and
        (.id == null or (.id | type == "string" and test("^f_[A-Za-z0-9]+$")))
      ) and
      ([.findings[].id | select(. != null)] | length == (unique | length)) and
      (.dispositions == null or (
        (.dispositions | type == "array") and
        all(.dispositions[];
          type == "object" and
          ((keys - ["id", "status"]) | length == 0) and
          (.id | type == "string" and test("^f_[A-Za-z0-9]+$")) and
          (.status | IN("open", "resolved_by_change", "reclassified", "dismissed_by_human"))
        ) and
        ([.dispositions[].id] | length == (unique | length))
      ))
    ) then {
      version: $projection_version,
      findings: [.findings[] | {
        severity: .severity,
        category: .category,
        file: .file,
        line: .line
      } + (if .id == null then {} else {id: .id} end)]
    } + (if .dispositions == null then {} else {
      dispositions: [.dispositions[] | {id, status}]
    } end) else error("invalid prior review projection") end
  ' > "${tmp_file}"; then
    # Legacy findings (v1 / v2 without id) get an opaque id before the
    # sandbox so this review can write a disposition for them.
    if mint_missing_prior_ids "${tmp_file}"; then
      mv "${tmp_file}" "${prior_file}"
      echo "Prior review projection validated"
    else
      : > "${prior_file}"
      rm -f "${tmp_file}"
      echo "::warning::Prior review projection rejected — using full first-review dispatch"
    fi
  else
    : > "${prior_file}"
    rm -f "${tmp_file}"
    echo "::warning::Prior review projection rejected — using full first-review dispatch"
  fi
}

# Fetch resolved review threads for the final pre-sandbox authorization step
# and reduce them to exact finding ids eligible for human dismissal. Raw
# comment text is used only on the host to extract finding-id stamps and is
# never persisted or copied into the sandbox.
fetch_human_dismissals() {
  local pr_author response trusted_reviewers
  local -a fetch_args

  pr_author="$(forge_get_pr_author)"
  if [[ -z "${pr_author}" ]]; then
    echo "::warning::Could not determine the PR author — human dismissals cannot be verified" >&2
    echo '[]'
    return 0
  fi

  case "${FULLSEND_FORGE}" in
    github)
      local org app_set
      org="${REPO%%/*}"
      app_set="${FULLSEND_APP_SET:-}"
      trusted_reviewers="$(jq -nc \
        --arg org "${org}" \
        --arg app_set "${app_set}" '
          [
            ($org + "-review"), ($org + "-review[bot]"),
            "fullsend-ai-review", "fullsend-ai-review[bot]",
            (if $app_set == "" then empty else ($app_set + "-review"), ($app_set + "-review[bot]") end)
          ] | unique
        ')"
      ;;
    gitlab)
      local review_actor
      review_actor="$(_gitlab_api GET "/user" 2>/dev/null | jq -r '.username // empty' 2>/dev/null)" || review_actor=""
      if [[ -z "${review_actor}" ]]; then
        echo "::warning::Could not determine the GitLab review bot — human dismissals cannot be verified" >&2
        echo '[]'
        return 0
      fi
      trusted_reviewers="$(jq -nc --arg actor "${review_actor}" '[$actor]')"
      ;;
  esac

  fetch_args=(fetch-review-threads --forge "${FULLSEND_FORGE}" --repo "${REPO}" --pr "${PR_NUMBER}")
  if [[ "${FULLSEND_FORGE}" == "gitlab" && -n "${CI_SERVER_URL:-}" ]]; then
    fetch_args+=(--base-url "${CI_SERVER_URL}")
  fi
  if ! response="$(GH_TOKEN="${REVIEW_TOKEN:-${GH_TOKEN:-}}" \
    GITLAB_TOKEN="${REVIEW_TOKEN:-${GITLAB_TOKEN:-}}" \
    fullsend "${fetch_args[@]}" 2>/dev/null)"; then
    echo "::warning::Failed to fetch review threads — human dismissals cannot be verified" >&2
    echo '[]'
    return 0
  fi

  if ! jq -e 'type == "object" and (.threads | type == "array") and (.truncated == false)' \
    <<< "${response}" >/dev/null 2>&1; then
    echo "::warning::Review thread fetch was invalid or truncated — human dismissals cannot be verified" >&2
    echo '[]'
    return 0
  fi

  jq -c --arg author "${pr_author}" --arg forge "${FULLSEND_FORGE}" --argjson trusted "${trusted_reviewers}" '
    [ .threads[]
      | select(type == "object")
      | select(.is_resolved == true)
      | select(.resolved_by_type == "User")
      | select(.resolved_by_role_verified == true)
      | select(.resolved_by_role | IN("write", "maintain", "admin"))
      | select((.resolved_by | ascii_downcase) != ($author | ascii_downcase))
      | select(.comments_truncated == false)
      | .comments[]?
      | select(
          if $forge == "github" then
            (.author_type == "Bot") and
            (.author as $login | ($trusted | map(ascii_downcase) | index($login | ascii_downcase)) != null)
          else
            (.author as $login | ($trusted | map(ascii_downcase) | index($login | ascii_downcase)) != null)
          end
        )
      | .body
      | scan("<!--[[:space:]]+finding:(f_[A-Za-z0-9]+)[[:space:]]+-->")
      | .[0]
    ] | unique
  ' <<< "${response}" 2>/dev/null || echo '[]'
}

# Close eligible prior findings before the model sees the ledger. Only exact
# stamped ids are authoritative. High and critical findings remain open.
apply_human_dismissals() {
  local prior_file="$1"
  local dismissals tmp_file

  [[ -s "${prior_file}" ]] || return 0
  dismissals="$(fetch_human_dismissals)" || dismissals='[]'
  if ! jq -e 'type == "array"' <<< "${dismissals}" >/dev/null 2>&1; then
    dismissals='[]'
  fi

  tmp_file="$(mktemp "${prior_file}.dismissals.XXXXXX")"
  if ! jq --argjson dismissals "${dismissals}" '
    def valid_id: type == "string" and test("^f_[A-Za-z0-9]+$");
    def closed_status: IN("resolved_by_change", "dismissed_by_human");
    ([.dispositions[]? | select(.status | closed_status) | .id]) as $closed
    | ([.findings[] | select((.id | valid_id) and (.id as $id | $closed | index($id) == null))]) as $open
    | ([ $open[]
         | . as $finding
         | select((.severity | IN("high", "critical")) | not)
         | select($dismissals | index($finding.id) != null)
         | {id: .id, status: "dismissed_by_human"}
       ]) as $new
    | if ($new | length) == 0 then .
      else .dispositions = ([.dispositions[]? | select(.id as $id | any($new[]; .id == $id) | not)] + $new)
      end
  ' "${prior_file}" > "${tmp_file}"; then
    rm -f "${tmp_file}"
    echo "::warning::Human-dismissal matching failed — keeping prior dispositions unchanged"
    return 0
  fi

  mv "${tmp_file}" "${prior_file}"
}

if [[ -n "${PRIOR_REVIEW_FILE:-}" && -f "${PRIOR_REVIEW_FILE}" ]]; then
  case "${PRIOR_REVIEW_PROVENANCE:-none}" in
    app-verified|bot-verified) validate_prior_review_projection "${PRIOR_REVIEW_FILE}" ;;
    *) : > "${PRIOR_REVIEW_FILE}" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Check PR state — skip review on merged or closed PRs
# ---------------------------------------------------------------------------
if [[ -z "${REVIEW_TOKEN:-}" ]]; then
  echo "No token available — skipping PR state check"
  exit 0
fi

PR_STATE="$(forge_get_pr_state)"

if [[ -n "${PR_STATE}" && "${PR_STATE}" != "OPEN" ]]; then
  echo "::notice::PR #${PR_NUMBER} is ${PR_STATE} — skipping review"

  STATE_LOWER="$(echo "${PR_STATE}" | tr '[:upper:]' '[:lower:]')"
  COMMENT_BODY="Review skipped — this PR is already **${STATE_LOWER}**.

The \`/fs-review\` command only reviews open PRs/MRs.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> pre-review check</sub>"

  forge_post_comment "${COMMENT_BODY}" 2>/dev/null || true

  exit 0
fi

# ---------------------------------------------------------------------------
# Check author skip list — exit early if PR author is in REVIEW_SKIP_AUTHORS
# ---------------------------------------------------------------------------
if [[ -n "${REVIEW_SKIP_AUTHORS:-}" ]]; then
  PR_AUTHOR="$(forge_get_pr_author)"

  if [[ -n "${PR_AUTHOR}" ]]; then
    IFS=',' read -ra _SKIP_LIST <<< "${REVIEW_SKIP_AUTHORS}"
    for _entry in "${_SKIP_LIST[@]}"; do
      read -r _entry <<< "${_entry}"  # trim whitespace
      if [[ "${_entry,,}" == "${PR_AUTHOR,,}" ]]; then
        _SAFE_AUTHOR="$(_gha_sanitize "${PR_AUTHOR}")"
        echo "::notice::PR #${PR_NUMBER} authored by ${_SAFE_AUTHOR} — skipping review (REVIEW_SKIP_AUTHORS)"

        COMMENT_BODY="Review skipped — PR author **${PR_AUTHOR}** is in the \`REVIEW_SKIP_AUTHORS\` list.

<sub>Posted by <a href=\"https://github.com/fullsend-ai/fullsend\">fullsend</a> pre-review check</sub>"

        forge_post_comment "${COMMENT_BODY}" 2>/dev/null || true

        exit 0
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# Deepen shallow clone for git history analysis (risk assessment Tier 2).
# When REVIEW_GIT_FETCH_DEPTH is unset, default to "0" (full unshallow) if
# risk assessment is enabled — the Tier 2 sub-agent needs full git history.
# Explicit values always take precedence.
# ---------------------------------------------------------------------------
if [[ -z "${REVIEW_GIT_FETCH_DEPTH+set}" && "${REVIEW_RISK_ASSESSMENT_ENABLED:-false}" == "true" ]]; then
  REVIEW_GIT_FETCH_DEPTH="0"
fi
if [[ "${REVIEW_GIT_FETCH_DEPTH:-}" == "0" ]]; then
  _TARGET_DIR="${REPO_DIR:-${GITHUB_WORKSPACE:-.}/target-repo}"
  if [[ ! -d "${_TARGET_DIR}" ]]; then
    echo "::warning::Clone-deepening skipped — target directory '${_TARGET_DIR}' not found"
  elif git -C "${_TARGET_DIR}" rev-parse --is-shallow-repository 2>/dev/null | grep -q true; then
    echo "Deepening shallow clone for git history analysis..."
    if [[ "${FULLSEND_FORGE}" == "github" && -n "${GH_TOKEN:-}" && -n "${REPO_FULL_NAME:-}" ]]; then
      git -C "${_TARGET_DIR}" \
        -c "http.extraheader=Authorization: basic $(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 -w0)" \
        fetch --unshallow "https://github.com/${REPO_FULL_NAME}.git" 2>/dev/null \
        && echo "Clone deepened successfully" \
        || echo "::warning::Failed to deepen clone — Tier 2 risk signals may be degraded"
    else
      echo "::warning::Cannot deepen clone — missing credentials or unsupported forge"
    fi
  fi
fi

# Fetch and apply current human-dismissal evidence only after all early exits
# and immediately before the validated ledger is copied into the sandbox.
if [[ -n "${PRIOR_REVIEW_FILE:-}" && -f "${PRIOR_REVIEW_FILE}" ]]; then
  case "${PRIOR_REVIEW_PROVENANCE:-none}" in
    app-verified|bot-verified) apply_human_dismissals "${PRIOR_REVIEW_FILE}" ;;
  esac
fi

echo "PR #${PR_NUMBER} is open — proceeding with review agent"
