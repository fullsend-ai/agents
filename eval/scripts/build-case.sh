#!/usr/bin/env bash
# Build an eval/dev/code-rhai case from a Jira epic sample entry (rhai-epics dataset,
# schema_version >= 4, with descriptions). The epic is the case: its text becomes
# the issue the agent sees; its linked PRs are used only to identify the
# repository and to choose the snapshot commit.
#
# Usage:
#   build-case.sh --sample sample.json --epic RHAI-517 --case eval/dev/code-rhai/cases/NNN-slug
#                 [--snapshot <sha>] [--keep-workflows]
#
# Snapshot rule (decided 2026-09-24): the repository as it was the moment the
# epic's FIRST PR was accepted into its base branch, i.e. the parent of the
# earliest merge commit among the linked PRs. If no linked PR has merged, the
# current tip of the default branch. --snapshot overrides; the choice and the
# reason are recorded in annotations.yaml either way.
#
# Produces in --case:
#   repo/              tree at the snapshot, no .git; .github/workflows removed
#                      (NOT committed: git-ignored, rebuilt on demand by
#                      materialize-case.sh from annotations.source)
#                      unless --keep-workflows (they would run upstream CI on
#                      the ephemeral repo)
#   input.yaml         epic summary + description, verbatim
#   annotations.yaml   provenance, snapshot, PR list; regression command,
#                      budgets left as TODO; judge_notes empty
set -euo pipefail

SAMPLE="" EPIC="" CASE_DIR="" SNAPSHOT="" KEEP_WORKFLOWS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample) SAMPLE="$2"; shift 2 ;;
    --epic) EPIC="$2"; shift 2 ;;
    --case) CASE_DIR="$2"; shift 2 ;;
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --keep-workflows) KEEP_WORKFLOWS=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done
: "${SAMPLE:?--sample FILE is required}" "${EPIC:?--epic KEY is required}" "${CASE_DIR:?--case DIR is required}"
for cmd in gh git jq python3; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found" >&2; exit 1; }; done
[[ -f "$SAMPLE" ]] || { echo "ERROR: sample not found: $SAMPLE" >&2; exit 1; }
if [[ -e "$CASE_DIR" && -n "$(ls -A "$CASE_DIR" 2>/dev/null)" ]]; then
  echo "ERROR: $CASE_DIR exists and is not empty" >&2; exit 1
fi

epic_json=$(jq -c --arg k "$EPIC" '.issues[] | select(.key == $k)' "$SAMPLE")
[[ -n "$epic_json" ]] || { echo "ERROR: $EPIC not in $SAMPLE" >&2; exit 1; }
summary=$(jq -r .summary <<<"$epic_json")
description=$(jq -r '.description // empty' <<<"$epic_json")
[[ -n "$description" ]] || { echo "ERROR: $EPIC has no description in the sample; re-run the sampler with descriptions" >&2; exit 1; }
epic_url=$(jq -r .url <<<"$epic_json")
repos=$(jq -r '[.code_changes[].repository] | unique | .[]' <<<"$epic_json")
nrepos=$(wc -l <<<"$repos" | tr -d ' ')
if [[ "$nrepos" != "1" ]]; then
  echo "ERROR: epic touches $nrepos repositories; the eval wants exactly one:" >&2; echo "$repos" >&2; exit 1
fi
REPO="$repos"

echo "Epic ${EPIC}: ${summary}"
echo "Repository: ${REPO}"
echo "Linked PRs:"
merged_parents=()   # "mergedAt sha parent title"
while IFS= read -r num; do
  [[ -z "$num" ]] && continue
  info=$(gh pr view "$num" --repo "$REPO" --json title,state,createdAt,mergedAt,mergeCommit,changedFiles \
    --jq '"\(.state)\t\(.createdAt[0:10])\t\(.mergedAt // "-" | .[0:10])\t\(.mergeCommit.oid // "-")\t\(.changedFiles)\t\(.title)"')
  IFS=$'\t' read -r state created merged mc files title <<<"$info"
  printf '  #%-6s %-7s opened %s  merged %s  %4s files  %s\n' "$num" "$state" "$created" "$merged" "$files" "$title"
  if [[ "$state" == "MERGED" && "$mc" != "-" ]]; then
    merged_parents+=("$merged"$'\t'"$mc"$'\t'"$num")
  fi
done < <(jq -r '.code_changes[] | select(.kind=="pull_request") | .number' <<<"$epic_json" | sort -un)

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
echo "Cloning ${REPO} (blobless)..."
git clone --quiet --filter=blob:none "https://github.com/${REPO}.git" "$WORK/src"
default_branch=$(git -C "$WORK/src" symbolic-ref --short HEAD)

if [[ -n "$SNAPSHOT" ]]; then
  git -C "$WORK/src" fetch --quiet origin "$SNAPSHOT" 2>/dev/null || true
  snapshot=$(git -C "$WORK/src" rev-parse "${SNAPSHOT}^{commit}")
  snapshot_rule="override: --snapshot ${SNAPSHOT}"
elif [[ ${#merged_parents[@]} -gt 0 ]]; then
  first=$(printf '%s\n' "${merged_parents[@]}" | sort | head -1)
  IFS=$'\t' read -r fmerged fmc fnum <<<"$first"
  git -C "$WORK/src" fetch --quiet origin "$fmc"
  snapshot=$(git -C "$WORK/src" rev-parse "${fmc}^1")
  snapshot_rule="parent of the merge commit of PR #${fnum}, the epic's first PR to be accepted (merged ${fmerged})"
else
  snapshot=$(git -C "$WORK/src" rev-parse HEAD)
  snapshot_rule="tip of ${default_branch} at build time; no linked PR has merged yet"
fi
snapshot_date=$(git -C "$WORK/src" show -s --format=%cs "$snapshot")
echo "Snapshot: ${snapshot} (${snapshot_date}) — ${snapshot_rule}"

mkdir -p "$CASE_DIR/repo"
git -C "$WORK/src" archive "$snapshot" | tar -x -C "$CASE_DIR/repo"
# Automation that would act on the ephemeral repo the moment it is pushed:
# CI workflows, and Dependabot / Renovate configs (Dependabot opened a
# version-bump PR on a throwaway repo within minutes on 2026-09-25, and the
# hooks mistook it for the agent's PR).
removed=()
if [[ $KEEP_WORKFLOWS -eq 0 && -d "$CASE_DIR/repo/.github/workflows" ]]; then
  rm -rf "$CASE_DIR/repo/.github/workflows"; removed+=(".github/workflows")
fi
for f in .github/dependabot.yml .github/dependabot.yaml .github/renovate.json .github/renovate.json5 renovate.json renovate.json5 .renovaterc .renovaterc.json; do
  if [[ -e "$CASE_DIR/repo/$f" ]]; then rm -f "$CASE_DIR/repo/$f"; removed+=("$f"); fi
done
removed_note="none"; [[ ${#removed[@]} -gt 0 ]] && removed_note="${removed[*]} (automation that would act on the ephemeral repo)"
n_files=$(find "$CASE_DIR/repo" -type f | wc -l | tr -d ' ')
size=$(du -sh "$CASE_DIR/repo" | cut -f1)

# input.yaml: the epic verbatim (Python so multi-line text is quoted safely).
python3 - "$CASE_DIR/input.yaml" "${EPIC}: ${summary}" "$description" <<'PY'
import sys, yaml
path, title, body = sys.argv[1], sys.argv[2], sys.argv[3]
# Write the body as a literal block scalar (body: |-) so the card reads as prose in a
# diff. Trailing whitespace is stripped first: a literal block cannot carry it under
# the repo's trailing-whitespace hook, and PyYAML would otherwise fall back to quoting.
body = "\n".join(line.rstrip() for line in body.split("\n")).rstrip("\n")
class Literal(str):
    pass
yaml.add_representer(Literal, lambda d, s: d.represent_scalar(
    "tag:yaml.org,2002:str", s, style="|"))
# ready-to-code is the label that triggers the code agent in production
# (docs/code.md); the fixture carries it so runtimes that check readiness proceed.
yaml.dump({"forge": "github", "fixture": {"type": "issue", "title": title,
                                           "body": Literal(body),
                                           "labels": ["ready-to-code"]}},
          open(path, "w"), sort_keys=False, allow_unicode=True, width=10**6)
PY

prs_yaml=$(jq -r '.code_changes[] | select(.kind=="pull_request") | "    - " + .url' <<<"$epic_json")
cat > "$CASE_DIR/annotations.yaml" <<YAML
# Generated by eval/scripts/build-case.sh on $(date -u +%Y-%m-%dT%H:%MZ); validated with
# eval/scripts/check-case.sh.
source:
  epic: ${EPIC}
  epic_url: ${epic_url}
  epic_summary: $(jq -n --arg s "$summary" '$s')
  sample: $(jq -n --arg s "$(basename "$SAMPLE") (generated $(jq -r '.generated_at // "?"' "$SAMPLE"))" '$s')
  repo: ${REPO}
  # The PRs humans opened for this epic. Used only to identify the repository
  # and to choose the snapshot; never shown to the agent or the judge.
  pull_requests:
${prs_yaml}
  snapshot_commit: ${snapshot}   # ${snapshot_date}
  snapshot_rule: $(jq -n --arg s "$snapshot_rule" '$s')
  vendored: $(jq -n --arg s "full tree at the snapshot (${n_files} files, ${size}); removed: ${removed_note}" '$s')

# Pass-to-pass: the repository's own test command, run on the agent's PR head
# from the repo root (capture-pr-artifacts.sh). Use what the repo's CI runs.
regression_tests:
  command: "TODO"
test_timeout_s: 1800

# Optional, for the judges: facts about the FIXTURE the judge cannot see for
# itself, such as a directory left out of the snapshot that the task touches.
# Never describe the task, the human solution or its PRs; the task text is
# the only specification the judge should have. Leave empty by default.
judge_notes: ""


# First-run budgets; tighten from the measured result.
max_turns: 300
max_cost_usd: 40.00
YAML

echo
echo "Case written to ${CASE_DIR}"
echo "  repo/:       ${n_files} files, ${size}; removed: ${removed_note}"
echo "  input.yaml:  epic text, $(wc -c < "$CASE_DIR/input.yaml" | tr -d ' ') bytes"
echo "Next: fill regression_tests.command in annotations.yaml, then:"
echo "  eval/scripts/check-case.sh ${CASE_DIR}"
