#!/usr/bin/env bash
# gitleaks-install-test.sh — Test platform detection and checksum lookup
# from scripts/lib/gitleaks-install.lib.sh.
#
# Run from the repo root:
#   bash scripts/gitleaks-install-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILURES=0

# Source the lib directly for unit testing.
# shellcheck source=lib/gitleaks-install.lib.sh
source "${SCRIPT_DIR}/lib/gitleaks-install.lib.sh"

# ---------------------------------------------------------------------------
# resolve_platform tests — mock uname via PATH override
# ---------------------------------------------------------------------------
run_platform_test() {
  local test_name="$1"
  local mock_os="$2"
  local mock_arch="$3"
  local expected="$4"

  local tmpdir
  tmpdir="$(mktemp -d)"
  cat > "${tmpdir}/uname" <<MOCKEOF
#!/bin/bash
case "\$1" in
  (-s) echo "${mock_os}" ;;
  (-m) echo "${mock_arch}" ;;
  (*) echo "mock-uname: unknown flag \$1" >&2; exit 1 ;;
esac
MOCKEOF
  chmod +x "${tmpdir}/uname"

  local actual
  # shellcheck disable=SC2123
  actual="$(PATH="${tmpdir}:${PATH}" resolve_platform 2>/dev/null || echo "ERROR")"
  rm -rf "${tmpdir}"

  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${test_name}"
    echo "  os=${mock_os} arch=${mock_arch}"
    echo "  expected: '${expected}'"
    echo "  actual:   '${actual}'"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

run_platform_test "linux-x86_64"  "Linux"  "x86_64"  "linux_x64"
run_platform_test "linux-amd64"   "Linux"  "amd64"   "linux_x64"
run_platform_test "linux-aarch64" "Linux"  "aarch64" "linux_arm64"
run_platform_test "linux-arm64"   "Linux"  "arm64"   "linux_arm64"
run_platform_test "darwin-x86_64" "Darwin" "x86_64"  "darwin_x64"
run_platform_test "darwin-arm64"  "Darwin" "arm64"   "darwin_arm64"
run_platform_test "unsupported-os" "FreeBSD" "x86_64" "ERROR"
run_platform_test "unsupported-arch" "Linux" "riscv64" "ERROR"

# ---------------------------------------------------------------------------
# gitleaks_sha256 tests — verify checksum lookup for all platforms
# ---------------------------------------------------------------------------
run_checksum_test() {
  local test_name="$1"
  local platform="$2"
  local expect_success="$3"

  local actual rc=0
  actual="$(gitleaks_sha256 "${platform}" 2>/dev/null)" || rc=$?

  if [ "${expect_success}" = "yes" ]; then
    if [ "${rc}" -ne 0 ] || [ -z "${actual}" ]; then
      echo "FAIL: ${test_name}"
      echo "  platform: '${platform}' — expected checksum, got rc=${rc}"
      FAILURES=$((FAILURES + 1))
      return
    fi
    if [ "${#actual}" -ne 64 ]; then
      echo "FAIL: ${test_name}"
      echo "  platform: '${platform}' — checksum length ${#actual}, expected 64"
      FAILURES=$((FAILURES + 1))
      return
    fi
  else
    if [ "${rc}" -eq 0 ]; then
      echo "FAIL: ${test_name}"
      echo "  platform: '${platform}' — expected failure, got: '${actual}'"
      FAILURES=$((FAILURES + 1))
      return
    fi
  fi

  echo "PASS: ${test_name}"
}

run_checksum_test "checksum-linux-x64"    "linux_x64"    "yes"
run_checksum_test "checksum-linux-arm64"  "linux_arm64"  "yes"
run_checksum_test "checksum-darwin-x64"   "darwin_x64"   "yes"
run_checksum_test "checksum-darwin-arm64" "darwin_arm64" "yes"
run_checksum_test "checksum-unknown"      "freebsd_x64"  "no"

# ---------------------------------------------------------------------------
# verify_checksum tests — verify the checksum function works
# ---------------------------------------------------------------------------
run_verify_test() {
  local test_name="$1"
  local content="$2"
  local checksum="$3"
  local expect_pass="$4"

  local tmpfile
  tmpfile="$(mktemp)"
  printf '%s' "${content}" > "${tmpfile}"

  local rc=0
  verify_checksum "${tmpfile}" "${checksum}" >/dev/null 2>&1 || rc=$?
  rm -f "${tmpfile}"

  if [ "${expect_pass}" = "yes" ] && [ "${rc}" -ne 0 ]; then
    echo "FAIL: ${test_name} — expected pass, got rc=${rc}"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [ "${expect_pass}" = "no" ] && [ "${rc}" -eq 0 ]; then
    echo "FAIL: ${test_name} — expected fail, got pass"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "PASS: ${test_name}"
}

KNOWN_CONTENT="gitleaks-test-content"
KNOWN_HASH="$(printf '%s' "${KNOWN_CONTENT}" | sha256sum | cut -d' ' -f1)"

run_verify_test "verify-valid-checksum" "${KNOWN_CONTENT}" "${KNOWN_HASH}" "yes"
run_verify_test "verify-invalid-checksum" "${KNOWN_CONTENT}" "0000000000000000000000000000000000000000000000000000000000000000" "no"

# ---------------------------------------------------------------------------
# Version drift guard — GITLEAKS_VERSION must be consistent
# ---------------------------------------------------------------------------
for script in post-code post-fix; do
  src_file="${SCRIPT_DIR}/${script}.src.sh"
  [ -f "${src_file}" ] || continue
  src_ver="$(grep -o 'GITLEAKS_VERSION="[^"]*"' "${src_file}" || true)"
  if [ -n "${src_ver}" ]; then
    echo "FAIL: version-not-in-src-${script}"
    echo "  ${src_file} still defines GITLEAKS_VERSION — should come from gitleaks-install.lib.sh only"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: version-not-in-src-${script}"
  fi
done

lib_ver="$(grep -o 'GITLEAKS_VERSION="[^"]*"' "${SCRIPT_DIR}/lib/gitleaks-install.lib.sh")"
if [ -z "${lib_ver}" ]; then
  echo "FAIL: version-in-lib"
  echo "  gitleaks-install.lib.sh missing GITLEAKS_VERSION"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: version-in-lib (${lib_ver})"
fi

# ---------------------------------------------------------------------------
# Function drift guard — both bundled scripts must contain the shared functions
# ---------------------------------------------------------------------------
for script in post-code post-fix; do
  bundled="${SCRIPT_DIR}/${script}.sh"
  [ -f "${bundled}" ] || continue
  for func in resolve_platform gitleaks_sha256 verify_checksum install_gitleaks; do
    if ! grep -q "${func}" "${bundled}"; then
      echo "FAIL: bundled-has-${func}-${script}"
      echo "  ${bundled} missing ${func}"
      FAILURES=$((FAILURES + 1))
    else
      echo "PASS: bundled-has-${func}-${script}"
    fi
  done
done

# --- Summary ---

echo ""
if [ ${FAILURES} -gt 0 ]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All tests passed"
