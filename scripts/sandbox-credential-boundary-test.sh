#!/usr/bin/env bash
# sandbox-credential-boundary-test.sh — Verify denylisted credentials
# never appear in sandbox expansion paths across all harness files.
#
# The "sandbox expansion denylist" prevents credentials from leaking
# into the sandbox through two paths:
#
#   1. env.sandbox values — catches both direct keys (JIRA_TOKEN: "...")
#      and aliases (LEAK: "${JIRA_TOKEN}") that would expand the real
#      credential into the sandbox under a different name.
#
#   2. host_files with expand: true — catches expanded env files that
#      reference a denylisted variable (e.g. export FOO="${JIRA_TOKEN}").
#
# This is defense-in-depth: even if a child overlay or harness
# regression re-introduces a denylisted credential, this test catches
# it before merge.
#
# Run from the repo root: bash scripts/sandbox-credential-boundary-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0

# ---------------------------------------------------------------------------
# Sandbox expansion denylist
# ---------------------------------------------------------------------------
# Credentials that must never be expanded into any sandbox environment.
# Add new entries here when onboarding provider-backed credentials.
DENYLIST=(
  JIRA_TOKEN
  OPENAI_API_KEY
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
assert_pass() { echo "PASS: $1"; }
assert_fail() {
  local test_name="$1" detail="$2"
  echo "FAIL: ${test_name} — ${detail}"
  FAILURES=$((FAILURES + 1))
}

# check_env_sandbox — scan env.sandbox values (top-level + overlays) for
# a denylisted variable reference.  Catches both KEY matches and VALUE
# expansion patterns like ${VAR}.
check_env_sandbox() {
  local harness_file="$1" denied_var="$2"
  python3 - "$harness_file" "$denied_var" <<'PYEOF'
import yaml, sys

harness_file = sys.argv[1]
denied_var = sys.argv[2]
pattern = "${" + denied_var + "}"

with open(harness_file) as f:
    doc = yaml.safe_load(f)

hits = []

def scan_sandbox(env_block, label):
    sandbox = (env_block or {}).get("sandbox") or {}
    for k, v in sandbox.items():
        # Key IS the denylisted var (direct inclusion)
        if k == denied_var:
            hits.append(f"{label}: key {k}")
        # Value references the denylisted var (alias / expansion)
        if pattern in str(v):
            hits.append(f"{label}: {k}={v}")

# Top-level env.sandbox
scan_sandbox(doc.get("env"), "top-level env.sandbox")

# Overlay env.sandbox
for i, ov in enumerate(doc.get("overlays") or []):
    when = ov.get("when", f"overlay[{i}]")
    scan_sandbox(ov.get("env"), f"overlay [{when}] env.sandbox")

for h in hits:
    print(h)
PYEOF
}

# check_host_files — scan host_files with expand: true for denylisted
# variable references in their source files.
check_host_files() {
  local harness_file="$1" denied_var="$2"
  python3 - "$harness_file" "$denied_var" "$REPO_ROOT" <<'PYEOF'
import yaml, os, sys

harness_file = sys.argv[1]
denied_var = sys.argv[2]
repo_root = sys.argv[3]
pattern = "${" + denied_var + "}"

with open(harness_file) as f:
    doc = yaml.safe_load(f)

hits = []

def scan_host_files(hfs, label):
    for hf in (hfs or []):
        if not hf.get("expand"):
            continue
        src = hf.get("src", "")
        # Skip dynamic paths (e.g. ${GOOGLE_APPLICATION_CREDENTIALS})
        if "$" in src:
            continue
        src_path = os.path.join(repo_root, src)
        if not os.path.isfile(src_path):
            continue
        with open(src_path) as sf:
            content = sf.read()
        if pattern in content or denied_var in content:
            hits.append(f"{label}: {src}")

# Top-level host_files
scan_host_files(doc.get("host_files"), "top-level")

# Overlay host_files
for i, ov in enumerate(doc.get("overlays") or []):
    when = ov.get("when", f"overlay[{i}]")
    scan_host_files(ov.get("host_files"), f"overlay [{when}]")

for h in hits:
    print(h)
PYEOF
}

# ---------------------------------------------------------------------------
# Discover harness files
# ---------------------------------------------------------------------------
HARNESS_DIR="${REPO_ROOT}/harness"
HARNESS_FILES=()
for f in "${HARNESS_DIR}"/*.yaml; do
  [[ -f "$f" ]] && HARNESS_FILES+=("$f")
done

if [[ ${#HARNESS_FILES[@]} -eq 0 ]]; then
  echo "ERROR: no harness YAML files found in ${HARNESS_DIR}"
  exit 1
fi

echo "Scanning ${#HARNESS_FILES[@]} harness file(s) against ${#DENYLIST[@]} denylisted credential(s)"
echo ""

# ---------------------------------------------------------------------------
# Test: env.sandbox must not reference denylisted vars
# ---------------------------------------------------------------------------
for harness in "${HARNESS_FILES[@]}"; do
  harness_name="$(basename "$harness" .yaml)"
  for denied_var in "${DENYLIST[@]}"; do
    test_name="${harness_name}-env-sandbox-no-${denied_var}"
    matches="$(check_env_sandbox "$harness" "$denied_var")"
    if [[ -n "$matches" ]]; then
      assert_fail "$test_name" "denylisted credential reference: ${matches}"
    else
      assert_pass "$test_name"
    fi
  done
done

# ---------------------------------------------------------------------------
# Test: expanded host_files must not reference denylisted vars
# ---------------------------------------------------------------------------
for harness in "${HARNESS_FILES[@]}"; do
  harness_name="$(basename "$harness" .yaml)"
  for denied_var in "${DENYLIST[@]}"; do
    test_name="${harness_name}-host-files-no-${denied_var}"
    matches="$(check_host_files "$harness" "$denied_var")"
    if [[ -n "$matches" ]]; then
      assert_fail "$test_name" "denylisted credential in expanded host file: ${matches}"
    else
      assert_pass "$test_name"
    fi
  done
done

# ---------------------------------------------------------------------------
# Test: Jira skill files carry the opaque placeholder through Basic auth
# ---------------------------------------------------------------------------
# This is the positive complement to the sandbox env denylist above:
# the real JIRA_TOKEN never enters sandbox config (env.sandbox, env files),
# but sandbox curl commands must still carry the provider-supplied opaque
# placeholder via --user for Basic auth.
JIRA_SKILL_FILES=(
  "${REPO_ROOT}/skills/jira-forge/SKILL.md"
  "${REPO_ROOT}/skills/issue-labels/jira/SKILL.md"
  "${REPO_ROOT}/skills/jira-components/SKILL.md"
  "${REPO_ROOT}/skills/code-implementation/SKILL.md"
)

for skill_file in "${JIRA_SKILL_FILES[@]}"; do
  skill_name="$(basename "$(dirname "${skill_file}")")"
  test_name="skill-${skill_name}-uses-basic-auth-placeholder"

  if [ ! -f "${skill_file}" ]; then
    assert_fail "${test_name}" "${skill_file} not found"
    continue
  fi

  if grep -qF -- '--user "${JIRA_USER_EMAIL}:${JIRA_TOKEN}"' "${skill_file}"; then
    assert_pass "${test_name}"
  else
    assert_fail "${test_name}" "missing --user Basic auth with opaque JIRA_TOKEN placeholder"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All sandbox credential boundary tests passed"
