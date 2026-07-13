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
assert_contains "dedup-already-bundled-comment" "# (already bundled: lib/leaf.lib.sh)" "${CONTENT}"
assert_eq "dedup-leaf-fn-count" "1" "$(printf '%s' "${CONTENT}" | grep -c '^leaf_fn()')"
bash "${OUT}"
echo "PASS: dedup-executes"

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
