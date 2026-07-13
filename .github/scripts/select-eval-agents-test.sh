#!/usr/bin/env bash
# Tests for select-eval-agents.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELECT_SCRIPT="${SCRIPT_DIR}/select-eval-agents.sh"
FAILURES=0
TESTS=0

fail() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "PASS: $1"
}

run_test() {
  TESTS=$((TESTS + 1))
}

# Create a temporary repo-like structure for each test
setup_fixture() {
  local tmpdir
  tmpdir="$(mktemp -d)"

  # Minimal harness files referencing known paths
  mkdir -p "$tmpdir/harness" "$tmpdir/eval/triage/cases" "$tmpdir/eval/review/cases"

  cat > "$tmpdir/harness/triage.yaml" << 'YAML'
agent: agents/triage.md
doc: docs/triage.md
policy: policies/triage.yaml
pre_script: scripts/pre-triage.sh
post_script: scripts/post-triage.sh
validation_loop:
  script: scripts/validate-output-schema.sh
  schema: schemas/triage-result.schema.json
host_files:
  - src: common/env/gcp-vertex.env
    dest: /sandbox/workspace/.env.d/gcp-vertex.env
  - src: env/triage.env
    dest: /sandbox/workspace/.env.d/triage.env
  - src: ${GOOGLE_APPLICATION_CREDENTIALS}
    dest: /tmp/.gcp-credentials.json
skills:
  - skills/issue-labels
YAML

  cat > "$tmpdir/harness/review.yaml" << 'YAML'
agent: agents/review.md
doc: docs/review.md
policy: policies/review.yaml
pre_script: scripts/pre-review.sh
post_script: scripts/post-review.sh
validation_loop:
  script: scripts/validate-output-schema.sh
  schema: schemas/review-result.schema.json
host_files:
  - src: common/env/gcp-vertex.env
    dest: /sandbox/workspace/.env.d/gcp-vertex.env
  - src: env/review.env
    dest: /sandbox/workspace/.env.d/review.env
  - src: ${GOOGLE_APPLICATION_CREDENTIALS}
    dest: /tmp/.gcp-credentials.json
skills:
  - skills/pr-review
  - skills/code-review
plugins:
  - plugins/gopls-lsp
YAML

  # Agent with no eval config — should never be selected
  cat > "$tmpdir/harness/code.yaml" << 'YAML'
agent: agents/code.md
doc: docs/code.md
policy: policies/code.yaml
pre_script: scripts/pre-code.sh
post_script: scripts/post-code.sh
host_files:
  - src: env/code.env
    dest: /sandbox/workspace/.env.d/code.env
YAML

  # Minimal eval configs (just need to exist)
  echo "dataset: {}" > "$tmpdir/eval/triage/eval.yaml"
  echo "dataset: {}" > "$tmpdir/eval/review/eval.yaml"
  # No eval/code/eval.yaml — intentionally missing

  echo "$tmpdir"
}

cleanup_fixture() {
  rm -rf "$1"
}

# ---------------------------------------------------------------------------
# Test: modifying a harness file selects that agent
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "harness/triage.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "triage" ]]; then
  pass "harness file change selects agent"
else
  fail "harness file change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: modifying env file selects agent that references it
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "env/triage.env" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "triage" ]]; then
  pass "env file change selects agent via harness reference"
else
  fail "env file change selects agent via harness reference (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: modifying shared file selects all agents referencing it
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "common/env/gcp-vertex.env" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
EXPECTED=$(printf "review\ntriage")
if [[ "$RESULT" == "$EXPECTED" ]]; then
  pass "shared file change selects all referencing agents"
else
  fail "shared file change selects all referencing agents (got: '$RESULT', expected: '$EXPECTED')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: modifying agent prompt selects that agent
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "agents/review.md" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "review" ]]; then
  pass "agent prompt change selects agent"
else
  fail "agent prompt change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: modifying eval case selects that agent
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "eval/triage/cases/happy-path.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "triage" ]]; then
  pass "eval case change selects agent"
else
  fail "eval case change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: modifying eval config selects that agent
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "eval/review/eval.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "review" ]]; then
  pass "eval config change selects agent"
else
  fail "eval config change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: modifying a file under a skill directory selects the agent
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "skills/issue-labels/README.md" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "triage" ]]; then
  pass "skill subpath change selects agent"
else
  fail "skill subpath change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: modifying a plugin directory file selects the agent
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "plugins/gopls-lsp/init.sh" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "review" ]]; then
  pass "plugin subpath change selects agent"
else
  fail "plugin subpath change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: modifying files for both agents selects both
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(printf "env/triage.env\nagents/review.md\n" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
EXPECTED=$(printf "review\ntriage")
if [[ "$RESULT" == "$EXPECTED" ]]; then
  pass "multiple agents selected from mixed changes"
else
  fail "multiple agents selected from mixed changes (got: '$RESULT', expected: '$EXPECTED')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: agent without eval config is NOT selected
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "agents/code.md" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ -z "$RESULT" ]]; then
  pass "agent without eval config is not selected"
else
  fail "agent without eval config is not selected (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: unrelated file selects nothing
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "README.md" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ -z "$RESULT" ]]; then
  pass "unrelated file selects nothing"
else
  fail "unrelated file selects nothing (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: shared script referenced by multiple harness files
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "scripts/validate-output-schema.sh" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
EXPECTED=$(printf "review\ntriage")
if [[ "$RESULT" == "$EXPECTED" ]]; then
  pass "shared script selects all referencing agents"
else
  fail "shared script selects all referencing agents (got: '$RESULT', expected: '$EXPECTED')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: forge-level pre/post scripts are also tracked
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
# Add forge scripts to the triage harness
cat >> "$FIXTURE/harness/triage.yaml" << 'YAML'
forge:
  github:
    pre_script: scripts/forge-pre-triage.sh
    post_script: scripts/forge-post-triage.sh
YAML
RESULT=$(echo "scripts/forge-pre-triage.sh" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "triage" ]]; then
  pass "forge script change selects agent"
else
  fail "forge script change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: schema file change selects agent
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "schemas/triage-result.schema.json" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "triage" ]]; then
  pass "schema file change selects agent"
else
  fail "schema file change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: variable-expanded host_files (${VAR}) are ignored
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo '${GOOGLE_APPLICATION_CREDENTIALS}' | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ -z "$RESULT" ]]; then
  pass "variable host_file paths are ignored"
else
  fail "variable host_file paths are ignored (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== $TESTS tests, $FAILURES failures ==="
if [[ $FAILURES -gt 0 ]]; then
  exit 1
fi
