#!/usr/bin/env bash
# pr-review-prior-risk-test.sh — Verify the pr-review skill finds the prior
# risk assessment posted by the review App named in FULLSEND_SLUG (#2050).
#
# Extracts the GitHub "Fetch prior risk assessment" snippet from
# skills/pr-review/SKILL.md and runs it against a stubbed `gh` that applies
# the snippet's --jq filter to a fixture comment list.
#
# Run from the repo root:
#   bash scripts/pr-review-prior-risk-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/pr-review/SKILL.md"
FAILURES=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

SNIPPET="$(awk '
  /\*\*Fetch prior risk assessment \(re-reviews only\)\.\*\*/ { found = 1 }
  found && /^ *```bash$/ { code = 1; next }
  code && /^ *```$/ { exit }
  code { print }
' "${SKILL}")"

if [[ -z "${SNIPPET}" ]]; then
  echo "FAIL: could not extract the prior risk assessment snippet from ${SKILL#"${REPO_ROOT}/"}"
  exit 1
fi

# Stub gh: print the fixture comments through the --jq filter, as
# `gh api --jq` does (strings raw, everything else as JSON).
mkdir -p "${TMP_ROOT}/bin"
cat > "${TMP_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
filter=""
while test $# -gt 0; do
  case "$1" in
    --jq) filter="$2"; shift 2 ;;
    *) shift ;;
  esac
done
jq -c -r "${filter:-.}" "${COMMENTS_FIXTURE}"
EOF
chmod +x "${TMP_ROOT}/bin/gh"

MARKER='<!-- fullsend:risk-assessment -->'

# Each comment is identified by its id. The default App's comment and a
# plain user's forged comment come last, so `last` would pick them if the
# filter matched them.
jq -n --arg m "${MARKER}" '[
  {id: 1, body: ($m + "\n**Risk Assessment: low (1/5)**"),
   performed_via_github_app: {slug: "custom-review"},
   user: {login: "custom-review[bot]"}},
  {id: 2, body: "no marker here",
   performed_via_github_app: {slug: "custom-review"},
   user: {login: "custom-review[bot]"}},
  {id: 3, body: ($m + "\n**Risk Assessment: medium (3/5)**"),
   performed_via_github_app: {slug: "fullsend-ai-review"},
   user: {login: "fullsend-ai-review[bot]"}},
  {id: 4, body: ($m + "\n**Risk Assessment: low (1/5)**"),
   performed_via_github_app: null,
   user: {login: "contributor"}}
]' > "${TMP_ROOT}/comments.json"

# A comment matched only by user.login (no performed_via_github_app).
jq -n --arg m "${MARKER}" '[
  {id: 5, body: ($m + "\n**Risk Assessment: high (4/5)**"),
   performed_via_github_app: null,
   user: {login: "custom-review[bot]"}},
  {id: 6, body: ($m + "\n**Risk Assessment: low (1/5)**"),
   performed_via_github_app: null,
   user: {login: "fullsend-ai-review[bot]"}}
]' > "${TMP_ROOT}/comments-login.json"

# Only a plain user's forged comment.
jq -n --arg m "${MARKER}" '[
  {id: 7, body: ($m + "\n**Risk Assessment: low (1/5)**"),
   performed_via_github_app: null,
   user: {login: "custom-review"}}
]' > "${TMP_ROOT}/comments-forged.json"

# run_snippet <fixture> <slug|--unset> — prints the selected comment id,
# or nothing when no comment matched.
run_snippet() {
  local fixture="$1" slug="$2"
  local -a slug_env=(-u FULLSEND_SLUG)
  if [[ "${slug}" != "--unset" ]]; then
    slug_env=("FULLSEND_SLUG=${slug}")
  fi
  # shellcheck disable=SC2016 # expanded by the inner bash
  env "${slug_env[@]}" \
    PATH="${TMP_ROOT}/bin:${PATH}" \
    COMMENTS_FIXTURE="${fixture}" \
    REPO_FULL_NAME=example/repo PR_NUMBER=10 \
    bash -c "${SNIPPET}"$'\n''test -z "${PRIOR_RISK_COMMENT}" || jq -r .id <<<"${PRIOR_RISK_COMMENT}"'
}

assert_selects() {
  local name="$1" fixture="$2" slug="$3" expected="$4" got
  if ! got="$(run_snippet "${fixture}" "${slug}")"; then
    fail "${name} — snippet failed"
    return
  fi
  if [[ "${got}" == "${expected}" ]]; then
    pass "${name}"
  else
    fail "${name} — expected '${expected}', got '${got}'"
  fi
}

assert_selects "overridden slug finds its own prior assessment" \
  "${TMP_ROOT}/comments.json" custom-review 1
assert_selects "unset FULLSEND_SLUG falls back to fullsend-ai-review" \
  "${TMP_ROOT}/comments.json" --unset 3
assert_selects "empty FULLSEND_SLUG falls back to fullsend-ai-review" \
  "${TMP_ROOT}/comments.json" "" 3
assert_selects "overridden slug matches the App's [bot] login" \
  "${TMP_ROOT}/comments-login.json" custom-review 5
assert_selects "default slug matches the default App's [bot] login" \
  "${TMP_ROOT}/comments-login.json" --unset 6
assert_selects "a plain user's comment is never selected" \
  "${TMP_ROOT}/comments-forged.json" custom-review ""
assert_selects "an unrelated slug finds no prior assessment" \
  "${TMP_ROOT}/comments.json" other-review ""

if grep -qF '"fullsend-ai-review"' <<<"${SNIPPET}"; then
  fail "snippet hard-codes the fullsend-ai-review slug in the jq filter"
else
  pass "snippet does not hard-code the review App slug in the jq filter"
fi

if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi

echo "All PR review prior risk assessment tests passed"
