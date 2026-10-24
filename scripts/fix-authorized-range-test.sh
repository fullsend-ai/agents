#!/usr/bin/env bash
# fix-authorized-range-test.sh — Test skills/fix-history-rewrite/scripts/
# authorized-range.sh: the contiguous fix-agent suffix at HEAD, with the
# Authored-by trailer rule for commits published through the GitHub API.
#
# Run from the repo root:
#   bash scripts/fix-authorized-range-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RANGE="${SCRIPT_DIR}/../skills/fix-history-rewrite/scripts/authorized-range.sh"
FAILURES=0
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
BOT_EMAIL="333+app[bot]@users.noreply.github.com"
export GIT_AUTHOR_NAME=fullsend-fix GIT_AUTHOR_EMAIL="${BOT_EMAIL}"
export GIT_COMMITTER_NAME=fullsend-fix GIT_COMMITTER_EMAIL="${BOT_EMAIL}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; shift; printf '  %s\n' "$@"; FAILURES=$((FAILURES + 1)); }

# new_repo NAME — repo with main at "init" and a branch checked out.
new_repo() {
  local d="${TEST_TMPDIR}/$1"
  git init -q -b main "$d"
  echo base > "$d/f"; git -C "$d" add f
  git -C "$d" commit -q -m init
  git -C "$d" checkout -q -b topic
  echo "$d"
}
# commit REPO NAME EMAIL MSG [extra -m ...] — one commit touching f.
commit() {
  local d="$1" name="$2" email="$3" msg="$4"; shift 4
  echo "${msg}" >> "$d/f"; git -C "$d" add f
  GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" git -C "$d" commit -q -m "$msg" "$@"
}
# published REPO NAME MSG [extra -m ...] — as the API publishes it.
published() {
  local d="$1" name="$2" msg="$3"; shift 3
  commit "$d" 'app[bot]' "${BOT_EMAIL}" "$msg" -m "Authored-by: ${name} <${BOT_EMAIL}>" "$@"
}
run() { (cd "$1" && bash "${RANGE}" main 2>&1); }
# expect REPO NAME N — the authorized range is the N commits at HEAD.
expect() {
  local d="$1" name="$2" n="$3" out
  if out="$(run "$d")" && [ "$out" = "REWRITE_BASE=$(git -C "$d" rev-parse "HEAD~${n}")
IN_SCOPE=${n}" ]; then pass "$name"; else fail "$name" "$out"; fi
}

# --- sandbox-authored suffix above a code-agent commit --------------------
r="$(new_repo plain)"
commit "$r" fullsend-code "${BOT_EMAIL}" "feat: code"
commit "$r" fullsend-fix "${BOT_EMAIL}" "fix: one"
commit "$r" fullsend-fix "${BOT_EMAIL}" "fix: two"
expect "$r" plain-suffix 2

# --- published commits: the trailer decides -------------------------------
r="$(new_repo published)"
published "$r" fullsend-code "feat: code"
published "$r" fullsend-fix "fix: one"
commit "$r" fullsend-fix "${BOT_EMAIL}" "fix: two"
expect "$r" published-trailer-suffix 2

# --- a human's spoofed trailer does not make it the fix agent's -----------
r="$(new_repo spoofed)"
commit "$r" Human h@example.com "feat: human" -m "Authored-by: fullsend-fix <${BOT_EMAIL}>"
commit "$r" fullsend-fix "${BOT_EMAIL}" "fix: one"
expect "$r" spoofed-trailer-ignored 1

# --- another bot's trailer is not trusted: the suffix stops there ---------
r="$(new_repo otherbot)"
commit "$r" 'github-actions[bot]' "41898282+github-actions[bot]@users.noreply.github.com" "chore: fmt" -m "Authored-by: fullsend-fix <${BOT_EMAIL}>"
commit "$r" fullsend-fix "${BOT_EMAIL}" "fix: one"
expect "$r" other-bot-trailer-ignored 1

# --- two trailers on a published commit are ambiguous: fail closed --------
r="$(new_repo double)"
commit "$r" 'app[bot]' "${BOT_EMAIL}" "fix: ambiguous" -m "Authored-by: fullsend-fix <${BOT_EMAIL}>
Authored-by: fullsend-fix <${BOT_EMAIL}>"
if out="$(run "$r")"; then fail "double-trailer-fails-closed" "$out"; else pass "double-trailer-fails-closed"; fi

# --- HEAD not the fix agent's: fail closed --------------------------------
r="$(new_repo head-code)"
commit "$r" fullsend-fix "${BOT_EMAIL}" "fix: one"
commit "$r" fullsend-code "${BOT_EMAIL}" "feat: code on top"
if out="$(run "$r")"; then fail "head-not-fix-agent" "$out"; else pass "head-not-fix-agent"; fi

echo
if [ "${FAILURES}" -gt 0 ]; then echo "${FAILURES} test(s) failed"; exit 1; fi
echo "All tests passed"
