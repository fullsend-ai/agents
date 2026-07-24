#!/usr/bin/env bash
# pre-critique.sh — Prepare context for the critique agent.
#
# Downloads the refine agent's result and assembles the full context
# (issue, exploration, refinement plan, prior critique history) for review.
#
# Required env vars:
#   ISSUE_KEY        — Issue identifier
#   ISSUE_SOURCE     — "jira" or "github"
#   REFINE_RUN_ID    — GitHub Actions run ID of the refine stage
#   GH_TOKEN         — GitHub token
#
# Optional env vars:
#   REVIEW_ROUND         — Current review round (default: 1)
#   MAX_REVIEW_ROUNDS    — Max rounds before escalation (default: 3)
#   GITHUB_ISSUE_NUMBER  — GitHub issue for reply-back
#   JIRA_HOST, JIRA_EMAIL, JIRA_API_TOKEN — for Jira sources
#   REPO_FULL_NAME       — for GitHub sources
#
# NOTE: This script uses pre-explore.sh for shared issue context fetching.
# That script is provided by the explore agent PR and must be present in
# the scripts/ directory.

set -euo pipefail

WORKSPACE="/tmp/workspace"
mkdir -p "$WORKSPACE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Companion resolution for harness base: composition (ADR-0045).
_resolve_companion() {
  local name="$1"
  if [[ -f "${SCRIPT_DIR}/${name}" ]]; then
    printf '%s\n' "${SCRIPT_DIR}/${name}"
    return 0
  fi
  local d
  for d in \
    "${GITHUB_WORKSPACE:+${GITHUB_WORKSPACE}/.fullsend/scripts}" \
    "${FULLSEND_DIR:+${FULLSEND_DIR}/scripts}"; do
    if [[ -n "${d}" && -f "${d}/${name}" ]]; then
      printf '%s\n' "${d}/${name}"
      return 0
    fi
  done
  echo "ERROR: companion ${name} not found next to ${BASH_SOURCE[0]} or under install .fullsend/scripts." >&2
  echo "Installs using harness base: should override pre_script/post_script locally, or vendor companions into .fullsend/scripts/." >&2
  return 1
}

REVIEW_ROUND="${REVIEW_ROUND:-1}"
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-3}"

echo "::notice::Pre-critique: preparing context (source=${ISSUE_SOURCE}, key=${ISSUE_KEY}, round=${REVIEW_ROUND}/${MAX_REVIEW_ROUNDS})"

# --- Step 1: Ensure issue context ---
if [[ ! -f "$WORKSPACE/issue-context.json" ]]; then
  if [[ -f "${SCRIPT_DIR}/pre-explore.sh" ]]; then
    echo "Fetching issue context via pre-explore.sh..."
    SKIP_REPO_CLONING=1 bash "$(_resolve_companion pre-explore.sh)"
  else
    echo "ERROR: No issue context available and pre-explore.sh not found (requires PR #11 explore agent)"
    exit 1
  fi
fi

# --- Step 2: Download refine result ---
if [[ -f "$WORKSPACE/refine-result.json" ]]; then
  echo "Refine result already present."
elif ls "$WORKSPACE"/iteration-*/output/agent-result.json 1>/dev/null 2>&1; then
  for dir in "$WORKSPACE"/iteration-*/output; do
    if [[ -f "${dir}/agent-result.json" ]]; then
      cp "${dir}/agent-result.json" "$WORKSPACE/refine-result.json"
    fi
  done
  echo "Refine result extracted from downloaded artifact."

elif [[ "${ISSUE_SOURCE}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
  echo "Looking for refine-result.json attachment on ${ISSUE_KEY}..."
  AUTH=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
  ATTACHMENT_URL=$(curl -sSf \
    -H "Authorization: Basic $AUTH" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}?fields=attachment" \
    | jq -r '.fields.attachment[] | select(.filename == "refine-result.json") | .content' \
    | head -1 2>/dev/null || true)

  if [[ -n "$ATTACHMENT_URL" ]]; then
    curl -sSfL -H "Authorization: Basic $AUTH" \
      "$ATTACHMENT_URL" > "$WORKSPACE/refine-result.json" \
      && echo "Refine result downloaded from Jira attachment." \
      || echo "::warning::Failed to download Jira attachment — trying GHA artifact fallback"
  fi

  if [[ ! -f "$WORKSPACE/exploration_context.json" ]]; then
    EXPLORE_URL=$(curl -sSf \
      -H "Authorization: Basic $AUTH" \
      -H "Accept: application/json" \
      "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}?fields=attachment" \
      | jq -r '.fields.attachment[] | select(.filename == "exploration_context.json") | .content' \
      | head -1 2>/dev/null || true)

    if [[ -n "$EXPLORE_URL" ]]; then
      if curl -sSfL -H "Authorization: Basic $AUTH" \
        "$EXPLORE_URL" > "$WORKSPACE/exploration_context.json"; then
        echo "Exploration context downloaded from Jira attachment."
      fi
    fi
  fi

  if [[ ! -f "$WORKSPACE/refine-result.json" && -n "${REFINE_RUN_ID:-}" && "${REFINE_RUN_ID}" != "N/A" ]]; then
    REPO="${REPO_FULL_NAME:-$(gh api repos/:owner/:repo --jq .full_name 2>/dev/null || echo "")}"
    if [[ -n "$REPO" ]]; then
      echo "Falling back to GHA artifact from run ${REFINE_RUN_ID}..."
      ARTIFACT_DIR=$(mktemp -d)
      if gh run download "$REFINE_RUN_ID" --repo "$REPO" --name "fullsend-refine" --dir "$ARTIFACT_DIR" 2>/dev/null; then
        REFINE_RESULT_IN_ARTIFACT=""
        for dir in "$ARTIFACT_DIR"/iteration-*/output; do
          if [[ -f "${dir}/agent-result.json" ]]; then
            REFINE_RESULT_IN_ARTIFACT="${dir}/agent-result.json"
          fi
        done

        if [[ -n "$REFINE_RESULT_IN_ARTIFACT" ]]; then
          cp "$REFINE_RESULT_IN_ARTIFACT" "$WORKSPACE/refine-result.json"
          echo "Refine result extracted from GHA artifact (fallback)."
        fi

        for f in exploration_context.json issue-context.json; do
          if [[ -f "$ARTIFACT_DIR/$f" && ! -f "$WORKSPACE/$f" ]]; then
            cp "$ARTIFACT_DIR/$f" "$WORKSPACE/$f"
          fi
        done
      else
        echo "::warning::Could not download refine artifact from run ${REFINE_RUN_ID}"
      fi
      rm -rf "$ARTIFACT_DIR"
    fi
  fi

elif [[ -n "${REFINE_RUN_ID:-}" && "${REFINE_RUN_ID}" != "N/A" ]]; then
  REPO="${REPO_FULL_NAME:-$(gh api repos/:owner/:repo --jq .full_name 2>/dev/null || echo "")}"
  if [[ -n "$REPO" ]]; then
    echo "Downloading refine artifact from run ${REFINE_RUN_ID}..."
    ARTIFACT_DIR=$(mktemp -d)
    if gh run download "$REFINE_RUN_ID" --repo "$REPO" --name "fullsend-refine" --dir "$ARTIFACT_DIR" 2>/dev/null; then
      REFINE_RESULT_IN_ARTIFACT=""
      for dir in "$ARTIFACT_DIR"/iteration-*/output; do
        if [[ -f "${dir}/agent-result.json" ]]; then
          REFINE_RESULT_IN_ARTIFACT="${dir}/agent-result.json"
        fi
      done

      if [[ -n "$REFINE_RESULT_IN_ARTIFACT" ]]; then
        cp "$REFINE_RESULT_IN_ARTIFACT" "$WORKSPACE/refine-result.json"
        echo "Refine result extracted from artifact."
      fi

      for f in exploration_context.json issue-context.json; do
        if [[ -f "$ARTIFACT_DIR/$f" && ! -f "$WORKSPACE/$f" ]]; then
          cp "$ARTIFACT_DIR/$f" "$WORKSPACE/$f"
        fi
      done
    else
      echo "::warning::Could not download refine artifact — critique will work from issue context"
    fi
    rm -rf "$ARTIFACT_DIR"
  fi
fi

if [[ ! -f "$WORKSPACE/refine-result.json" ]]; then
  echo "::warning::No refine result available — critique agent will assess the issue directly"
  jq -n \
    --arg key "$ISSUE_KEY" \
    --arg source "$ISSUE_SOURCE" \
    '{
      standalone_mode: true,
      note: "Refine stage did not run or result not found. Critique agent should review the issue directly.",
      issue_key: $key,
      issue_source: $source,
      work_items: [],
      metadata: { refine_skipped: true }
    }' > "$WORKSPACE/refine-result.json"
elif ! jq empty "$WORKSPACE/refine-result.json" 2>/dev/null; then
  echo "::error::Refine result is not valid JSON"
  exit 1
fi

# --- Step 3: Build critique history for round 2+ ---
if [[ "$REVIEW_ROUND" -gt 1 && ! -f "$WORKSPACE/critique-history.json" ]]; then
  echo "Round ${REVIEW_ROUND}: building critique history from prior rounds..."
  echo '{"rounds": [], "note": "History not available from artifact — critique agent should focus on current plan quality"}' \
    > "$WORKSPACE/critique-history.json"
fi

if [[ ! -f "$WORKSPACE/critique-history.json" ]]; then
  echo '{"rounds": []}' > "$WORKSPACE/critique-history.json"
fi

# --- Step 4: Ensure exploration context ---
if [[ ! -f "$WORKSPACE/exploration_context.json" ]]; then
  echo "::warning::No exploration context available — critique will rely on issue context and refine result"
  echo '{"gaps": [{"dimension": "exploration", "description": "Explore stage context not available to critique"}], "confidence": {"overall": 50}}' \
    > "$WORKSPACE/exploration_context.json"
fi

# --- Step 5: Load routing skill if present ---
for candidate in \
  ".fullsend/skills/jira-routing/SKILL.md" \
  ".agents/skills/project-routing/SKILL.md"; do
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
  if [[ -f "${REPO_ROOT}/${candidate}" ]]; then
    cp "${REPO_ROOT}/${candidate}" "$WORKSPACE/routing-skill.md"
    echo "PROJECT_ROUTING=$WORKSPACE/routing-skill.md" >> "${GITHUB_ENV:-/dev/null}"
    echo "::notice::Routing skill loaded for critique validation"
    break
  fi
done

# --- Step 6: Inject platform context ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
PLATFORM_CONTEXT_FILE=""
for search_root in \
  "${REPO_ROOT}/.fullsend/scripts" \
  "${SCRIPT_DIR}"; do
  case "${ISSUE_SOURCE}" in
    jira)   candidate="${search_root}/platform-jira.md" ;;
    github) candidate="${search_root}/platform-github.md" ;;
    gitlab) candidate="${search_root}/platform-gitlab.md" ;;
    *)      candidate="" ;;
  esac
  if [[ -n "$candidate" && -f "$candidate" ]]; then
    PLATFORM_CONTEXT_FILE="$candidate"
    break
  fi
done

if [[ -n "$PLATFORM_CONTEXT_FILE" ]]; then
  cp "$PLATFORM_CONTEXT_FILE" "$WORKSPACE/platform-context.md"
  echo "PLATFORM_CONTEXT=$WORKSPACE/platform-context.md" >> "${GITHUB_ENV:-/dev/null}"
  echo "::notice::Platform context loaded for critique: ${ISSUE_SOURCE}"
fi

# --- Export paths ---
{
  echo "ISSUE_CONTEXT=$WORKSPACE/issue-context.json"
  echo "EXPLORE_CONTEXT=$WORKSPACE/exploration_context.json"
  echo "REFINE_RESULT=$WORKSPACE/refine-result.json"
  echo "CRITIQUE_HISTORY=$WORKSPACE/critique-history.json"
  echo "REVIEW_ROUND=$REVIEW_ROUND"
  echo "MAX_REVIEW_ROUNDS=$MAX_REVIEW_ROUNDS"
} >> "${GITHUB_ENV:-/dev/null}"

echo "Pre-critique complete."
