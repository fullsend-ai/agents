#!/usr/bin/env bash
# Materialize a case's repo/ tree from its recipe card.
#
# A case directory under eval/local/code-rhai/cases/ is a card: input.yaml (the
# epic as the issue) and annotations.yaml (provenance, snapshot commit,
# regression command). The repository tree the fixture pushes is NOT
# committed; this script rebuilds it from annotations.source.repo at
# annotations.source.snapshot_commit, then strips the same automation
# build-case.sh strips (CI workflows, Dependabot/Renovate configs) and any
# paths listed in annotations.source.exclude. Idempotent: a repo/ that
# already exists is kept unless --force. The tree is built in a staging
# directory beside repo/ and moved into place only when every step has
# succeeded, so a failed build never leaves a partial repo/ that later runs
# (setup-fixture.sh, check-case.sh) would take for a complete one.
#
# Usage: materialize-case.sh <case-dir> [--force]
set -euo pipefail
CASE_DIR="${1:?usage: materialize-case.sh <case-dir> [--force]}"
CASE_DIR="$(cd "$CASE_DIR" && pwd)"
FORCE=0; [[ "${2:-}" == "--force" ]] && FORCE=1
ANN="$CASE_DIR/annotations.yaml"
command -v yq >/dev/null || { echo "ERROR: yq not found" >&2; exit 1; }
[[ -f "$ANN" ]] || { echo "ERROR: no annotations.yaml in $CASE_DIR" >&2; exit 1; }

# One build per card at a time: the existence check, the stale-stage sweep
# and the final move all assume nobody else is working on repo/. The lock is
# a directory (mkdir is atomic) and goes away with this run.
LOCK="$CASE_DIR/.repo-lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "ERROR: another materialize-case.sh run holds $LOCK; if no run is active, remove that directory and retry" >&2
  exit 1
fi
WORK=""; STAGE=""
cleanup() {
  # shellcheck disable=SC2317 # invoked indirectly via trap
  rm -rf "${WORK:-}" "${STAGE:-}" "$LOCK"
}
trap cleanup EXIT

if [[ -d "$CASE_DIR/repo" && $FORCE -eq 0 ]]; then
  echo "repo/ already present in $CASE_DIR (use --force to rebuild)"; exit 0
fi

REPO=$(yq -r '.source.repo // ""' "$ANN")
SNAPSHOT=$(yq -r '.source.snapshot_commit // ""' "$ANN")
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "ERROR: source.repo must be owner/name, got '$REPO'" >&2; exit 1; }
[[ "$SNAPSHOT" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: source.snapshot_commit must be a full sha, got '$SNAPSHOT'" >&2; exit 1; }
mapfile -t EXCLUDE < <(yq -r '.source.exclude // [] | .[]' "$ANN")

WORK=$(mktemp -d)
# A run killed before its trap ran (SIGKILL, lost terminal) leaves its stage
# behind; sweep those before making a new one (safe under the lock).
# .gitignore covers the pattern.
find "$CASE_DIR" -maxdepth 1 -name '.repo-stage.*' -type d -exec rm -rf {} +
STAGE=$(mktemp -d "$CASE_DIR/.repo-stage.XXXXXX")
echo "Cloning https://github.com/${REPO}.git at ${SNAPSHOT:0:12} ..."
git clone --quiet --filter=blob:none --no-checkout "https://github.com/${REPO}.git" "$WORK/src"
git -C "$WORK/src" fetch --quiet origin "$SNAPSHOT" 2>/dev/null || true
git -C "$WORK/src" rev-parse --verify --quiet "${SNAPSHOT}^{commit}" >/dev/null \
  || { echo "ERROR: commit $SNAPSHOT not found in ${REPO} (rewritten or deleted upstream?)" >&2; exit 1; }

git -C "$WORK/src" archive "$SNAPSHOT" | tar -x -C "$STAGE"

# Never delete through a symlink: every component of the target, the last
# one included, must be a real path inside the tree, or rm would act on the
# link's target on this host (an upstream tree could ship .github as a link;
# `rm -rf link/` with a trailing slash follows the link). The relpath must
# already be clean: no leading or trailing slash, no empty component.
# Kept identical to the copy in build-case.sh.
assert_real_path() { # root relpath
  local cur="$1" parts c
  [[ "$2" == */ || "$2" == *//* ]] && { echo "ERROR: refusing to delete $2: path must not end in / or contain //" >&2; exit 1; }
  IFS=/ read -ra parts <<< "$2"
  for c in "${parts[@]}"; do
    cur="$cur/$c"
    [[ -L "$cur" ]] && { echo "ERROR: refusing to delete $2: '$c' is a symlink in the upstream tree" >&2; exit 1; }
  done
  return 0
}

# Automation that would act on the ephemeral repo the moment it is pushed
# (same list as build-case.sh), then the card's own exclusions.
assert_real_path "$STAGE" .github/workflows
rm -rf "$STAGE/.github/workflows"
for f in .github/dependabot.yml .github/dependabot.yaml .github/renovate.json .github/renovate.json5 renovate.json renovate.json5 .renovaterc .renovaterc.json; do
  assert_real_path "$STAGE" "$f"
  rm -f "$STAGE/$f"
done
for p in "${EXCLUDE[@]+"${EXCLUDE[@]}"}"; do
  [[ -n "$p" && "$p" != /* && "$p" != *..* ]] || { echo "ERROR: refusing exclude path '$p'" >&2; exit 1; }
  p="${p%/}"   # a trailing slash would make rm follow a symlink
  assert_real_path "$STAGE" "$p"
  rm -rf "${STAGE:?}/$p"
done

# Every step succeeded: replace repo/ in one move (same filesystem).
rm -rf "$CASE_DIR/repo"
mv "$STAGE" "$CASE_DIR/repo"

n_files=$(find "$CASE_DIR/repo" -type f | wc -l | tr -d ' ')
echo "Materialized $CASE_DIR/repo from ${REPO}@${SNAPSHOT:0:12}: ${n_files} files, $(du -sh "$CASE_DIR/repo" | cut -f1)"
