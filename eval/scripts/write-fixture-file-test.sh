#!/usr/bin/env bash
# Tests for write-fixture-file.sh: every PR fixture file ends with exactly
# one final newline, whatever YAML block style its content uses, including
# when the content comes from `yq -r` the way setup-fixture.sh reads it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITER="${SCRIPT_DIR}/write-fixture-file.sh"
FAILURES=0
TESTS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() {
  local name="$1" expected="$2" file="$3" actual
  TESTS=$((TESTS + 1))
  actual="$(od -An -c "$file" | tr -s ' \n' ' ' | sed 's/^ //; s/ $//')"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    FAILURES=$((FAILURES + 1))
  fi
}

printf 'a\nb\n\n' | "$WRITER" "$TMP/extra"
check "an extra trailing newline is dropped" 'a \n b \n' "$TMP/extra"

printf 'a\nb' | "$WRITER" "$TMP/none"
check "a missing final newline is added" 'a \n b \n' "$TMP/none"

printf 'a\nb\n' | "$WRITER" "$TMP/one"
check "exactly one final newline is kept" 'a \n b \n' "$TMP/one"

printf 'a\n\nb\n\n\n' | "$WRITER" "$TMP/inner"
check "inner blank lines are kept, trailing ones collapse to one newline" 'a \n \n b \n' "$TMP/inner"

if command -v yq >/dev/null 2>&1; then
  cat > "$TMP/input.yaml" <<'YAML'
files:
  - content: |
      x
      y
  - content: |-
      x
      y
  - content: |+
      x
      y

YAML
  for i in 0 1 2; do
    yq -r ".files[$i].content" "$TMP/input.yaml" | "$WRITER" "$TMP/yq-$i"
  done
  check "yq -r of a | block ends with one newline" 'x \n y \n' "$TMP/yq-0"
  check "yq -r of a |- block ends with one newline" 'x \n y \n' "$TMP/yq-1"
  check "yq -r of a |+ block ends with one newline" 'x \n y \n' "$TMP/yq-2"
else
  echo "SKIP: yq not on PATH; yq block-style cases not run"
fi

echo ""
echo "=== $TESTS tests, $FAILURES failures ==="
[[ $FAILURES -eq 0 ]]
