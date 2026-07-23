#!/usr/bin/env bash
# CLI runner command for the eval harness.
#
# Called by the harness as the runner.command. Setup and teardown are
# handled by before_each/after_each hooks — this script just runs
# fullsend with the right env vars.
#
# Args (from harness placeholders):
#   $1 — agent name (e.g., "triage")
#   $2 — workspace path (case workspace)
#   $3 — output directory
#
# Required env (injected by harness from hook outputs + execution.env):
#   FULLSEND_DIR    — path to the fullsend scaffold directory
#   GH_TOKEN        — GitHub token
#   FIXTURE_URL     — URL of the fixture (issue or PR)
#   FIXTURE_TYPE    — "issue" or "pull_request"
set -euo pipefail

AGENT="${1:?agent name required}"
# $2 is the workspace path (passed by harness, unused here)
OUTPUT_DIR="${3:?output dir required}"

FULLSEND_DIR="$(cd "${FULLSEND_DIR:?FULLSEND_DIR is required}" && pwd)"
FIXTURE_URL="${FIXTURE_URL:?FIXTURE_URL is required (set by before_each hook)}"
FIXTURE_TYPE="${FIXTURE_TYPE:?FIXTURE_TYPE is required (set by before_each hook)}"

# Clone the ephemeral repo as the target for fullsend run.
# The hook already created it and pushed content.
#
# Layout mirrors GHA for code/fix: harness expands
# REPO_DIR=${GITHUB_WORKSPACE}/target-repo for post-scripts.
EPHEMERAL_REPO="${EPHEMERAL_REPO:?EPHEMERAL_REPO is required}"
FIXTURE_NUMBER="${FIXTURE_NUMBER:?FIXTURE_NUMBER is required (set by before_each hook)}"

# Shape checks for fixture-derived values — before clone / dotenv writes.
if [[ ! "$FIXTURE_URL" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/(issues|pull)/[0-9]+$ ]]; then
  echo "ERROR: FIXTURE_URL has unexpected shape: ${FIXTURE_URL}" >&2
  exit 1
fi
if [[ ! "$FIXTURE_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: FIXTURE_NUMBER must be a positive integer, got: ${FIXTURE_NUMBER}" >&2
  exit 1
fi
if [[ ! "$EPHEMERAL_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: EPHEMERAL_REPO must be owner/repo, got: ${EPHEMERAL_REPO}" >&2
  exit 1
fi

EVAL_GH_WORKSPACE=$(mktemp -d)
TARGET_DIR="${EVAL_GH_WORKSPACE}/target-repo"
GH_CRED_HELPER='!f(){ echo "password=${GH_TOKEN}"; };f'
git -c "credential.helper=${GH_CRED_HELPER}" \
  clone "https://x-access-token@github.com/${EPHEMERAL_REPO}.git" "$TARGET_DIR"
git -C "$TARGET_DIR" config credential.helper "${GH_CRED_HELPER}"

# Fix must run on the PR's actual head branch (post-script pushes
# `git branch --show-current`). A local alias like eval-pr-head would push a
# *new* remote branch and leave the PR head unchanged — failing new_commit.
# Do not switch other PR-fixture agents (e.g. review) off main.
if [[ "$AGENT" == "fix" && "$FIXTURE_TYPE" == "pull_request" ]]; then
  HEAD_REF=""
  for attempt in 1 2 3; do
    if [[ $attempt -lt 3 ]]; then
      # Suppress stderr on early attempts (expected to be noisy/flaky);
      # let the final attempt's stderr through so the real gh error is
      # visible in logs instead of being swallowed entirely.
      if HEAD_REF=$(gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" \
        --json headRefName --jq '.headRefName' 2>/dev/null); then
        break
      fi
      sleep $((attempt))
    elif HEAD_REF=$(gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" \
      --json headRefName --jq '.headRefName'); then
      break
    fi
  done
  if [[ -z "$HEAD_REF" ]]; then
    echo "ERROR: gh pr view failed for headRefName after retries (PR #${FIXTURE_NUMBER}); see gh error above" >&2
    exit 1
  fi
  if [[ ! "$HEAD_REF" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "ERROR: unexpected PR head ref: ${HEAD_REF}" >&2
    exit 1
  fi
  git -C "$TARGET_DIR" fetch origin "pull/${FIXTURE_NUMBER}/head:${HEAD_REF}"
  git -C "$TARGET_DIR" checkout "$HEAD_REF"
fi
PRE_AGENT_HEAD="$(git -C "$TARGET_DIR" rev-parse HEAD)"
export PRE_AGENT_HEAD

REVIEW_BODY_FILE=""
cleanup() {
  # shellcheck disable=SC2317 # invoked indirectly via trap
  [[ -n "${ENV_FILE:-}" ]] && rm -f "$ENV_FILE"
  # shellcheck disable=SC2317
  [[ -n "${REVIEW_BODY_FILE:-}" && -f "${REVIEW_BODY_FILE:-}" ]] && rm -f "$REVIEW_BODY_FILE"
  # shellcheck disable=SC2317
  [[ -n "${EVAL_GH_WORKSPACE:-}" && -d "${EVAL_GH_WORKSPACE:-}" ]] && rm -rf "$EVAL_GH_WORKSPACE"
}
trap cleanup EXIT

# Reject newline/CR injection into the dotenv file (defense in depth).
# Values today come from gh/mktemp; still validate shape before writing.
# Quote values so envfile.go does not treat " #" as an inline comment
# (unquoted values strip from space-hash onward).
#
# Dotenv format contract: NAME="value" lines, one per line, consumed by
# fullsend's Go dotenv parser via --env-file (internal/*/envfile.go) — NOT
# sourced by any shell. Escaping only needs to satisfy that parser's quoted-
# string rules (backslash, double-quote, dollar-sign, backtick), not bash's;
# characters with special meaning only to an interactive shell (e.g. `!`
# history expansion) are not escaped here because they are never evaluated
# by a shell.
emit_env() {
  local name="$1" value="$2"
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: invalid env name: ${name}" >&2
    exit 1
  fi
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "ERROR: env value for ${name} contains a newline" >&2
    exit 1
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  printf '%s="%s"\n' "$name" "$value"
}

# Build env file for fullsend run
ENV_FILE="${OUTPUT_DIR}/.eval-env"
install -m 0600 /dev/null "$ENV_FILE"
{
  emit_env "GH_TOKEN" "${GH_TOKEN}"
  emit_env "PUSH_TOKEN" "${GH_TOKEN}"
  emit_env "REVIEW_TOKEN" "${GH_TOKEN}"

  # Code/fix harness runner_env refs — mint normally sets these; eval skips mint.
  # Only override GITHUB_WORKSPACE for agents whose post-scripts expand
  # REPO_DIR=${GITHUB_WORKSPACE}/target-repo (triage reads config.yaml from
  # the real Actions workspace and must not be redirected to the temp clone).
  case "$AGENT" in
    code|fix)
      emit_env "PUSH_TOKEN_SOURCE" "eval"
      # Empty matches production reusable-code.yml: post-code.sh treats unset/empty
      # as fallback to the repo default branch (not "allow all"; use * for any).
      emit_env "CODE_ALLOWED_TARGET_BRANCHES" ""
      emit_env "GITHUB_WORKSPACE" "${EVAL_GH_WORKSPACE}"
      emit_env "GIT_BOT_EMAIL" "fullsend-eval[bot]@users.noreply.github.com"
      ;;
  esac

  case "$FIXTURE_TYPE" in
    issue)
      emit_env "GITHUB_ISSUE_URL" "${FIXTURE_URL}"
      # Code (and other issue-driven agents) require these explicitly;
      # triage derives them inside its pre-script from GITHUB_ISSUE_URL alone.
      emit_env "ISSUE_NUMBER" "${FIXTURE_NUMBER}"
      emit_env "REPO_FULL_NAME" "${EPHEMERAL_REPO}"
      ;;
    pull_request)
      emit_env "GITHUB_PR_URL" "${FIXTURE_URL}"
      emit_env "PR_NUMBER" "${FIXTURE_NUMBER}"
      emit_env "REPO_FULL_NAME" "${EPHEMERAL_REPO}"
      ;;
  esac

  if [[ "$AGENT" == "fix" ]]; then
    # HUMAN_INSTRUCTION comes from case input.yaml via setup-fixture hook-outputs.
    # TRIGGER_SOURCE / FIX_ITERATION / TARGET_BRANCH below are hardcoded for the
    # v1 human /fs-fix scenario; move them into case input.yaml (like
    # human_instruction) if/when a second fix scenario needs different values.
    if [[ -z "${HUMAN_INSTRUCTION:-}" ]]; then
      echo "ERROR: HUMAN_INSTRUCTION is required for fix eval (set human_instruction in input.yaml)" >&2
      exit 1
    fi
    # mktemp already creates an empty file (human /fs-fix path; no review body).
    REVIEW_BODY_FILE="$(mktemp)"
    emit_env "TRIGGER_SOURCE" "eval-human"
    emit_env "HUMAN_INSTRUCTION" "${HUMAN_INSTRUCTION}"
    emit_env "FIX_ITERATION" "1"
    emit_env "TARGET_BRANCH" "main"
    emit_env "PRE_AGENT_HEAD" "${PRE_AGENT_HEAD}"
    emit_env "REVIEW_BODY_FILE" "${REVIEW_BODY_FILE}"
  fi

  [[ -n "${ANTHROPIC_VERTEX_PROJECT_ID:-}" ]] && emit_env "ANTHROPIC_VERTEX_PROJECT_ID" "${ANTHROPIC_VERTEX_PROJECT_ID}"
  [[ -n "${GOOGLE_CLOUD_PROJECT:-}" ]]        && emit_env "GOOGLE_CLOUD_PROJECT" "${GOOGLE_CLOUD_PROJECT}"
  [[ -n "${CLOUD_ML_REGION:-}" ]]             && emit_env "CLOUD_ML_REGION" "${CLOUD_ML_REGION}"
  [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]] && emit_env "GOOGLE_APPLICATION_CREDENTIALS" "${GOOGLE_APPLICATION_CREDENTIALS}"
} > "$ENV_FILE"

FULLSEND_BIN="$(command -v fullsend)"
EVAL_TIMEOUT="${EVAL_TIMEOUT:-1800}"

mkdir -p "$OUTPUT_DIR"
printf '%s\n' "$PRE_AGENT_HEAD" > "${OUTPUT_DIR}/pre-agent-head.txt"

rc=0
timeout "$EVAL_TIMEOUT" fullsend run "$AGENT" \
  --fullsend-dir "${FULLSEND_DIR}" \
  --target-repo "$TARGET_DIR" \
  --env-file "$ENV_FILE" \
  --output-dir "$OUTPUT_DIR" \
  --fullsend-binary "$FULLSEND_BIN" \
  || rc=$?

if [[ $rc -ne 0 ]]; then
  echo "WARNING: fullsend run exited with status $rc" >&2
fi

# Remove env file to prevent secrets from being uploaded as artifacts
rm -f "$ENV_FILE"

# Copy metrics.json to the output root so score.py can find it.
# OUTPUT_DIR is {output_dir} from the harness, which is workspace/output.
# score.py loads files relative to case_dir/output, so metrics.json needs
# to be at OUTPUT_DIR/metrics.json (not OUTPUT_DIR/output/metrics.json).
METRICS_FILE=$(find "$OUTPUT_DIR" -maxdepth 3 -name metrics.json -not -path "$OUTPUT_DIR/metrics.json" 2>/dev/null | head -1)
if [[ -n "$METRICS_FILE" ]]; then
  cp "$METRICS_FILE" "$OUTPUT_DIR/metrics.json"
  echo "Copied metrics -> $OUTPUT_DIR/metrics.json"
fi

exit "$rc"
