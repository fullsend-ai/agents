#!/usr/bin/env bash
# scrub-eval-results.sh — Remove secrets from eval result trees before artifact upload.
#
# Post-scripts (post-code/post-fix/post-review/…) echo `::add-mask::<token>` so the
# Actions log viewer can redact tokens. The eval harness also captures that
# stdout into case logs, so the raw token would otherwise ship in artifacts.
# This script redacts those patterns (and common GitHub token shapes) in place.
#
# Usage:
#   bash eval/scripts/scrub-eval-results.sh [dir ...]
# Defaults: eval/runs /tmp/agent-eval
set -euo pipefail

ROOTS=("$@")
if [[ ${#ROOTS[@]} -eq 0 ]]; then
  ROOTS=(eval/runs /tmp/agent-eval)
fi

# Dotenv files written for fullsend run may contain raw tokens.
for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  find "$root" -name '.eval-env' -type f -delete 2>/dev/null || true
done

scrub_file() {
  local f="$1"
  [[ -s "$f" ]] || return 0
  # perl is available on ubuntu-24.04 runners; -i edits in place.
  perl -i -pe '
    s/::add-mask::\S+/::add-mask::[REDACTED]/g;
    s/\bghp_[A-Za-z0-9_]{20,}/ghp_[REDACTED]/g;
    s/\bgho_[A-Za-z0-9_]{20,}/gho_[REDACTED]/g;
    s/\bghu_[A-Za-z0-9_]{20,}/ghu_[REDACTED]/g;
    s/\bghs_[A-Za-z0-9_]{20,}/ghs_[REDACTED]/g;
    s/\bghr_[A-Za-z0-9_]{20,}/ghr_[REDACTED]/g;
    s/\bgithub_pat_[A-Za-z0-9_]{20,}/github_pat_[REDACTED]/g;
    s#x-access-token:[^@/\s]+@#x-access-token:[REDACTED]@#g;
  ' "$f"
}

for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' f; do
    scrub_file "$f"
  done < <(find "$root" -type f \( \
      -name '*.log' -o -name '*.txt' -o -name '*.json' -o -name '*.jsonl' \
      -o -name '*.yaml' -o -name '*.yml' -o -name '*.md' \
    \) -print0 2>/dev/null)
done

# Fail closed if anything still looks like a live token / unredacted add-mask payload.
leak_pat='::add-mask::(ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)|\bghp_[A-Za-z0-9_]{20,}|\bgho_[A-Za-z0-9_]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}'
found=0
for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  if grep -RIE --binary-files=without-match \
      --include='*.log' --include='*.txt' --include='*.json' --include='*.jsonl' \
      --include='*.yaml' --include='*.yml' --include='*.md' \
      -e "$leak_pat" "$root" >/tmp/eval-scrub-leaks.txt 2>/dev/null; then
    found=1
    echo "::error::Secrets remain in eval results under ${root} after scrub:" >&2
    head -n 50 /tmp/eval-scrub-leaks.txt >&2 || true
  fi
done
rm -f /tmp/eval-scrub-leaks.txt

if [[ "$found" -ne 0 ]]; then
  exit 1
fi

echo "Scrubbed eval results under: ${ROOTS[*]}"
