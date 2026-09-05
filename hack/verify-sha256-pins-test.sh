#!/usr/bin/env bash
# verify-sha256-pins-test.sh — Tests for hack/verify-sha256-pins
#
# Run from the repo root:
#   bash hack/verify-sha256-pins-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINTER="${SCRIPT_DIR}/verify-sha256-pins"

FAILURES=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# Create content files for mock fetching.
CONTENT_A="harness content alpha"
printf '%s' "${CONTENT_A}" > "${WORKDIR}/content-a.txt"
HASH_A="$(sha256sum "${WORKDIR}/content-a.txt" | awk '{print $1}')"

CONTENT_B="harness content beta"
printf '%s' "${CONTENT_B}" > "${WORKDIR}/content-b.txt"
HASH_B="$(sha256sum "${WORKDIR}/content-b.txt" | awk '{print $1}')"

WRONG_HASH="0000000000000000000000000000000000000000000000000000000000000000"

# Mock fetch script: maps test URLs to local fixture files.
MOCK_FETCH="${WORKDIR}/mock-fetch"
cat > "${MOCK_FETCH}" <<MOCKEOF
#!/bin/bash
case "\$1" in
  https://raw.githubusercontent.com/example/repo/abc123/file-a.yaml)
    cat "${WORKDIR}/content-a.txt" ;;
  https://raw.githubusercontent.com/example/repo/abc123/file-b.yaml)
    cat "${WORKDIR}/content-b.txt" ;;
  https://raw.githubusercontent.com/example/repo/abc123/unreachable.yaml)
    exit 1 ;;
  *) exit 1 ;;
esac
MOCKEOF
chmod +x "${MOCK_FETCH}"

# run_case NAME EXPECTED_EXIT [EXPECTED_OUTPUT_SUBSTRING]
#
# Expects the case directory to have been set up before calling.
run_case() {
  local name="$1" expected_exit="$2" expected_substring="${3:-}"
  local case_dir="${WORKDIR}/${name}"

  local output
  local actual_exit=0
  output="$(REPO_ROOT="${case_dir}" VERIFY_FETCH="${MOCK_FETCH}" "${LINTER}" 2>&1)" || actual_exit=$?

  if [[ "${actual_exit}" != "${expected_exit}" ]]; then
    echo "FAIL: ${name} (exit ${actual_exit}, expected ${expected_exit})"
    echo "${output}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  if [[ -n "${expected_substring}" ]] && [[ "${output}" != *"${expected_substring}"* ]]; then
    echo "FAIL: ${name} (missing expected output: '${expected_substring}')"
    echo "${output}" | sed 's/^/    /'
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${name}"
}

# ---- Test: correct hash passes ----
name="correct-hash-passes"
case_dir="${WORKDIR}/${name}"
mkdir -p "${case_dir}/harness"
cat > "${case_dir}/harness/test.yaml" <<EOF
---
agent: agents/test.md
base: https://raw.githubusercontent.com/example/repo/abc123/file-a.yaml#sha256=${HASH_A}
EOF
run_case "${name}" 0 "OK"

# ---- Test: wrong hash fails ----
name="wrong-hash-fails"
case_dir="${WORKDIR}/${name}"
mkdir -p "${case_dir}/harness"
cat > "${case_dir}/harness/test.yaml" <<EOF
---
agent: agents/test.md
base: https://raw.githubusercontent.com/example/repo/abc123/file-a.yaml#sha256=${WRONG_HASH}
EOF
run_case "${name}" 1 "MISMATCH"

# ---- Test: local paths silently skipped ----
name="local-paths-skipped"
case_dir="${WORKDIR}/${name}"
mkdir -p "${case_dir}/harness"
cat > "${case_dir}/harness/test.yaml" <<EOF
---
agent: agents/test.md
policy: policies/base.yaml
openshell:
  profiles:
    - profiles/fullsend-vertex-ai.yaml
providers:
  - providers/vertex-ai.yaml
EOF
run_case "${name}" 0 "0 sha256 pin(s) verified"

# ---- Test: container image digests ignored ----
name="image-digest-ignored"
case_dir="${WORKDIR}/${name}"
mkdir -p "${case_dir}/harness"
cat > "${case_dir}/harness/test.yaml" <<EOF
---
agent: agents/test.md
image: ghcr.io/fullsend-ai/fullsend-code@sha256:9743bc7b6e451e0bcea25ae4a67e0c040c296f1fee04c08988ae80c53fafcfe6
EOF
run_case "${name}" 0 "0 sha256 pin(s) verified"

# ---- Test: field-agnostic scanning ----
name="field-agnostic"
case_dir="${WORKDIR}/${name}"
mkdir -p "${case_dir}/harness"
cat > "${case_dir}/harness/test.yaml" <<EOF
---
agent: agents/test.md
base: https://raw.githubusercontent.com/example/repo/abc123/file-a.yaml#sha256=${HASH_A}
skills:
  - https://raw.githubusercontent.com/example/repo/abc123/file-b.yaml#sha256=${HASH_B}
EOF
run_case "${name}" 0 "2 sha256 pin(s) verified"

# ---- Test: .fullsend/config.yaml scanned ----
name="fullsend-config-scanned"
case_dir="${WORKDIR}/${name}"
mkdir -p "${case_dir}/harness" "${case_dir}/.fullsend"
# Empty harness dir (no .yaml files)
cat > "${case_dir}/.fullsend/config.yaml" <<EOF
version: "1"
agents:
    - source: https://raw.githubusercontent.com/example/repo/abc123/file-a.yaml#sha256=${HASH_A}
EOF
run_case "${name}" 0 ".fullsend/config.yaml"

# ---- Test: fetch failure reports error ----
name="fetch-failure"
case_dir="${WORKDIR}/${name}"
mkdir -p "${case_dir}/harness"
cat > "${case_dir}/harness/test.yaml" <<EOF
---
source: https://raw.githubusercontent.com/example/repo/abc123/unreachable.yaml#sha256=${HASH_A}
EOF
run_case "${name}" 1 "failed to fetch"

# ---- Test: placeholder hashes skipped ----
name="placeholder-skipped"
case_dir="${WORKDIR}/${name}"
mkdir -p "${case_dir}/harness"
cat > "${case_dir}/harness/test.yaml" <<EOF
---
base: https://raw.githubusercontent.com/fullsend-ai/agents/<SHA>/harness/review.yaml#sha256=<sha256sum>
EOF
run_case "${name}" 0 "0 sha256 pin(s) verified"

# ---- Test: mismatch output includes url and hashes ----
name="mismatch-output-details"
case_dir="${WORKDIR}/${name}"
mkdir -p "${case_dir}/harness"
cat > "${case_dir}/harness/test.yaml" <<EOF
---
base: https://raw.githubusercontent.com/example/repo/abc123/file-a.yaml#sha256=${WRONG_HASH}
EOF
run_case "${name}" 1 "expected: ${WRONG_HASH}"

# ---- Test: mixed valid and invalid ----
name="mixed-valid-invalid"
case_dir="${WORKDIR}/${name}"
mkdir -p "${case_dir}/harness"
cat > "${case_dir}/harness/test.yaml" <<EOF
---
base: https://raw.githubusercontent.com/example/repo/abc123/file-a.yaml#sha256=${HASH_A}
source: https://raw.githubusercontent.com/example/repo/abc123/file-b.yaml#sha256=${WRONG_HASH}
EOF
run_case "${name}" 1 "MISMATCH"

# ---- Test: no yaml files ----
name="no-yaml-files"
case_dir="${WORKDIR}/${name}"
mkdir -p "${case_dir}"
run_case "${name}" 0 "no sha256 pins to verify"

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
