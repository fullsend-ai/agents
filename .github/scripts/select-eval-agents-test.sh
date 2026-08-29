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
policy: policies/base.yaml
openshell:
  profiles:
    - profiles/fullsend-vertex-ai.yaml
providers:
  - providers/vertex-ai.yaml
pre_script: scripts/pre-triage.sh
post_script: scripts/post-triage.sh
validation_loop:
  script: scripts/validate-output-schema.sh
  schema: schemas/triage-result.schema.json
host_files:
  - src: env/gcp-vertex.env
    dest: /sandbox/workspace/.env.d/gcp-vertex.env
  - src: ${GOOGLE_APPLICATION_CREDENTIALS}
    dest: /tmp/.gcp-credentials.json
overlays:
  - when: 'has(event.source) && event.source.system == "github"'
    providers:
      - providers/github-ro.yaml
    openshell:
      profiles:
        - profiles/fullsend-github-ro.yaml
    skills:
      - skills/github-forge
      - skills/issue-labels/github
    host_files:
      - src: env/github/triage.env
        dest: /sandbox/workspace/.env.d/triage.env
  - when: 'has(event.source) && event.source.system == "gitlab"'
    providers:
      - providers/gitlab-rw.yaml
    openshell:
      profiles:
        - profiles/fullsend-gitlab-rw.yaml
    skills:
      - skills/gitlab-forge
      - skills/issue-labels/gitlab
    host_files:
      - src: env/gitlab/triage.env
        dest: /sandbox/workspace/.env.d/triage.env
YAML

  cat > "$tmpdir/harness/review.yaml" << 'YAML'
agent: agents/review.md
doc: docs/review.md
policy: policies/base.yaml
openshell:
  profiles:
    - profiles/fullsend-vertex-ai.yaml
providers:
  - providers/vertex-ai.yaml
validation_loop:
  script: scripts/validate-output-schema.sh
  schema: schemas/review-result.schema.json
host_files:
  - src: env/gcp-vertex.env
    dest: /sandbox/workspace/.env.d/gcp-vertex.env
  - src: ${GOOGLE_APPLICATION_CREDENTIALS}
    dest: /tmp/.gcp-credentials.json
skills:
  - skills/pr-review
  - skills/code-review
plugins:
  - plugins/gopls-lsp
forge:
  github:
    providers:
      - providers/github-ro.yaml
    openshell:
      profiles:
        - profiles/fullsend-github-ro.yaml
    pre_script: scripts/pre-review.sh
    post_script: scripts/post-review.sh
    skills:
      - skills/github-forge
      - skills/issue-labels/github
      - skills/pr-review/github
    host_files:
      - src: env/github/review.env
        dest: /sandbox/workspace/.env.d/review.env
  gitlab:
    providers:
      - providers/gitlab-ro.yaml
    openshell:
      profiles:
        - profiles/fullsend-gitlab-ro.yaml
    pre_script: scripts/pre-review.sh
    post_script: scripts/post-review.sh
    skills:
      - skills/gitlab-forge
      - skills/issue-labels/gitlab
      - skills/pr-review/gitlab
    host_files:
      - src: env/gitlab/review.env
        dest: /sandbox/workspace/.env.d/review.env
YAML

  # Agent with no eval config — should never be selected
  cat > "$tmpdir/harness/code.yaml" << 'YAML'
agent: agents/code.md
doc: docs/code.md
policy: policies/base.yaml
pre_script: scripts/pre-code.sh
post_script: scripts/post-code.sh
host_files:
  - src: env/gcp-vertex.env
    dest: /sandbox/workspace/.env.d/gcp-vertex.env
  - src: env/ssl-cainfo.env
    dest: /sandbox/workspace/.env.d/ssl-cainfo.env
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
# Test: modifying shared policy file selects all referencing agents
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "policies/base.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
EXPECTED=$(printf "review\ntriage")
if [[ "$RESULT" == "$EXPECTED" ]]; then
  pass "shared policy change selects all referencing agents"
else
  fail "shared policy change selects all referencing agents (got: '$RESULT', expected: '$EXPECTED')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: modifying shared file selects all agents referencing it
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "env/gcp-vertex.env" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
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
RESULT=$(echo "skills/issue-labels/github/README.md" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
EXPECTED=$'review\ntriage'
if [[ "$RESULT" == "$EXPECTED" ]]; then
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
RESULT=$(printf "agents/triage.md\nagents/review.md\n" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
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
RESULT=$(echo "scripts/pre-review.sh" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "review" ]]; then
  pass "forge script change selects agent"
else
  fail "forge script change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: forge-level policy, skills, and host_files are tracked
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "skills/gitlab-forge/SKILL.md" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
EXPECTED=$'review\ntriage'
if [[ "$RESULT" == "$EXPECTED" ]]; then
  pass "forge skill subpath change selects agent"
else
  fail "forge skill subpath change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "providers/gitlab-rw.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "triage" ]]; then
  pass "forge provider change selects agent"
else
  fail "forge provider change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "env/gitlab/triage.env" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "triage" ]]; then
  pass "forge host_file change selects agent"
else
  fail "forge host_file change selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: forge-level providers and openshell profiles are tracked
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "providers/github-ro.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
EXPECTED=$(printf "review\ntriage")
if [[ "$RESULT" == "$EXPECTED" ]]; then
  pass "forge provider change selects all referencing agents"
else
  fail "forge provider change selects all referencing agents (got: '$RESULT', expected: '$EXPECTED')"
fi
cleanup_fixture "$FIXTURE"

run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "profiles/fullsend-github-ro.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
EXPECTED=$(printf "review\ntriage")
if [[ "$RESULT" == "$EXPECTED" ]]; then
  pass "forge openshell profile change selects all referencing agents"
else
  fail "forge openshell profile change selects all referencing agents (got: '$RESULT', expected: '$EXPECTED')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: top-level providers and openshell profiles are tracked
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "providers/vertex-ai.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
EXPECTED=$(printf "review\ntriage")
if [[ "$RESULT" == "$EXPECTED" ]]; then
  pass "top-level provider change selects all referencing agents"
else
  fail "top-level provider change selects all referencing agents (got: '$RESULT', expected: '$EXPECTED')"
fi
cleanup_fixture "$FIXTURE"

run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "profiles/fullsend-vertex-ai.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
EXPECTED=$(printf "review\ntriage")
if [[ "$RESULT" == "$EXPECTED" ]]; then
  pass "top-level openshell profile change selects all referencing agents"
else
  fail "top-level openshell profile change selects all referencing agents (got: '$RESULT', expected: '$EXPECTED')"
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
# Test: embedded variable references (mid-path) are also ignored
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
# Overwrite triage harness with an embedded-variable host_file entry
cat > "$FIXTURE/harness/triage.yaml" << 'YAML'
agent: agents/triage.md
doc: docs/triage.md
policy: policies/base.yaml
host_files:
  - src: env/gcp-vertex.env
    dest: /sandbox/workspace/.env.d/gcp-vertex.env
  - src: env/${AGENT_NAME}.env
    dest: /sandbox/workspace/.env.d/agent.env
YAML
RESULT=$(echo 'env/${AGENT_NAME}.env' | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ -z "$RESULT" ]]; then
  pass "embedded variable host_file paths are ignored"
else
  fail "embedded variable host_file paths are ignored (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: malformed harness YAML causes failure (not silent skip)
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
echo "not: valid: yaml: [[[" > "$FIXTURE/harness/triage.yaml"
if OUTPUT=$(echo "agents/triage.md" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" 2>&1); then
  fail "malformed YAML should cause nonzero exit (got success, output: '$OUTPUT')"
else
  pass "malformed YAML causes nonzero exit"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: invalid agent name (contains special chars) causes failure
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
mkdir -p "$FIXTURE/harness" "$FIXTURE/eval/bad\$(name)/cases"
echo "agent: agents/bad.md" > "$FIXTURE/harness/bad\$(name).yaml"
echo "dataset: {}" > "$FIXTURE/eval/bad\$(name)/eval.yaml"
if OUTPUT=$(echo "agents/bad.md" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" 2>&1); then
  fail "invalid agent name should cause nonzero exit (got success, output: '$OUTPUT')"
else
  pass "invalid agent name causes nonzero exit"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: harness with all variable refs does not fail (grep -v exits 1)
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
# Overwrite triage harness so every tracked field is a variable
cat > "$FIXTURE/harness/triage.yaml" << 'YAML'
agent: ${AGENT_PATH}
doc: ${DOC_PATH}
policy: ${POLICY_PATH}
host_files:
  - src: ${CREDS}
    dest: /tmp/creds
YAML
# Changing the harness file itself should still select the agent
RESULT=$(echo "harness/triage.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ "$RESULT" == "triage" ]]; then
  pass "all-variable harness does not fail; harness change still selects agent"
else
  fail "all-variable harness does not fail; harness change still selects agent (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: empty stdin selects nothing
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo -n "" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
if [[ -z "$RESULT" ]]; then
  pass "empty stdin selects nothing"
else
  fail "empty stdin selects nothing (got: '$RESULT')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: modifying a profile file selects all agents referencing it
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "profiles/fullsend-vertex-ai.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
EXPECTED=$(printf "review\ntriage")
if [[ "$RESULT" == "$EXPECTED" ]]; then
  pass "profile change selects all referencing agents"
else
  fail "profile change selects all referencing agents (got: '$RESULT', expected: '$EXPECTED')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: modifying a provider file selects all agents referencing it
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(echo "providers/github-ro.yaml" | "$SELECT_SCRIPT" --repo-root "$FIXTURE" | sort)
EXPECTED=$(printf "review\ntriage")
if [[ "$RESULT" == "$EXPECTED" ]]; then
  pass "provider change selects all referencing agents"
else
  fail "provider change selects all referencing agents (got: '$RESULT', expected: '$EXPECTED')"
fi
cleanup_fixture "$FIXTURE"

# ---------------------------------------------------------------------------
# Test: duplicate file inputs produce deduplicated agent output
# ---------------------------------------------------------------------------
run_test
FIXTURE="$(setup_fixture)"
RESULT=$(printf "agents/triage.md\nagents/triage.md\nagents/triage.md\n" | "$SELECT_SCRIPT" --repo-root "$FIXTURE")
LINES=$(echo "$RESULT" | grep -c "triage")
if [[ "$LINES" -eq 1 ]]; then
  pass "duplicate file inputs produce single agent output"
else
  fail "duplicate file inputs produce single agent output (got $LINES lines: '$RESULT')"
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
