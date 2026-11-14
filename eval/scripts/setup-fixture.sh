#!/usr/bin/env bash
# before_each hook: create ephemeral repo and fixture for a test case.
#
# Reads input.yaml from CASE_SOURCE_DIR, creates an ephemeral GitHub repo,
# pushes test content, creates the fixture (issue or PR), and writes
# .hook-outputs.yaml so the harness passes dynamic URLs to the runner.
#
# Required env (set by harness + eval.yaml execution.env):
#   CASE_SOURCE_DIR  — path to the original case directory in the dataset
#   CASE_WORKSPACE   — path to the case workspace (cwd)
#   EVAL_ORG         — GitHub org/user for ephemeral repos
#   GH_TOKEN         — GitHub token with repo and delete_repo scope
# Optional env:
#   EVAL_REPO_VISIBILITY — private (default) or public; see eval/README.md
#
# Writes:
#   $CASE_WORKSPACE/.hook-outputs.yaml — env vars for the runner
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CASE_WORKSPACE="${CASE_WORKSPACE:?CASE_WORKSPACE is required}"
EVAL_ORG="${EVAL_ORG:?EVAL_ORG is required}"

# CASE_SOURCE_DIR is set by the harness but may resolve incorrectly when
# dataset.path is relative. Fall back to locating input.yaml via the
# eval config's directory.
CASE_SOURCE_DIR="${CASE_SOURCE_DIR:?CASE_SOURCE_DIR is required}"
if [[ ! -d "$CASE_SOURCE_DIR" ]]; then
  config="${AGENT_EVAL_CONFIG:?}"
  config_dir="$(dirname "$config")"
  case_id="${CASE_ID:?}"
  dataset_path="$(yq -r '.dataset.path // "cases"' "$config")"
  CASE_SOURCE_DIR="$(cd "$config_dir" && cd "$dataset_path" && cd "$case_id" && pwd)"
fi

for cmd in gh yq jq git uuidgen; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not found in PATH" >&2
    exit 1
  fi
done

INPUT="${CASE_SOURCE_DIR}/input.yaml"
if [[ ! -f "$INPUT" ]]; then
  echo "ERROR: ${INPUT} not found" >&2
  exit 1
fi

FORGE=$(yq -r '.forge // "github"' "$INPUT")
FIXTURE_TYPE=$(yq -r '.fixture.type // "issue"' "$INPUT")
FIXTURE_TITLE=$(yq -r '.fixture.title' "$INPUT")
FIXTURE_BODY=$(yq -r '.fixture.body' "$INPUT")
FIXTURE_BASE=$(yq -r '.fixture.base // "main"' "$INPUT")
FIXTURE_HEAD=$(yq -r '.fixture.head_branch // ""' "$INPUT")
FIXTURE_FILES=$(yq -r '.fixture.files // "[]"' "$INPUT")
FOLLOWUP_FILES=$(yq -r '.fixture.followup_files // "[]"' "$INPUT")
FIXTURE_COMMIT_MESSAGE=$(yq -r '.fixture.commit_message // "eval: fixture changes"' "$INPUT")
PRIOR_REVIEW_BODY=$(yq -r '.prior_review.body // ""' "$INPUT")
PRIOR_REVIEW_PROVENANCE=$(yq -r '.prior_review.provenance // "none"' "$INPUT")

# --- Create ephemeral repo ---
uuid=$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)
CASE_ID_SAFE=$(basename "$CASE_SOURCE_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
repo_name="eval-${CASE_ID_SAFE}-${uuid}"
EPHEMERAL_REPO="${EVAL_ORG}/${repo_name}"
FIXTURE_BODY=${FIXTURE_BODY//\$\{REPO_URL\}/https://github.com/${EPHEMERAL_REPO}}

# Private by default: the fixture is a throwaway copy of someone else's
# repository, and a public copy is indexed, scanned and acted on by automation
# as if it were meant to be published (a secret scanner has flagged a sample
# key in a public fixture snapshot). EVAL_REPO_VISIBILITY=public restores the
# old behaviour; the value is checked here, before anything is created, since
# gh would otherwise reject a typo as an unknown flag on every attempt of the
# retry loop below.
EVAL_REPO_VISIBILITY="${EVAL_REPO_VISIBILITY:-private}"
case "$EVAL_REPO_VISIBILITY" in
  private|public) ;;
  *)
    echo "ERROR: EVAL_REPO_VISIBILITY must be private or public, not '${EVAL_REPO_VISIBILITY}'" >&2
    exit 1
    ;;
esac
# GitHub's API occasionally resets the connection; retry the create.
created=0
for attempt in 1 2 3; do
  if gh repo create "$EPHEMERAL_REPO" "--${EVAL_REPO_VISIBILITY}" --description "Ephemeral eval repo (auto-deleted)"; then
    created=1; break
  fi
  # A retry after a half-created repo would collide; check before retrying.
  # Reuse it only with the visibility this run asked for: the snapshot must
  # not land in a repository more visible than requested.
  existing="$(gh repo view "$EPHEMERAL_REPO" --json visibility -q .visibility 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  if [[ -n "$existing" ]]; then
    if [[ "$existing" == "$EVAL_REPO_VISIBILITY" ]]; then created=1; break; fi
    echo "ERROR: ${EPHEMERAL_REPO} already exists with visibility ${existing}, not ${EVAL_REPO_VISIBILITY}; refusing to reuse it" >&2
    exit 1
  fi
  if [[ $attempt -lt 3 ]]; then
    echo "WARNING: gh repo create attempt ${attempt} failed; retrying in $((attempt * 5))s" >&2
    sleep $((attempt * 5))
  fi
done
if [[ $created -ne 1 ]]; then
  echo "ERROR: could not create ${EPHEMERAL_REPO} after 3 attempts" >&2
  exit 1
fi
echo "Created repo: $EPHEMERAL_REPO"

# Record the repo for teardown-fixture.sh before anything else can fail.
# The harness collects .hook-outputs.yaml only after this hook succeeds;
# when a later step fails, the file stays in CASE_WORKSPACE and
# teardown-fixture.sh reads it from there to delete the repo. The full
# file written at the end replaces this one.
cat > "$CASE_WORKSPACE/.hook-outputs.yaml" <<YAML
env:
  EPHEMERAL_REPO: "${EPHEMERAL_REPO}"
data:
  ephemeral_repo: "${EPHEMERAL_REPO}"
YAML

TARGET_DIR=$(mktemp -d)
# Username comes from the helper; URL userinfo is lost when curl strips it from the effective URL.
GH_CRED_HELPER='!f(){ echo "username=x-access-token"; echo "password=${GH_TOKEN}"; };f'
git -c "credential.helper=${GH_CRED_HELPER}" \
  clone "https://github.com/${EPHEMERAL_REPO}.git" "$TARGET_DIR"
git -C "$TARGET_DIR" config credential.helper "${GH_CRED_HELPER}"

if [[ -d "${CASE_SOURCE_DIR}/repo" ]]; then
  cp -a "${CASE_SOURCE_DIR}/repo/." "$TARGET_DIR/"
else
  echo "# Eval test repo" > "$TARGET_DIR/README.md"
fi

git -C "$TARGET_DIR" add -A
if ! git -C "$TARGET_DIR" diff --cached --quiet; then
  # The snapshot is a mechanical copy of an upstream repository. For a private
  # throwaway fixture, a developer's global git hooks (e.g. a secret scanner
  # configured via core.hooksPath, which may hook pre-commit, pre-push or both)
  # have blocked this step on upstream sample data, so they are bypassed for
  # this commit and its push only. A public snapshot is the case the private
  # default exists to prevent (upstream sample secrets published under the
  # eval account), so there the developer's hooks stay on as the last local
  # check before the snapshot is published; a hook that refuses fails the
  # case, which is the right outcome.
  hook_opts=()
  if [[ "$EVAL_REPO_VISIBILITY" == "private" ]]; then
    hook_opts=(-c core.hooksPath=/dev/null)
    git -C "$TARGET_DIR" "${hook_opts[@]}" commit --no-verify -m "eval: initial content"
  else
    echo "WARNING: EVAL_REPO_VISIBILITY=${EVAL_REPO_VISIBILITY}: the snapshot will be published under the eval account; local git hooks run on this commit and its push" >&2
    git -C "$TARGET_DIR" commit -m "eval: initial content"
  fi
  # Large snapshots (100 MB+, 10k+ files) have failed their first HTTPS push
  # with "curl 55 Send failure: Broken pipe"; retry a few times before giving
  # up. No git transport settings are changed: GitHub speaks chunked HTTP/1.1,
  # and git's docs say raising http.postBuffer is not a fix for push failures.
  push_ok=0
  for attempt in 1 2 3; do
    # ${arr[@]+"${arr[@]}"}: an empty array is "unbound" under set -u on bash
    # before 4.4, so a plain "${hook_opts[@]}" would abort the public push.
    if git -C "$TARGET_DIR" ${hook_opts[@]+"${hook_opts[@]}"} push origin HEAD; then
      push_ok=1; break
    fi
    if [[ $attempt -lt 3 ]]; then
      echo "WARNING: push attempt ${attempt} failed; retrying in $((attempt * 10))s" >&2
      sleep $((attempt * 10))
    fi
  done
  if [[ $push_ok -ne 1 ]]; then
    echo "ERROR: could not push the snapshot to ${EPHEMERAL_REPO} after 3 attempts" >&2
    exit 1
  fi
fi

# --- Create seed issues (if any) ---
SEED_COUNT=$(yq -r '.seed_issues // [] | length' "$INPUT")
if [[ "$SEED_COUNT" -gt 0 ]]; then
  for i in $(seq 0 $((SEED_COUNT - 1))); do
    seed_title=$(yq -r ".seed_issues[$i].title" "$INPUT")
    seed_body=$(yq -r ".seed_issues[$i].body" "$INPUT")
    seed_url=$(gh issue create \
      --repo "$EPHEMERAL_REPO" \
      --title "$seed_title" \
      --body "$seed_body")
    echo "Created seed issue: $seed_url"
    seed_state=$(yq -r ".seed_issues[$i].state // \"open\"" "$INPUT")
    if [[ "$seed_state" == "closed" ]]; then
      seed_number="${seed_url##*/}"
      gh issue close "$seed_number" --repo "$EPHEMERAL_REPO" --reason completed
      echo "Closed seed issue: $seed_url"
    fi
  done
fi

# --- Create fixture ---
FIXTURE_URL=""
FIXTURE_NUMBER=""
FIXTURE_INITIAL_SHA=""
PRIOR_REVIEW_SHA=""

case "${FORGE}:${FIXTURE_TYPE}" in
  github:issue)
    FIXTURE_URL=$(gh issue create \
      --repo "$EPHEMERAL_REPO" \
      --title "$FIXTURE_TITLE" \
      --body "$FIXTURE_BODY")
    FIXTURE_NUMBER="${FIXTURE_URL##*/}"
    echo "Created issue: $FIXTURE_URL"
    # Optional fixture.labels: labels the issue already carries when the
    # agent starts, e.g. ready-to-code for a code case (the code agent is
    # dispatched only after triage applies it).
    if [[ "$(yq -r '(.fixture.labels // []) | type' "$INPUT")" != "!!seq" ]] \
      || [[ "$(yq -r '[(.fixture.labels // [])[] | select(type != "!!str")] | length' "$INPUT")" != "0" ]]; then
      echo "ERROR: fixture.labels must be a list of label names" >&2
      exit 1
    fi
    mapfile -t fixture_labels < <(yq -r '.fixture.labels // [] | .[]' "$INPUT")
    for label in "${fixture_labels[@]}"; do
      [[ -n "$label" ]] || continue
      # Logged on one line with every "::" broken up, so a label cannot
      # be read as an Actions workflow command.
      label_log="$(printf '%s' "$label" | tr '\r\n' '  ' | sed 's/::/: :/g')"
      # gh issue edit --add-label splits its value on commas.
      if [[ "$label" == *,* ]]; then
        echo "ERROR: fixture label '${label_log}' contains a comma" >&2
        exit 1
      fi
      gh label create "$label" --repo "$EPHEMERAL_REPO" --force >/dev/null
      gh issue edit "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" --add-label "$label" >/dev/null
      echo "Labeled issue: ${label_log}"
    done
    ;;
  github:pull_request)
    PR_BRANCH="${FIXTURE_HEAD:-eval-pr-$(date +%s)-$$}"
    git -C "$TARGET_DIR" checkout -b "$PR_BRANCH"
    file_count=$(echo "$FIXTURE_FILES" | yq -r 'length')
    for i in $(seq 0 $((file_count - 1))); do
      path=$(echo "$FIXTURE_FILES" | yq -r ".[$i].path")
      mkdir -p "$TARGET_DIR/$(dirname "$path")"
      echo "$FIXTURE_FILES" | yq -r ".[$i].content" | "$SCRIPT_DIR/write-fixture-file.sh" "$TARGET_DIR/$path"
    done
    git -C "$TARGET_DIR" add -A
    git -C "$TARGET_DIR" commit -m "$FIXTURE_COMMIT_MESSAGE"
    FIXTURE_INITIAL_SHA=$(git -C "$TARGET_DIR" rev-parse HEAD)
    git -C "$TARGET_DIR" push origin "$PR_BRANCH"
    followup_count=$(echo "$FOLLOWUP_FILES" | yq -r 'length')
    if [[ "$followup_count" -gt 0 ]]; then
      for i in $(seq 0 $((followup_count - 1))); do
        path=$(echo "$FOLLOWUP_FILES" | yq -r ".[$i].path")
        mkdir -p "$TARGET_DIR/$(dirname "$path")"
        echo "$FOLLOWUP_FILES" | yq -r ".[$i].content" | "$SCRIPT_DIR/write-fixture-file.sh" "$TARGET_DIR/$path"
      done
      git -C "$TARGET_DIR" add -A
      git -C "$TARGET_DIR" commit -m "eval: re-review follow-up"
      git -C "$TARGET_DIR" push origin "$PR_BRANCH"
    fi
    FIXTURE_URL=$(gh pr create \
      --repo "$EPHEMERAL_REPO" \
      --base "$FIXTURE_BASE" \
      --head "$PR_BRANCH" \
      --title "$FIXTURE_TITLE" \
      --body "$FIXTURE_BODY")
    FIXTURE_NUMBER="${FIXTURE_URL##*/}"
    echo "Created PR: $FIXTURE_URL"
    ;;
  *)
    echo "ERROR: unsupported forge:fixture_type = ${FORGE}:${FIXTURE_TYPE}" >&2
    exit 1
    ;;
esac

# Clean up the local clone
rm -rf "$TARGET_DIR"

PRIOR_REVIEW_FILE=""
if [[ -n "$PRIOR_REVIEW_BODY" ]]; then
  PRIOR_REVIEW_SHA="${FIXTURE_INITIAL_SHA:-}"
  if [[ -z "$PRIOR_REVIEW_SHA" ]]; then
    echo "ERROR: prior_review requires a pull_request fixture" >&2
    exit 1
  fi
  PRIOR_REVIEW_FILE="${CASE_WORKSPACE}/prior-review.txt"
  printf '%s\n' "$PRIOR_REVIEW_BODY" > "$PRIOR_REVIEW_FILE"
fi

# --- Write hook outputs ---
# The harness reads this file and injects env vars into the CLI runner
# and forward-propagates them to after_each hooks.
cat > "$CASE_WORKSPACE/.hook-outputs.yaml" <<YAML
env:
  EPHEMERAL_REPO: "${EPHEMERAL_REPO}"
  FIXTURE_URL: "${FIXTURE_URL}"
  FIXTURE_NUMBER: "${FIXTURE_NUMBER}"
  FIXTURE_TYPE: "${FIXTURE_TYPE}"
  FORGE: "${FORGE}"
  PRIOR_REVIEW_FILE: "${PRIOR_REVIEW_FILE}"
  PRIOR_REVIEW_SHA: "${PRIOR_REVIEW_SHA:-}"
  PRIOR_REVIEW_PROVENANCE: "${PRIOR_REVIEW_PROVENANCE}"
data:
  ephemeral_repo: "${EPHEMERAL_REPO}"
  fixture_url: "${FIXTURE_URL}"
  fixture_type: "${FIXTURE_TYPE}"
YAML

# Optional per-case human instruction for fix (and similar) agents. Kept in
# input.yaml with the fixture; shared runner must not hardcode prompt text.
human_instruction=$(yq -r '.human_instruction // ""' "$INPUT")
if [[ -n "$human_instruction" ]]; then
  if [[ "$human_instruction" == *$'\n'* || "$human_instruction" == *$'\r'* ]]; then
    echo "ERROR: human_instruction in input.yaml must be a single line" >&2
    exit 1
  fi
  HUMAN_INSTRUCTION="$human_instruction" yq -i \
    '.env.HUMAN_INSTRUCTION = strenv(HUMAN_INSTRUCTION)' \
    "$CASE_WORKSPACE/.hook-outputs.yaml"
fi

echo "Hook outputs written to $CASE_WORKSPACE/.hook-outputs.yaml"
