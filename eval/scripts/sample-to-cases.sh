#!/usr/bin/env bash
# List what eval/dev/code-rhai cases a Jira epic sample (rhai-epics dataset,
# schema_version >= 4) can yield. The epic is the case unit. Eligible: the epic
# has a description and all its linked PRs are in one repository. For each
# epic prints the repo (language, size), the linked PRs with merge state, the
# snapshot the build script would pick, and the build command.
#
# Usage: sample-to-cases.sh sample.json [--no-gh]
set -euo pipefail
SAMPLE="${1:?usage: sample-to-cases.sh sample.json [--no-gh]}"
USE_GH=1; [[ "${2:-}" == "--no-gh" ]] && USE_GH=0
command -v jq >/dev/null || { echo "ERROR: jq not found" >&2; exit 1; }
echo "sample: $SAMPLE (schema_version $(jq -r '.schema_version // "?"' "$SAMPLE"), $(jq '.issues|length' "$SAMPLE") epics, filter: $(jq -c '.sampling_filter' "$SAMPLE"))"
echo
jq -r '.issues[] | [.key, .status, (.description // "" | length | tostring), ([.code_changes[].repository] | unique | join(",")), .summary] | @tsv' "$SAMPLE" |
while IFS=$'\t' read -r key status dlen repos summary; do
  echo "== $key [$status]: $summary"
  [[ "$dlen" == "0" ]] && echo "   BLOCKER: no description in the sample"
  if [[ "$repos" == *,* || -z "$repos" ]]; then echo "   BLOCKER: repositories: ${repos:-none}"; echo; continue; fi
  echo "   repo: $repos"
  if [[ $USE_GH -eq 1 ]]; then
    gh repo view "$repos" --json primaryLanguage,diskUsage --jq '"   " + (.primaryLanguage.name // "?") + ", " + ((.diskUsage/1024)|floor|tostring) + " MB"' 2>/dev/null || echo "   (gh repo view failed)"
    first_merged=""
    while IFS= read -r num; do
      [[ -z "$num" ]] && continue
      info=$(gh pr view "$num" --repo "$repos" --json state,createdAt,mergedAt,changedFiles,title \
        --jq '"\(.state)\t\(.createdAt[0:10])\t\(.mergedAt // "-" | .[0:10])\t\(.changedFiles)\t\(.title)"' 2>/dev/null) || { echo "   PR #$num: gh failed"; continue; }
      IFS=$'\t' read -r st cr mg nf title <<<"$info"
      printf '   PR #%-6s %-7s opened %s merged %s %4s files  %s\n' "$num" "$st" "$cr" "$mg" "$nf" "$title"
      if [[ "$st" == "MERGED" ]]; then
        if [[ -z "$first_merged" || "$mg" < "${first_merged%% *}" ]]; then first_merged="$mg #$num"; fi
      fi
    done < <(jq -r --arg k "$key" '.issues[] | select(.key==$k) | .code_changes[] | select(.kind=="pull_request") | .number' "$SAMPLE" | sort -un)
    if [[ -n "$first_merged" ]]; then echo "   snapshot: parent of the merge of ${first_merged#* } (first accepted, ${first_merged%% *})"
    else echo "   snapshot: current default-branch tip (nothing merged yet)"; fi
  fi
  slug=$(printf '%s' "$summary" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-40)
  echo "   build: eval/scripts/build-case.sh --sample $SAMPLE --epic $key --case eval/dev/code-rhai/cases/NNN-${key,,}-${slug}"
  echo
done
