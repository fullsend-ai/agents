#!/usr/bin/env bash
# changed-since-prior-test.sh — Tests for the PR-vs-base delta used as
# changed_since_prior on re-review (issue #1091).
#
# Extracts the jq programs from the forge pr-review skills so the
# fixtures exercise the same filters the review agent runs.
#
# Run from the repo root: bash scripts/changed-since-prior-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILURES=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

GITHUB_SKILL="${REPO_ROOT}/skills/pr-review/github/SKILL.md"
GITLAB_SKILL="${REPO_ROOT}/skills/pr-review/gitlab/SKILL.md"

extract_jq() {
  local skill="$1"
  local cur_path="$2"
  python3 - "$skill" "$cur_path" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
cur = sys.argv[2]
pat = (
    r"jq -n -r --slurpfile cur "
    + re.escape(cur)
    + r" --slurpfile prior /sandbox/workspace/prior-pr-compare.json '\n(.*?)'"
)
match = re.search(pat, text, re.S)
if not match:
    sys.stderr.write(f"failed to extract jq from {sys.argv[1]}\n")
    sys.exit(1)
sys.stdout.write(match.group(1))
PY
}

assert_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"
  local exp_n act_n
  exp_n=$(printf '%s' "${expected}" | sed '/^$/d' | sort)
  act_n=$(printf '%s' "${actual}" | sed '/^$/d' | sort)
  if [[ "${exp_n}" == "${act_n}" ]]; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name}"
    echo "  expected: $(printf '%s' "${exp_n}" | tr '\n' ' ')"
    echo "  actual:   $(printf '%s' "${act_n}" | tr '\n' ' ')"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_file_absent() {
  local test_name="$1"
  local file="$2"
  local pattern="$3"
  if grep -F -q -- "${pattern}" "${file}"; then
    echo "FAIL: ${test_name} — '${pattern}' still present in ${file}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${test_name}"
  fi
}

assert_file_present() {
  local test_name="$1"
  local file="$2"
  local pattern="$3"
  if grep -F -q -- "${pattern}" "${file}"; then
    echo "PASS: ${test_name}"
  else
    echo "FAIL: ${test_name} — '${pattern}' missing from ${file}"
    FAILURES=$((FAILURES + 1))
  fi
}

run_jq() {
  local program="$1"
  local cur="$2"
  local prior="$3"
  jq -n -r --slurpfile cur "${cur}" --slurpfile prior "${prior}" "${program}"
}

GITHUB_JQ="$(extract_jq "${GITHUB_SKILL}" "/sandbox/workspace/pr-files.json")"
GITLAB_JQ="$(extract_jq "${GITLAB_SKILL}" "/sandbox/workspace/mr-changes.json")"

# --- Skill wiring ---

assert_file_absent "github-no-raw-head-compare" "${GITHUB_SKILL}" \
  'compare/${PRIOR_REVIEW_SHA}...${HEAD_SHA}'
assert_file_present "github-uses-base-to-prior-compare" "${GITHUB_SKILL}" \
  'compare/${BASE_SHA}...${PRIOR_REVIEW_SHA}'
assert_file_absent "gitlab-no-raw-head-compare-url" "${GITLAB_SKILL}" \
  'repository/compare?from=${PRIOR_REVIEW_SHA}&to=${HEAD_SHA}'
assert_file_present "gitlab-uses-base-to-prior-compare" "${GITLAB_SKILL}" \
  'from=${BASE_REF}&to=${PRIOR_REVIEW_SHA}&straight=false'
assert_file_present "orchestrator-reads-changed-since-prior-file" \
  "${REPO_ROOT}/skills/pr-review/SKILL.md" \
  "/sandbox/workspace/changed-since-prior.txt"

# --- GitHub fixtures ---
# prior-pr-compare.json is BASE_SHA...PRIOR_REVIEW_SHA (three-dot
# PR-vs-base at the prior review). pr-files.json is the current
# PR-vs-base list. Files that only changed on main never appear in
# either list.

cat > "${TMPDIR}/gh-cur.json" <<'EOF'
[
  {"filename": "go.mod", "sha": "aaa", "status": "modified"},
  {"filename": "go.sum", "sha": "bbb", "status": "modified"}
]
EOF

cat > "${TMPDIR}/gh-prior-same.json" <<'EOF'
{
  "total_commits": 1,
  "commits": [{"sha": "c1"}],
  "files": [
    {"filename": "go.mod", "sha": "aaa", "status": "modified"},
    {"filename": "go.sum", "sha": "bbb", "status": "modified"}
  ]
}
EOF

assert_eq "github-clean-rebase-empty-delta" "" \
  "$(run_jq "${GITHUB_JQ}" "${TMPDIR}/gh-cur.json" "${TMPDIR}/gh-prior-same.json")"

cat > "${TMPDIR}/gh-prior-mod-changed.json" <<'EOF'
{
  "total_commits": 1,
  "commits": [{"sha": "c1"}],
  "files": [
    {"filename": "go.mod", "sha": "oldaaa", "status": "modified"},
    {"filename": "go.sum", "sha": "bbb", "status": "modified"}
  ]
}
EOF

assert_eq "github-author-changed-pr-file" "go.mod" \
  "$(run_jq "${GITHUB_JQ}" "${TMPDIR}/gh-cur.json" "${TMPDIR}/gh-prior-mod-changed.json")"

cat > "${TMPDIR}/gh-cur-new-file.json" <<'EOF'
[
  {"filename": "go.mod", "sha": "aaa", "status": "modified"},
  {"filename": "go.sum", "sha": "bbb", "status": "modified"},
  {"filename": "README.md", "sha": "ccc", "status": "added"}
]
EOF

assert_eq "github-new-file-in-pr" "README.md" \
  "$(run_jq "${GITHUB_JQ}" "${TMPDIR}/gh-cur-new-file.json" "${TMPDIR}/gh-prior-same.json")"

cat > "${TMPDIR}/gh-prior-extra-file.json" <<'EOF'
{
  "total_commits": 1,
  "commits": [{"sha": "c1"}],
  "files": [
    {"filename": "go.mod", "sha": "aaa", "status": "modified"},
    {"filename": "go.sum", "sha": "bbb", "status": "modified"},
    {"filename": "docs/old.md", "sha": "ddd", "status": "added"}
  ]
}
EOF

# A file dropped from the PR is not in the current PR-vs-base list, so
# it cannot re-qualify sub-agents (intersection with current PR files).
assert_eq "github-dropped-from-pr-excluded" "" \
  "$(run_jq "${GITHUB_JQ}" "${TMPDIR}/gh-cur.json" "${TMPDIR}/gh-prior-extra-file.json")"

# After a rebase, BASE...PRIOR can still list main-only files because
# the merge-base of the unrebased prior SHA and the new base is the
# old base. Those files must not survive the intersection.
cat > "${TMPDIR}/gh-prior-with-main.json" <<'EOF'
{
  "total_commits": 15,
  "commits": [{"sha": "c1"}],
  "files": [
    {"filename": "go.mod", "sha": "aaa", "status": "modified"},
    {"filename": "go.sum", "sha": "bbb", "status": "modified"},
    {"filename": "docs/review.md", "sha": "d1", "status": "modified"}
  ]
}
EOF

assert_eq "github-rebase-main-files-excluded" "" \
  "$(run_jq "${GITHUB_JQ}" "${TMPDIR}/gh-cur.json" "${TMPDIR}/gh-prior-with-main.json")"

cat > "${TMPDIR}/gh-prior-truncated-commits.json" <<'EOF'
{
  "total_commits": 251,
  "commits": [{"sha": "c1"}],
  "files": [
    {"filename": "go.mod", "sha": "aaa", "status": "modified"}
  ]
}
EOF

assert_eq "github-truncated-total-commits" "all" \
  "$(run_jq "${GITHUB_JQ}" "${TMPDIR}/gh-cur.json" "${TMPDIR}/gh-prior-truncated-commits.json")"

python3 - "${TMPDIR}/gh-prior-300-files.json" <<'PY'
import json, sys
files = [{"filename": f"f{i}", "sha": "x", "status": "modified"} for i in range(300)]
json.dump({"total_commits": 1, "commits": [{"sha": "c1"}], "files": files}, open(sys.argv[1], "w"))
PY

assert_eq "github-truncated-300-files" "all" \
  "$(run_jq "${GITHUB_JQ}" "${TMPDIR}/gh-cur.json" "${TMPDIR}/gh-prior-300-files.json")"

# --- GitLab fixtures ---

cat > "${TMPDIR}/gl-cur.json" <<'EOF'
{
  "changes": [
    {"new_path": "go.mod", "diff": "@@ pin @@", "new_file": false, "deleted_file": false},
    {"new_path": "go.sum", "diff": "@@ sum @@", "new_file": false, "deleted_file": false}
  ]
}
EOF

cat > "${TMPDIR}/gl-prior-same.json" <<'EOF'
{
  "compare_timeout": false,
  "diffs": [
    {"new_path": "go.mod", "diff": "@@ pin @@", "new_file": false, "deleted_file": false},
    {"new_path": "go.sum", "diff": "@@ sum @@", "new_file": false, "deleted_file": false}
  ]
}
EOF

assert_eq "gitlab-clean-rebase-empty-delta" "" \
  "$(run_jq "${GITLAB_JQ}" "${TMPDIR}/gl-cur.json" "${TMPDIR}/gl-prior-same.json")"

cat > "${TMPDIR}/gl-prior-mod-changed.json" <<'EOF'
{
  "compare_timeout": false,
  "diffs": [
    {"new_path": "go.mod", "diff": "@@ old pin @@", "new_file": false, "deleted_file": false},
    {"new_path": "go.sum", "diff": "@@ sum @@", "new_file": false, "deleted_file": false}
  ]
}
EOF

assert_eq "gitlab-author-changed-mr-file" "go.mod" \
  "$(run_jq "${GITLAB_JQ}" "${TMPDIR}/gl-cur.json" "${TMPDIR}/gl-prior-mod-changed.json")"

cat > "${TMPDIR}/gl-cur-new-file.json" <<'EOF'
{
  "changes": [
    {"new_path": "go.mod", "diff": "@@ pin @@", "new_file": false, "deleted_file": false},
    {"new_path": "go.sum", "diff": "@@ sum @@", "new_file": false, "deleted_file": false},
    {"new_path": "README.md", "diff": "@@ docs @@", "new_file": true, "deleted_file": false}
  ]
}
EOF

assert_eq "gitlab-new-file-in-mr" "README.md" \
  "$(run_jq "${GITLAB_JQ}" "${TMPDIR}/gl-cur-new-file.json" "${TMPDIR}/gl-prior-same.json")"

# After a rebase, from=base&to=prior can still list target-only files
# because the merge-base of the unrebased prior SHA and the new target
# is the old target. Those files must not survive the intersection
# with the current MR-vs-base list (mirrors github-rebase-main-files-excluded).
cat > "${TMPDIR}/gl-prior-with-target.json" <<'EOF'
{
  "compare_timeout": false,
  "diffs": [
    {"new_path": "go.mod", "diff": "@@ pin @@", "new_file": false, "deleted_file": false},
    {"new_path": "go.sum", "diff": "@@ sum @@", "new_file": false, "deleted_file": false},
    {"new_path": "docs/review.md", "diff": "@@ target-only @@", "new_file": false, "deleted_file": false}
  ]
}
EOF

assert_eq "gitlab-rebase-target-files-excluded" "" \
  "$(run_jq "${GITLAB_JQ}" "${TMPDIR}/gl-cur.json" "${TMPDIR}/gl-prior-with-target.json")"

cat > "${TMPDIR}/gl-prior-timeout.json" <<'EOF'
{
  "compare_timeout": true,
  "diffs": [
    {"new_path": "go.mod", "diff": "@@ pin @@", "new_file": false, "deleted_file": false}
  ]
}
EOF

assert_eq "gitlab-compare-timeout" "all" \
  "$(run_jq "${GITLAB_JQ}" "${TMPDIR}/gl-cur.json" "${TMPDIR}/gl-prior-timeout.json")"

# overflow: true on the current mr-changes.json means the current file
# list may be truncated; the intersection would otherwise silently
# shrink to whatever survived the truncation.
cat > "${TMPDIR}/gl-cur-overflow.json" <<'EOF'
{
  "overflow": true,
  "changes": []
}
EOF

assert_eq "gitlab-current-overflow" "all" \
  "$(run_jq "${GITLAB_JQ}" "${TMPDIR}/gl-cur-overflow.json" "${TMPDIR}/gl-prior-same.json")"

# A binary or over-the-size-limit file has no patch text (too_large /
# collapsed, or simply an empty diff) on both the prior compare and the
# current MR-vs-base snapshot, so a naive signature comparison sees no
# change and drops the file — even though it is not a pure add/delete.
cat > "${TMPDIR}/gl-cur-unenumerable.json" <<'EOF'
{
  "changes": [
    {"new_path": "go.mod", "diff": "@@ pin @@", "new_file": false, "deleted_file": false},
    {"new_path": "assets/logo.png", "diff": "", "new_file": false, "deleted_file": false, "too_large": true}
  ]
}
EOF

cat > "${TMPDIR}/gl-prior-unenumerable.json" <<'EOF'
{
  "compare_timeout": false,
  "diffs": [
    {"new_path": "go.mod", "diff": "@@ pin @@", "new_file": false, "deleted_file": false},
    {"new_path": "assets/logo.png", "diff": "", "new_file": false, "deleted_file": false, "too_large": true}
  ]
}
EOF

assert_eq "gitlab-unenumerable-diff-fails-closed" "all" \
  "$(run_jq "${GITLAB_JQ}" "${TMPDIR}/gl-cur-unenumerable.json" "${TMPDIR}/gl-prior-unenumerable.json")"

# A pure add of a binary file has an empty diff on both sides too, but
# new_file carries the signal directly — it must not force "all".
cat > "${TMPDIR}/gl-cur-new-binary.json" <<'EOF'
{
  "changes": [
    {"new_path": "go.mod", "diff": "@@ pin @@", "new_file": false, "deleted_file": false},
    {"new_path": "assets/logo.png", "diff": "", "new_file": true, "deleted_file": false}
  ]
}
EOF

cat > "${TMPDIR}/gl-prior-new-binary.json" <<'EOF'
{
  "compare_timeout": false,
  "diffs": [
    {"new_path": "go.mod", "diff": "@@ pin @@", "new_file": false, "deleted_file": false},
    {"new_path": "assets/logo.png", "diff": "", "new_file": true, "deleted_file": false}
  ]
}
EOF

assert_eq "gitlab-new-binary-file-not-unenumerable" "" \
  "$(run_jq "${GITLAB_JQ}" "${TMPDIR}/gl-cur-new-binary.json" "${TMPDIR}/gl-prior-new-binary.json")"

if [[ "${FAILURES}" -ne 0 ]]; then
  echo ""
  echo "${FAILURES} test(s) failed"
  exit 1
fi

echo ""
echo "All changed-since-prior tests passed"
