#!/usr/bin/env bash
# bundle-sh-test.sh — Tests for scripts/bundle-sh.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLER="${SCRIPT_DIR}/bundle-sh.sh"
FIXTURES="${SCRIPT_DIR}/test-fixtures/bundle"
TMPDIR="$(mktemp -d)"
FAILURES=0

trap 'rm -rf "${TMPDIR}"' EXIT

assert_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL: ${test_name}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${test_name}"
  fi
}

assert_contains() {
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
  if ! printf '%s' "${haystack}" | grep -qF "${needle}"; then
    echo "FAIL: ${test_name}"
    echo "  expected to find: ${needle}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${test_name}"
  fi
}

assert_not_contains() {
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "${haystack}" | grep -qF "${needle}"; then
    echo "FAIL: ${test_name}"
    echo "  expected NOT to find: ${needle}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: ${test_name}"
  fi
}

run_bundle_test() {
  local test_name="$1"
  local src="$2"
  local out="${TMPDIR}/${test_name}.sh"

  "${BUNDLER}" -o "${out}" "${src}"
  bash "${out}"
  echo "PASS: ${test_name}-executes"
}

# --- shebang and header ordering ---
OUT="${TMPDIR}/header.sh"
"${BUNDLER}" -o "${OUT}" "${FIXTURES}/simple.src.sh"
HEADER_LINE1="$(sed -n '1p' "${OUT}")"
HEADER_LINE2="$(sed -n '2p' "${OUT}")"
assert_eq "shebang-line-1" "#!/usr/bin/env bash" "${HEADER_LINE1}"
assert_contains "generated-banner-line-2" "GENERATED from simple.src.sh" "${HEADER_LINE2}"

# --- simple bundle executes ---
run_bundle_test "simple" "${FIXTURES}/simple.src.sh"

# --- nested bundle executes ---
run_bundle_test "nested" "${FIXTURES}/nested.src.sh"

# --- cross-dedup: parent sources nested; src also sources nested once ---
OUT="${TMPDIR}/cross-dedup.sh"
"${BUNDLER}" -o "${OUT}" "${FIXTURES}/cross-dedup.src.sh"
CONTENT="$(cat "${OUT}")"
assert_contains "cross-dedup-includes-nested-once" "nested_fn()" "${CONTENT}"
assert_eq "cross-dedup-nested-fn-count" "1" "$(printf '%s' "${CONTENT}" | grep -c '^nested_fn()')"
bash "${OUT}"
echo "PASS: cross-dedup-executes"

# --- dedup: second source becomes comment ---
OUT="${TMPDIR}/dedup.sh"
"${BUNDLER}" -o "${OUT}" "${FIXTURES}/dedup.src.sh"
CONTENT="$(cat "${OUT}")"
assert_contains "dedup-includes-leaf-once" "leaf_fn()" "${CONTENT}"
assert_contains "dedup-already-bundled-comment" "# (already bundled:" "${CONTENT}"
assert_eq "dedup-leaf-fn-count" "1" "$(printf '%s' "${CONTENT}" | grep -c '^leaf_fn()')"
bash "${OUT}"
echo "PASS: dedup-executes"

# --- outside-lib bundle must fail ---
if "${BUNDLER}" -o "${TMPDIR}/outside.sh" "${FIXTURES}/outside-lib.src.sh" 2>/dev/null; then
  echo "FAIL: outside-lib-should-fail"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: outside-lib-should-fail"
fi

# --- symlinked lib outside scripts/lib must fail ---
SYMLINK_ROOT="${TMPDIR}/symlink-bundle"
mkdir -p "${SYMLINK_ROOT}/scripts/lib" "${SYMLINK_ROOT}/outside"
printf '%s\n' 'evil_fn() { echo evil; }' > "${SYMLINK_ROOT}/outside/evil.lib.sh"
ln -sf "../../outside/evil.lib.sh" "${SYMLINK_ROOT}/scripts/lib/evil.lib.sh"
cat > "${SYMLINK_ROOT}/scripts/symlink.src.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/evil.lib.sh"
evil_fn
EOF
if "${BUNDLER}" -o "${TMPDIR}/symlink.sh" "${SYMLINK_ROOT}/scripts/symlink.src.sh" 2>/dev/null; then
  echo "FAIL: symlink-lib-should-fail"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: symlink-lib-should-fail"
fi

# --- check-bundle detects drift when mtimes are equal (temp copy only) ---
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRIFT_ROOT="${TMPDIR}/drift-check"
mkdir -p "${DRIFT_ROOT}"
cp "${REPO_ROOT}/Makefile" "${DRIFT_ROOT}/"
cp -r "${REPO_ROOT}/scripts" "${DRIFT_ROOT}/"
printf '\n# corrupt\n' >> "${DRIFT_ROOT}/scripts/post-code.sh"
touch -r "${DRIFT_ROOT}/scripts/post-code.sh" "${DRIFT_ROOT}/scripts/post-code.src.sh"
if ( cd "${DRIFT_ROOT}" && make check-bundle >/dev/null 2>&1 ); then
  echo "FAIL: check-bundle-should-detect-equal-mtime-drift"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: check-bundle-detects-equal-mtime-drift"
fi

# --- missing library fails ---
if "${BUNDLER}" -o "${TMPDIR}/bad.sh" "${SCRIPT_DIR}/does-not-exist.src.sh" 2>/dev/null; then
  echo "FAIL: missing-src-should-fail"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: missing-src-should-fail"
fi

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  echo "${FAILURES} test(s) failed"
  exit 1
fi
echo "All bundle-sh tests passed"
