#!/usr/bin/env bash
# pr-review-body-format-test.sh — Lock the review-body formatting contract
# in skills/pr-review/SKILL.md (issue #1366).
#
# The review agent builds `body` from that skill's template and
# Formatting rules. This test asserts the approve-with-findings fold
# and the omit-empty-section rules stay in the prompt.
#
# Run from the repo root:
#   bash scripts/pr-review-body-format-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/pr-review/SKILL.md"

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — $2"; FAILURES=$((FAILURES + 1)); }

if [[ ! -f "${SKILL}" ]]; then
  echo "FAIL: skill missing at ${SKILL}"
  exit 1
fi

SKILL_TEXT="$(cat "${SKILL}")"

# Extract the "Formatting rules" bullet list through the next heading so
# assertions target the contract, not incidental mentions elsewhere.
FORMAT_RULES="$(python3 - "${SKILL}" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
start = text.find("**Formatting rules:**")
if start < 0:
    sys.stderr.write("FAIL: Formatting rules heading not found\n")
    sys.exit(2)
rest = text[start:]
# Next markdown heading at column 0 after the rules block.
idx = rest.find("\nIf `PRIOR_REVIEW_PROVENANCE`")
if idx < 0:
    sys.stderr.write("FAIL: could not bound Formatting rules section\n")
    sys.exit(2)
print(rest[:idx])
PY
)"

FLAT_RULES="$(python3 -c 'import re,sys; print(re.sub(r"\s+", " ", sys.stdin.read()))' <<< "${FORMAT_RULES}")"

# Extract the fenced approve-with-findings example block (the one
# introduced for the approve+findings fold), distinct from the unfolded
# request-changes/comment/reject skeleton above it in the file.
APPROVE_EXAMPLE="$(python3 - "${SKILL}" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
marker = "Use this form when `action` is `approve` with findings"
start = text.find(marker)
if start < 0:
    sys.stderr.write("FAIL: approve-with-findings example intro not found\n")
    sys.exit(2)
rest = text[start:]
fence_start = rest.find("```markdown")
if fence_start < 0:
    sys.stderr.write("FAIL: approve-with-findings fenced block not found\n")
    sys.exit(2)
rest = rest[fence_start + len("```markdown"):]
fence_end = rest.find("```")
if fence_end < 0:
    sys.stderr.write("FAIL: approve-with-findings fenced block not closed\n")
    sys.exit(2)
print(rest[:fence_end])
PY
)"

# --- Approve-with-findings fold ---
if grep -qF '<summary>Findings</summary>' <<< "${SKILL_TEXT}"; then
  pass "skill-has-findings-summary"
else
  fail "skill-has-findings-summary" "missing <summary>Findings</summary> wrapper"
fi

if grep -qF '<details><summary>Findings</summary>' <<< "${FORMAT_RULES}" \
  || grep -qF 'multiline `<details>` block' <<< "${FORMAT_RULES}"; then
  pass "format-rules-fold-approve-findings"
else
  fail "format-rules-fold-approve-findings" \
    "Formatting rules must wrap ### Findings in a details/summary block"
fi

if printf '%s' "${FLAT_RULES}" | grep -qF \
  'When `action` is `approve` with findings, wrap `### Findings`'; then
  pass "format-rules-gated-on-approve"
else
  fail "format-rules-gated-on-approve" \
    "fold instruction must be gated on action approve in a single phrase"
fi

# Non-approve outcomes stay unfolded. Match the exact wrap-exclusion
# clause (not just incidental co-occurrence of the three action names,
# e.g. in the unrelated "No footer" bullet).
if printf '%s' "${FLAT_RULES}" | grep -qF \
  'do not wrap `request-changes`, `comment`, or `reject`'; then
  pass "format-rules-non-approve-stay-unfolded"
else
  fail "format-rules-non-approve-stay-unfolded" \
    "Formatting rules must keep request-changes/comment/reject unfolded via an explicit wrap-exclusion clause"
fi

# Zero-findings short-circuit is unchanged (no wrapper).
if grep -q 'Looks good to me' <<< "${FORMAT_RULES}"; then
  pass "format-rules-lgtm-short-circuit"
else
  fail "format-rules-lgtm-short-circuit" \
    "Formatting rules missing Looks good to me short-circuit"
fi

if printf '%s' "${FLAT_RULES}" | grep -qi 'zero findings' \
  && printf '%s' "${FLAT_RULES}" | grep -q 'no wrapper'; then
  pass "format-rules-zero-findings-no-wrapper"
else
  fail "format-rules-zero-findings-no-wrapper" \
    "zero-findings path must say no wrapper"
fi

# --- Omit empty sections / placeholders ---
if grep -q 'Only include sections that have content' <<< "${FORMAT_RULES}"; then
  pass "format-rules-omit-empty-sections"
else
  fail "format-rules-omit-empty-sections" \
    "must instruct omitting empty sections, not only empty severity headings"
fi

if grep -q '"None"' <<< "${FORMAT_RULES}" \
  && grep -q '"N/A"' <<< "${FORMAT_RULES}"; then
  pass "format-rules-forbid-placeholders"
else
  fail "format-rules-forbid-placeholders" \
    "must forbid None/N/A placeholders for empty sections"
fi

# The approve-with-findings fenced template (not the formatting-rules
# prose) must actually illustrate the multiline <details> convention:
# `## Review` outside, a standalone `<details>` line, `<summary>` on its
# own line, a blank line before `### Findings`, and a closing </details>.
if [[ -z "${APPROVE_EXAMPLE}" ]]; then
  fail "skill-template-approve-wraps-findings" "approve-with-findings example block not found"
elif grep -qF '## Review' <<< "${APPROVE_EXAMPLE}" \
  && grep -qxF '<details>' <<< "${APPROVE_EXAMPLE}" \
  && grep -qxF '<summary>Findings</summary>' <<< "${APPROVE_EXAMPLE}" \
  && grep -qF '### Findings' <<< "${APPROVE_EXAMPLE}" \
  && grep -qxF '</details>' <<< "${APPROVE_EXAMPLE}"; then
  pass "skill-template-approve-wraps-findings"
else
  fail "skill-template-approve-wraps-findings" \
    "approve-with-findings fenced example must show ## Review outside a multiline <details>/<summary>Findings</summary> block wrapping ### Findings"
fi

# The blank line after <summary>Findings</summary> is required for
# GitHub-flavored markdown to render the nested heading/list, not literal
# text.
SUMMARY_LINE="$(grep -n -x '<summary>Findings</summary>' <<< "${APPROVE_EXAMPLE}" | head -1 | cut -d: -f1)"
NEXT_LINE="$(sed -n "$((SUMMARY_LINE + 1))p" <<< "${APPROVE_EXAMPLE}")"
if [[ -n "${SUMMARY_LINE}" && -z "${NEXT_LINE}" ]]; then
  pass "skill-template-blank-line-after-summary"
else
  fail "skill-template-blank-line-after-summary" \
    "must have a blank line immediately after <summary>Findings</summary>"
fi

if [[ "${FAILURES}" -ne 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
