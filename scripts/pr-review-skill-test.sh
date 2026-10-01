#!/usr/bin/env bash
# pr-review-skill-test.sh — Lock the missing-sub-agent failure protocol.
#
# Prompt-only regression for fullsend-ai/agents#285: when pr-review
# sub-agent definition files cannot be loaded, the orchestrator must
# record sub-agent-failure findings and request-changes, not fall back
# to a single-pass code-review approval.
#
# Run from the repo root: bash scripts/pr-review-skill-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${REPO_ROOT}/skills/pr-review/SKILL.md"
PREFLIGHT="${REPO_ROOT}/skills/pr-review/references/missing-sub-agents.md"
AGENT="${REPO_ROOT}/agents/review.md"
CODE_REVIEW="${REPO_ROOT}/skills/code-review/SKILL.md"

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — $2"; FAILURES=$((FAILURES + 1)); }

require_file() {
  local name="$1"
  local file="$2"
  if [[ -f "${file}" ]]; then
    pass "${name}"
  else
    fail "${name}" "missing ${file}"
  fi
}

# Collapse wrapping so assertions match the protocol, not line breaks.
file_text() {
  tr '\n' ' ' < "$1" | tr -s ' '
}

require_grep() {
  local name="$1"
  local file="$2"
  local pattern="$3"
  if file_text "${file}" | grep -qE "${pattern}"; then
    pass "${name}"
  else
    fail "${name}" "pattern not found in ${file}: ${pattern}"
  fi
}

forbid_grep() {
  local name="$1"
  local file="$2"
  local pattern="$3"
  if file_text "${file}" | grep -qE "${pattern}"; then
    fail "${name}" "forbidden pattern in ${file}: ${pattern}"
  else
    pass "${name}"
  fi
}

# Scope a grep to the lines between (and including) a start and end
# heading, so a match elsewhere in the file (e.g. a roster footnote)
# cannot satisfy a check that a specific Process step does the wiring.
section_text() {
  local file="$1"
  local start_pattern="$2"
  local end_pattern="$3"
  # Pass patterns through ENVIRON rather than -v: POSIX awk runs -v
  # values through the same escape-sequence processing as string
  # literals, so a regex like '\*\*' can silently become a literal
  # '**' (varies by awk build — this is exactly what made
  # skill-3c-item4-excludes-subagent-failure pass on some awk builds
  # and fail on others despite identical file content). ENVIRON
  # entries are taken verbatim, so the pattern reaches the regex
  # engine unchanged.
  AWK_SECTION_START="${start_pattern}" AWK_SECTION_END="${end_pattern}" awk \
    '$0 ~ ENVIRON["AWK_SECTION_START"] {flag=1} flag {print} flag && $0 ~ ENVIRON["AWK_SECTION_END"] && $0 !~ ENVIRON["AWK_SECTION_START"] {exit}' \
    "${file}" | tr '\n' ' ' | tr -s ' '
}

require_grep_section() {
  local name="$1"
  local file="$2"
  local start_pattern="$3"
  local end_pattern="$4"
  local pattern="$5"
  if section_text "${file}" "${start_pattern}" "${end_pattern}" | grep -qE "${pattern}"; then
    pass "${name}"
  else
    fail "${name}" "pattern not found between ${start_pattern} and ${end_pattern} in ${file}: ${pattern}"
  fi
}

forbid_grep_section() {
  local name="$1"
  local file="$2"
  local start_pattern="$3"
  local end_pattern="$4"
  local pattern="$5"
  if section_text "${file}" "${start_pattern}" "${end_pattern}" | grep -qE "${pattern}"; then
    fail "${name}" "forbidden pattern found between ${start_pattern} and ${end_pattern} in ${file}: ${pattern}"
  else
    pass "${name}"
  fi
}

require_file "skill-present" "${SKILL}"
require_file "preflight-present" "${PREFLIGHT}"
require_file "agent-present" "${AGENT}"
require_file "code-review-present" "${CODE_REVIEW}"

# --- pr-review skill: pointer, step 5, and no failure-for-missing-files ---

require_grep "skill-links-preflight" "${SKILL}" \
  'references/missing-sub-agents.md'

# The roster line alone isn't enough — the dispatch step itself must
# send the orchestrator to the pre-flight protocol before it composes
# a spawn prompt, per issue #285 item 1.
require_grep_section "skill-step4-wires-preflight" "${SKILL}" \
  '^### 4\. Dispatch sub-agents' '^### 5\. Collect findings' \
  'references/missing-sub-agents\.md'

require_grep "skill-missing-files-step-5" "${SKILL}" \
  'Missing files: step 5'

require_grep "skill-step5-covers-missing-file" "${SKILL}" \
  'empty response, missing file'

require_grep "skill-step5-links-preflight" "${SKILL}" \
  "missing file.{0,20}step 4.s pre-flight"

require_grep "skill-challenger-exempts-subagent-failure" "${SKILL}" \
  'category: "sub-agent-failure".{0,15}findings'

# The prose exemption is not enough on its own — the fill-in template an
# orchestrator actually copies to build the challenger prompt must also
# exclude sub-agent-failure findings, not just say so in the paragraph
# above it. Scope to the 6d section so a match elsewhere can't satisfy this.
require_grep_section "skill-6d-template-excludes-subagent-failure" "${SKILL}" \
  '^#### 6d\. Challenger pass' '^#### 6e\.' \
  'Findings to challenge.{0,150}excluding.{0,20}sub-agent-failure'

forbid_grep_section "skill-6d-template-not-unqualified-all-findings" "${SKILL}" \
  '^#### 6d\. Challenger pass' '^#### 6e\.' \
  'JSON array of all findings from steps 6a'

# The skip rule's filtered predicate (excluding sub-agent-failure) must
# also be reflected in the three spots that restate the dispatch
# condition in prose, so a future edit can't revert just one of them
# without failing CI: the 6d lead-in sentence, step 3c item 4, and the
# dispatch-examples footnote.
require_grep_section "skill-6d-leadin-excludes-subagent-failure" "${SKILL}" \
  '^#### 6d\. Challenger pass' 'has not seen the orchestrator' \
  'excluding .category: "sub-agent-failure".{0,20}findings.{0,20}is non-empty'

require_grep_section "skill-3c-item4-excludes-subagent-failure" "${SKILL}" \
  '^4\. \*\*Challenger\*\*' '^This reuses the existing scope' \
  'produce findings excluding .category: "sub-agent-failure".'

require_grep_section "skill-dispatch-footnote-excludes-subagent-failure" "${SKILL}" \
  'Conditional — step 6d dispatches' '^#### 3c-1' \
  'produce findings excluding.{0,3}.category: "sub-agent-failure".'

# --- pre-flight reference: the protocol the issue requires ---

require_grep "preflight-pipeline-is-the-review" "${PREFLIGHT}" \
  'The sub-agent pipeline is the review'

require_grep "preflight-no-switch-to-code-review" "${PREFLIGHT}" \
  'Switch to the `code-review` skill'

require_grep "preflight-opus-tier-high" "${PREFLIGHT}" \
  'Opus-tier.*high'

require_grep "preflight-category" "${PREFLIGHT}" \
  '"category": "sub-agent-failure"'

require_grep "preflight-request-changes" "${PREFLIGHT}" \
  'makes the outcome `request-changes`'

require_grep "preflight-trusted-path-only" "${PREFLIGHT}" \
  'Do not rediscover this path with a Glob'

require_grep "preflight-excludes-pr-head" "${PREFLIGHT}" \
  '/sandbox/workspace/pr-head/'

require_grep "preflight-excludes-target-repo" "${PREFLIGHT}" \
  '/sandbox/workspace/target-repo/'

require_grep "preflight-no-approve-single-pass" "${PREFLIGHT}" \
  'Approve because a single-pass'

# --- review agent: routing and constraints ---

require_grep "agent-stays-on-pr-review" "${AGENT}" \
  'stays on `pr-review` and follows that skill'\''s missing-file protocol'

require_grep "agent-code-review-not-fallback" "${AGENT}" \
  'Do not use it as a fallback when `pr-review` sub-agent files are missing'

require_grep "agent-missing-files-completed-review" "${AGENT}" \
  'Missing sub-agent definition files are a completed review'

require_grep "agent-high-severity-opus" "${AGENT}" \
  'high severity for Opus-tier `correctness` and `security`'

require_grep "agent-request-changes-on-gap" "${AGENT}" \
  'high-severity finding forces the orchestrator to set `action` to `request-changes`'

require_grep "agent-sonnet-tier-info-severity" "${AGENT}" \
  'info severity for Sonnet-tier `intent-coherence`, `style-conventions`, `docs-currency`, and `cross-repo-contracts`'

require_grep "agent-info-not-automatic-request-changes" "${AGENT}" \
  'not automatically `request-changes`'

require_grep "agent-no-single-pass-code-review" "${AGENT}" \
  'Do not fall back to a single-pass `code-review`'

require_grep "agent-no-invent-prompt" "${AGENT}" \
  'do not invent a prompt and do not switch skills'

# Routing must not treat missing files as a reason to use code-review.
require_grep "agent-routing-unchanged-when-missing" "${AGENT}" \
  'Missing sub-agent files do not change that routing'

# --- code-review: do not invite pr-review to delegate here ---

forbid_grep "code-review-no-pr-review-delegate-example" "${CODE_REVIEW}" \
  'e\.g\., pr-review'

echo ""
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
