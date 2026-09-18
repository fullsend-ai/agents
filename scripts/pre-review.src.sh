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

# ---------------------------------------------------------------------------
# Replace the human-readable sticky review with a mechanically validated,
# structured projection before host_files copies it into the sandbox. The
# projection is appended by post-review.sh from schema-validated findings.
# Anything missing, malformed, unauthenticated, or path-unsafe fails closed to
# an empty file, which makes the agent perform a full first-review dispatch.
# ---------------------------------------------------------------------------
validate_prior_review_projection() {
  local prior_file="$1"
  local marker encoded decoded tmp_file
  local -a markers

  tmp_file="$(mktemp "${prior_file}.validated.XXXXXX")"
  mapfile -t markers < <(grep -E '^<!-- fullsend:review-findings-v1:[A-Za-z0-9+/=]+ -->$' \
    "${prior_file}" || true)
  if [[ ${#markers[@]} -ne 1 ]]; then
    : > "${prior_file}"
    rm -f "${tmp_file}"
    echo "::warning::Prior review projection rejected — using full first-review dispatch"
    return
  fi
  marker="${markers[0]}"
  encoded="${marker#<!-- fullsend:review-findings-v1:}"
  encoded="${encoded% -->}"
  decoded="$(printf '%s' "${encoded}" | base64 --decode 2>/dev/null || true)"

  if printf '%s' "${decoded}" | jq -ce '
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
      (test("(^/|/$|//|(^|/)\\.\\.?(/|$)|[\\\\\\r\\n<>])") | not);
    if (
      type == "object" and
      ((keys - ["version", "findings"]) | length == 0) and
      .version == 1 and
      (.findings | type == "array") and
      all(.findings[];
        type == "object" and
        ((keys - ["severity", "category", "file", "line"]) | length == 0) and
        (.severity | IN("info", "low", "medium", "high", "critical")) and
        (.category | type == "string" and allowed_category) and
        (.file | safe_path) and
        (.line == null or (.line | type == "number" and . > 0 and floor == .))
      )
    ) then {
      version: 1,
      findings: [.findings[] | {
        severity: .severity,
        category: .category,
        file: .file,
        line: .line
      }]
    } else error("invalid prior review projection") end
  ' > "${tmp_file}"; then
    mv "${tmp_file}" "${prior_file}"
    echo "Prior review projection validated"
  else
    : > "${prior_file}"
    rm -f "${tmp_file}"
    echo "::warning::Prior review projection rejected — using full first-review dispatch"
  fi
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

echo "PR #${PR_NUMBER} is open — proceeding with review agent"
