#!/usr/bin/env bash
# pre-refine.sh — Prepare context for the refine agent.
#
# Fetches issue data (if not already available) and downloads/locates
# the exploration context. Priority order:
#   1. Already present in workspace (from workflow artifact download step)
#   2. User-provided reference (EXPLORE_CONTEXT_REF = repo:path, URL, or attachment name)
#   3. Jira issue attachment named "exploration_context.json" (primary for Jira flow)
#   4. GHA artifact via EXPLORE_RUN_ID (fallback / GitHub flow)
#
# Required env vars:
#   ISSUE_KEY        — Issue identifier
#   ISSUE_SOURCE     — "jira" or "github"
#   GH_TOKEN         — GitHub token
#
# Optional env vars:
#   EXPLORE_RUN_ID       — GitHub Actions run ID of the explore stage
#   EXPLORE_CONTEXT_REF  — User-provided exploration context reference
#   CRITIQUE_RUN_ID      — GitHub Actions run ID of the critique stage (revision rounds)
#   REVIEW_ROUND         — Current review round (default: 1)
#   GITHUB_ISSUE_NUMBER  — GitHub issue for reply-back (GitHub flow)
#   JIRA_HOST, JIRA_EMAIL, JIRA_API_TOKEN — for Jira sources
#   REPO_FULL_NAME       — for GitHub sources
#
# NOTE: This script uses comment-helpers.sh and pre-explore.sh for shared
# functionality. These are provided by the explore agent PR and must be
# present in the scripts/ directory.

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


# Strip GHA workflow-command metacharacters from interpolated log output.
sanitize_gha() {
  local val="$1"
  val="${val//::/}"
  val="${val//%0A/}"
  val="${val//%0a/}"
  val="${val//%0D/}"
  val="${val//%0d/}"
  printf '%s' "${val}"
}

SAFE_ISSUE_SOURCE=$(sanitize_gha "${ISSUE_SOURCE}")
SAFE_ISSUE_KEY=$(sanitize_gha "${ISSUE_KEY}")
echo "::notice::Pre-refine: preparing context (source=${SAFE_ISSUE_SOURCE}, key=${SAFE_ISSUE_KEY})"

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

# --- Step 2: Locate exploration context ---
if [[ -f "$WORKSPACE/exploration_context.json" ]]; then
  echo "Exploration context already present."

elif [[ -n "${EXPLORE_CONTEXT_REF:-}" && "${EXPLORE_CONTEXT_REF}" != "N/A" ]]; then
  echo "Fetching user-provided exploration context: ${EXPLORE_CONTEXT_REF}"

  if [[ "$EXPLORE_CONTEXT_REF" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+:.+ ]]; then
    CONTEXT_REPO="${EXPLORE_CONTEXT_REF%%:*}"
    CONTEXT_PATH="${EXPLORE_CONTEXT_REF#*:}"

    echo "  Fetching from GitHub repo: ${CONTEXT_REPO} path: ${CONTEXT_PATH}"
    gh api "repos/${CONTEXT_REPO}/contents/${CONTEXT_PATH}" \
      --jq '.content' | base64 -d > "$WORKSPACE/exploration_context.json" \
      || { echo "::error::Failed to fetch exploration context from ${CONTEXT_REPO}:${CONTEXT_PATH}"; exit 1; }

  elif [[ "$EXPLORE_CONTEXT_REF" =~ ^https?:// ]]; then
    echo "  Fetching from URL: ${EXPLORE_CONTEXT_REF}"
    curl -sSfL "$EXPLORE_CONTEXT_REF" > "$WORKSPACE/exploration_context.json" \
      || { echo "::error::Failed to fetch exploration context from URL"; exit 1; }

  elif [[ "${ISSUE_SOURCE}" == "jira" && -n "${JIRA_HOST:-}" ]]; then
    ATTACHMENT_NAME="$EXPLORE_CONTEXT_REF"
    echo "  Fetching Jira attachment: ${ATTACHMENT_NAME}"

    AUTH=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
    ATTACHMENT_URL=$(curl -sSf \
      -H "Authorization: Basic $AUTH" \
      -H "Accept: application/json" \
      "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}?fields=attachment" \
      | jq -r --arg name "$ATTACHMENT_NAME" \
        '.fields.attachment[] | select(.filename == $name) | .content' \
      | head -1)

    if [[ -z "$ATTACHMENT_URL" ]]; then
      echo "::error::Jira attachment '${ATTACHMENT_NAME}' not found on ${ISSUE_KEY}"
      exit 1
    fi

    curl -sSfL -H "Authorization: Basic $AUTH" \
      "$ATTACHMENT_URL" > "$WORKSPACE/exploration_context.json" \
      || { echo "::error::Failed to download Jira attachment"; exit 1; }

  else
    echo "::error::Cannot resolve EXPLORE_CONTEXT_REF: ${EXPLORE_CONTEXT_REF}"
    exit 1
  fi

  if ! jq empty "$WORKSPACE/exploration_context.json" 2>/dev/null; then
    echo "::error::Fetched exploration context is not valid JSON"
    exit 1
  fi

  echo "User-provided exploration context loaded."

elif [[ "${ISSUE_SOURCE}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
  echo "Looking for exploration_context.json attachment on ${ISSUE_KEY}..."
  AUTH=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
  ATTACHMENT_URL=$(curl -sSf \
    -H "Authorization: Basic $AUTH" \
    -H "Accept: application/json" \
    "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}?fields=attachment" \
    | jq -r '.fields.attachment[] | select(.filename == "exploration_context.json") | .content' \
    | head -1 2>/dev/null || true)

  if [[ -n "$ATTACHMENT_URL" ]]; then
    curl -sSfL -H "Authorization: Basic $AUTH" \
      "$ATTACHMENT_URL" > "$WORKSPACE/exploration_context.json" \
      && echo "Exploration context downloaded from Jira attachment." \
      || echo "::warning::Failed to download Jira attachment — trying GHA artifact fallback"
  fi

  if [[ ! -f "$WORKSPACE/exploration_context.json" && -n "${EXPLORE_RUN_ID:-}" && "${EXPLORE_RUN_ID}" != "N/A" ]]; then
    REPO="${REPO_FULL_NAME:-$(gh api repos/:owner/:repo --jq .full_name 2>/dev/null || echo "")}"
    if [[ -n "$REPO" ]]; then
      echo "Falling back to GHA artifact from run ${EXPLORE_RUN_ID}..."
      ARTIFACT_DIR=$(mktemp -d)
      if gh run download "$EXPLORE_RUN_ID" --repo "$REPO" --name "fullsend-explore" --dir "$ARTIFACT_DIR" 2>/dev/null; then
        if [[ -f "$ARTIFACT_DIR/exploration_context.json" ]]; then
          cp "$ARTIFACT_DIR/exploration_context.json" "$WORKSPACE/exploration_context.json"
          echo "Exploration context downloaded from GHA artifact (fallback)."
        fi
      else
        echo "::warning::Could not download exploration artifact — refine will proceed without it"
      fi
      rm -rf "$ARTIFACT_DIR"
    fi
  fi

elif [[ -n "${EXPLORE_RUN_ID:-}" && "${EXPLORE_RUN_ID}" != "N/A" ]]; then
  REPO="${REPO_FULL_NAME:-$(gh api repos/:owner/:repo --jq .full_name 2>/dev/null || echo "")}"
  if [[ -n "$REPO" ]]; then
    echo "Downloading exploration artifact from run ${EXPLORE_RUN_ID}..."
    ARTIFACT_DIR=$(mktemp -d)
    if gh run download "$EXPLORE_RUN_ID" --repo "$REPO" --name "fullsend-explore" --dir "$ARTIFACT_DIR" 2>/dev/null; then
      if [[ -f "$ARTIFACT_DIR/exploration_context.json" ]]; then
        cp "$ARTIFACT_DIR/exploration_context.json" "$WORKSPACE/exploration_context.json"
        echo "Exploration context downloaded from explore run."
      fi
    else
      echo "::warning::Could not download exploration artifact — refine will proceed without it"
    fi
    rm -rf "$ARTIFACT_DIR"
  fi
fi

if [[ ! -f "$WORKSPACE/exploration_context.json" ]]; then
  echo "::warning::No exploration context available — refine agent will rely on issue context and codebase only"
  echo '{"gaps": [{"dimension": "exploration", "description": "Explore stage did not run", "impact": "Refine agent has limited context"}], "confidence": {"overall": 50}}' \
    > "$WORKSPACE/exploration_context.json"
fi

# --- Step 3: Load critique feedback for revision rounds ---
REVIEW_ROUND="${REVIEW_ROUND:-1}"

if [[ "$REVIEW_ROUND" -gt 1 && ! -f "$WORKSPACE/critique-feedback.json" ]]; then
  echo "Revision round ${REVIEW_ROUND}: loading critique feedback..."

  if [[ "${ISSUE_SOURCE}" == "jira" && -n "${JIRA_HOST:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
    echo "Looking for critique-feedback.json attachment on ${ISSUE_KEY}..."
    CRIT_AUTH=$(printf '%s:%s' "$JIRA_EMAIL" "$JIRA_API_TOKEN" | base64 -w0)
    CRIT_ATTACHMENT_URL=$(curl -sSf \
      -H "Authorization: Basic $CRIT_AUTH" \
      -H "Accept: application/json" \
      "https://${JIRA_HOST}/rest/api/3/issue/${ISSUE_KEY}?fields=attachment" \
      | jq -r '.fields.attachment[] | select(.filename == "critique-feedback.json") | .content' \
      | head -1 2>/dev/null || true)

    if [[ -n "$CRIT_ATTACHMENT_URL" ]]; then
      curl -sSfL -H "Authorization: Basic $CRIT_AUTH" \
        "$CRIT_ATTACHMENT_URL" > "$WORKSPACE/critique-feedback.json" \
        && echo "Critique feedback downloaded from Jira attachment." \
        || echo "::warning::Failed to download critique-feedback.json from Jira"
    fi
  fi

  if [[ ! -f "$WORKSPACE/critique-feedback.json" && -n "${CRITIQUE_RUN_ID:-}" && "${CRITIQUE_RUN_ID}" != "N/A" ]]; then
    REPO="${REPO_FULL_NAME:-$(gh api repos/:owner/:repo --jq .full_name 2>/dev/null || echo "")}"
    if [[ -n "$REPO" ]]; then
      echo "Falling back to GHA artifact from critique run ${CRITIQUE_RUN_ID}..."
      ARTIFACT_DIR=$(mktemp -d)
      if gh run download "$CRITIQUE_RUN_ID" --repo "$REPO" --name "fullsend-critique" --dir "$ARTIFACT_DIR" 2>/dev/null; then
        CRITIQUE_RESULT_IN_ARTIFACT=""
        for dir in "$ARTIFACT_DIR"/iteration-*/output; do
          if [[ -f "${dir}/agent-result.json" ]]; then
            CRITIQUE_RESULT_IN_ARTIFACT="${dir}/agent-result.json"
          fi
        done

        if [[ -n "$CRITIQUE_RESULT_IN_ARTIFACT" ]]; then
          cp "$CRITIQUE_RESULT_IN_ARTIFACT" "$WORKSPACE/critique-feedback.json"
          echo "Critique feedback loaded from GHA artifact."
        fi

        for f in critique-history.json exploration_context.json issue-context.json; do
          if [[ -f "$ARTIFACT_DIR/$f" && ! -f "$WORKSPACE/$f" ]]; then
            cp "$ARTIFACT_DIR/$f" "$WORKSPACE/$f"
          fi
        done
      else
        echo "::warning::Could not download critique artifact — refine will proceed without feedback"
      fi
      rm -rf "$ARTIFACT_DIR"
    fi
  fi

  if [[ ! -f "$WORKSPACE/critique-feedback.json" ]]; then
    echo "::warning::No critique feedback found — refine will proceed without revision guidance"
  fi

elif [[ -f "$WORKSPACE/critique-feedback.json" ]]; then
  echo "Critique feedback already present from artifact download."
fi

# --- Step 4: Load routing skill if present ---
# Look in the deploying repo's .fullsend directory for a routing skill.
# This is org/repo-specific and injected via harness base: composition.
ROUTING_SKILL=""
for candidate in \
  ".fullsend/customized/skills/jira-routing/SKILL.md" \
  ".fullsend/skills/jira-routing/SKILL.md" \
  ".agents/skills/project-routing/SKILL.md"; do
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
  if [[ -f "${REPO_ROOT}/${candidate}" ]]; then
    ROUTING_SKILL="${REPO_ROOT}/${candidate}"
    break
  fi
done

if [[ -n "$ROUTING_SKILL" ]]; then
  cp "$ROUTING_SKILL" "$WORKSPACE/routing-skill.md"
  echo "PROJECT_ROUTING=$WORKSPACE/routing-skill.md" >> "${GITHUB_ENV:-/dev/null}"
  echo "::notice::Routing skill loaded from ${ROUTING_SKILL}"
else
  echo "No routing skill found — children will be created in the parent's project"
fi

# --- Step 5: Inject platform context ---
PLATFORM_CONTEXT_FILE=""
for search_root in \
  "$(git rev-parse --show-toplevel 2>/dev/null || echo ".")/.fullsend/customized/scripts" \
  "$(git rev-parse --show-toplevel 2>/dev/null || echo ".")/.fullsend/scripts" \
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
  echo "::notice::Platform context loaded: ${ISSUE_SOURCE}"
else
  echo "::warning::No platform context template found for source=${ISSUE_SOURCE}"
fi

{
  echo "ISSUE_CONTEXT=$WORKSPACE/issue-context.json"
  echo "EXPLORE_CONTEXT=$WORKSPACE/exploration_context.json"
  echo "REVIEW_ROUND=$REVIEW_ROUND"
} >> "${GITHUB_ENV:-/dev/null}"

if [[ -n "${HUMAN_DIRECTIVE:-}" ]]; then
  echo "$HUMAN_DIRECTIVE" > "$WORKSPACE/human-directive.txt"
  echo "HUMAN_DIRECTIVE_FILE=$WORKSPACE/human-directive.txt" >> "${GITHUB_ENV:-/dev/null}"
  SAFE_DIRECTIVE=$(sanitize_gha "${HUMAN_DIRECTIVE:0:100}")
  echo "::notice::Human directive received: ${SAFE_DIRECTIVE}..."
fi

if [[ -f "$WORKSPACE/critique-feedback.json" ]]; then
  echo "CRITIQUE_FEEDBACK=$WORKSPACE/critique-feedback.json" >> "${GITHUB_ENV:-/dev/null}"
fi

echo "Pre-refine complete."
