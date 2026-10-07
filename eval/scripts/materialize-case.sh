#!/usr/bin/env bash
# Materialize a case's repo/ tree from its recipe card.
#
# A case directory under eval/dev/code-rhai/cases/ is a card: input.yaml (the
# epic as the issue) and annotations.yaml (provenance, snapshot commit,
# regression command). The repository tree the fixture pushes is NOT
# committed; this script rebuilds it from annotations.source.repo at
# annotations.source.snapshot_commit, then strips the same automation
# build-case.sh strips (CI workflows, Dependabot/Renovate configs) and any
# paths listed in annotations.source.exclude. Idempotent: a repo/ that
# already exists is kept unless --force.
#
# Usage: materialize-case.sh <case-dir> [--force]
set -euo pipefail
CASE_DIR="${1:?usage: materialize-case.sh <case-dir> [--force]}"
CASE_DIR="$(cd "$CASE_DIR" && pwd)"
FORCE=0; [[ "${2:-}" == "--force" ]] && FORCE=1
ANN="$CASE_DIR/annotations.yaml"
command -v yq >/dev/null || { echo "ERROR: yq not found" >&2; exit 1; }
[[ -f "$ANN" ]] || { echo "ERROR: no annotations.yaml in $CASE_DIR" >&2; exit 1; }

if [[ -d "$CASE_DIR/repo" && $FORCE -eq 0 ]]; then
  echo "repo/ already present in $CASE_DIR (use --force to rebuild)"; exit 0
fi

REPO=$(yq -r '.source.repo // ""' "$ANN")
SNAPSHOT=$(yq -r '.source.snapshot_commit // ""' "$ANN")
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "ERROR: source.repo must be owner/name, got '$REPO'" >&2; exit 1; }
[[ "$SNAPSHOT" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: source.snapshot_commit must be a full sha, got '$SNAPSHOT'" >&2; exit 1; }
mapfile -t EXCLUDE < <(yq -r '.source.exclude // [] | .[]' "$ANN")

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
echo "Cloning https://github.com/${REPO}.git at ${SNAPSHOT:0:12} ..."
git clone --quiet --filter=blob:none --no-checkout "https://github.com/${REPO}.git" "$WORK/src"
git -C "$WORK/src" fetch --quiet origin "$SNAPSHOT" 2>/dev/null || true
git -C "$WORK/src" rev-parse --verify --quiet "${SNAPSHOT}^{commit}" >/dev/null \
  || { echo "ERROR: commit $SNAPSHOT not found in ${REPO} (rewritten or deleted upstream?)" >&2; exit 1; }

rm -rf "$CASE_DIR/repo"; mkdir -p "$CASE_DIR/repo"
git -C "$WORK/src" archive "$SNAPSHOT" | tar -x -C "$CASE_DIR/repo"

# Automation that would act on the ephemeral repo the moment it is pushed
# (same list as build-case.sh), then the card's own exclusions.
rm -rf "$CASE_DIR/repo/.github/workflows"
for f in .github/dependabot.yml .github/dependabot.yaml .github/renovate.json .github/renovate.json5 renovate.json renovate.json5 .renovaterc .renovaterc.json; do
  rm -f "$CASE_DIR/repo/$f"
done
for p in "${EXCLUDE[@]+"${EXCLUDE[@]}"}"; do
  [[ -n "$p" && "$p" != /* && "$p" != *..* ]] || { echo "ERROR: refusing exclude path '$p'" >&2; exit 1; }
  rm -rf "$CASE_DIR/repo/$p"
done

n_files=$(find "$CASE_DIR/repo" -type f | wc -l | tr -d ' ')
echo "Materialized $CASE_DIR/repo from ${REPO}@${SNAPSHOT:0:12}: ${n_files} files, $(du -sh "$CASE_DIR/repo" | cut -f1)"
