#!/usr/bin/env bash
# Tests for materialize-case.sh: a card's repo/ is built from an upstream
# snapshot in a staging directory and moved into place whole, the automation
# and exclude removals never follow a symlink out of the tree, and a failed
# build leaves either the previous repo/ or nothing.
#
# Offline: a stub git on PATH answers clone/fetch/rev-parse and streams a tar
# of $FAKE_TREE for `archive`, so the test controls the upstream tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATERIALIZE="${SCRIPT_DIR}/materialize-case.sh"
FAILURES=0
TESTS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for tool in yq tar; do
  command -v "$tool" >/dev/null || { echo "SKIP: $tool not on PATH"; exit 0; }
done

mkdir -p "$TMP/bin"
cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [[ "${args[0]:-}" == "-C" ]]; then args=("${args[@]:2}"); fi
case "${args[0]:-}" in
  clone) mkdir -p "${args[${#args[@]}-1]}" ;;
  fetch) ;;
  rev-parse) echo "0000000000000000000000000000000000000000" ;;
  archive) tar -c -C "${FAKE_TREE:?}" . ;;
  *) echo "stub git: unexpected args: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/git"
export PATH="$TMP/bin:$PATH"

pass() { TESTS=$((TESTS + 1)); echo "PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL: $1"; }

# new_card <name> [exclude-json-array]: a card dir with annotations + input.
new_card() {
  local dir="$TMP/$1" excl="${2:-[]}"
  mkdir -p "$dir"
  printf 'source:\n  repo: o/r\n  snapshot_commit: "0000000000000000000000000000000000000000"\n  exclude: %s\n' "$excl" > "$dir/annotations.yaml"
  echo 'fixture: {}' > "$dir/input.yaml"
  echo "$dir"
}
# new_tree <name>: a plain upstream tree with workflows, a renovate file,
# docs/secret and docs/keep.
new_tree() {
  local t="$TMP/tree-$1"
  mkdir -p "$t/.github/workflows" "$t/docs/secret" "$t/docs/keep"
  echo readme > "$t/README.md"; echo ci > "$t/.github/workflows/ci.yml"
  echo '{}' > "$t/renovate.json"; echo s > "$t/docs/secret/key"; echo k > "$t/docs/keep/x"
  echo "$t"
}
run() { # tree card [args...]: materialize, capturing output and rc
  local tree="$1" card="$2"; shift 2
  RC=0; OUT=$(FAKE_TREE="$tree" "$MATERIALIZE" "$card" "$@" 2>&1) || RC=$?
}
files_of() { find "$1" -type f | sed "s|^$1/||" | sort | tr '\n' ' '; }
stage_count() { find "$1" -maxdepth 1 -name '.repo-stage.*' | wc -l | tr -d ' '; }

# --- normal build -----------------------------------------------------------
TREE=$(new_tree plain); CARD=$(new_card plain '["docs/secret"]')
run "$TREE" "$CARD"
if [[ $RC -eq 0 && "$(files_of "$CARD/repo")" == "README.md docs/keep/x " && "$(stage_count "$CARD")" == 0 ]]; then
  pass "a plain tree builds repo/ minus workflows, renovate.json and the excluded path, with no stage left"
else
  fail "a plain tree builds repo/ minus workflows, renovate.json and the excluded path (rc=$RC, files='$(files_of "$CARD/repo" 2>/dev/null)', stages=$(stage_count "$CARD"), out: $OUT)"
fi

run "$TREE" "$CARD"
if [[ $RC -eq 0 && "$OUT" == *"already present"* ]]; then
  pass "an existing repo/ is kept without --force"
else
  fail "an existing repo/ is kept without --force (rc=$RC, out: $OUT)"
fi

# --- exclude written with a trailing slash still removes a real directory ---
CARD=$(new_card slash '["docs/secret/"]')
run "$TREE" "$CARD"
if [[ $RC -eq 0 && "$(files_of "$CARD/repo")" == "README.md docs/keep/x " ]]; then
  pass "an exclude with a trailing slash removes the real directory"
else
  fail "an exclude with a trailing slash removes the real directory (rc=$RC, files='$(files_of "$CARD/repo" 2>/dev/null)', out: $OUT)"
fi

# --- failure after extraction: previous repo/ survives, nothing else left ---
CARD=$(new_card keep '["docs/secret"]')
run "$TREE" "$CARD"
yq -i '.source.exclude = ["/etc"]' "$CARD/annotations.yaml"
run "$TREE" "$CARD" --force
if [[ $RC -ne 0 && "$OUT" == *"refusing exclude path"* && "$(files_of "$CARD/repo")" == "README.md docs/keep/x " && "$(stage_count "$CARD")" == 0 ]]; then
  pass "a failure after extraction with --force leaves the previous repo/ intact and no stage"
else
  fail "a failure after extraction with --force leaves the previous repo/ intact and no stage (rc=$RC, files='$(files_of "$CARD/repo" 2>/dev/null)', stages=$(stage_count "$CARD"), out: $OUT)"
fi

CARD=$(new_card none '["/etc"]')
run "$TREE" "$CARD"
if [[ $RC -ne 0 && ! -e "$CARD/repo" && "$(stage_count "$CARD")" == 0 && ! -e "$CARD/.repo-lock" ]]; then
  pass "a failure with no repo/ present leaves nothing behind"
else
  fail "a failure with no repo/ present leaves nothing behind (rc=$RC, left: $(find "$CARD" -mindepth 1 -maxdepth 1 | tr '\n' ' '), out: $OUT)"
fi

# --- a stale stage from a killed run is swept -------------------------------
CARD=$(new_card stale)
mkdir -p "$CARD/.repo-stage.OLD123/junk"
run "$TREE" "$CARD"
if [[ $RC -eq 0 && "$(stage_count "$CARD")" == 0 && -f "$CARD/repo/README.md" ]]; then
  pass "a stale .repo-stage.* from a killed run is removed before building"
else
  fail "a stale .repo-stage.* from a killed run is removed before building (rc=$RC, stages=$(stage_count "$CARD"), out: $OUT)"
fi

# --- one build per card at a time ------------------------------------------
CARD=$(new_card locked)
mkdir "$CARD/.repo-lock"
run "$TREE" "$CARD"
if [[ $RC -ne 0 && "$OUT" == *"another materialize-case.sh run holds"* && ! -e "$CARD/repo" && -d "$CARD/.repo-lock" ]]; then
  pass "a card another run holds is refused and left alone"
else
  fail "a card another run holds is refused and left alone (rc=$RC, out: $OUT)"
fi
rmdir "$CARD/.repo-lock"
run "$TREE" "$CARD"
if [[ $RC -eq 0 && -f "$CARD/repo/README.md" && ! -e "$CARD/.repo-lock" ]]; then
  pass "the lock is taken for the build and released afterwards"
else
  fail "the lock is taken for the build and released afterwards (rc=$RC, left: $(find "$CARD" -mindepth 1 -maxdepth 1 | tr '\n' ' '), out: $OUT)"
fi

# --- symlinks in the upstream tree are never deleted through ---------------
VICTIM="$TMP/victim"; mkdir -p "$VICTIM/workflows" "$VICTIM/secret"
echo ci > "$VICTIM/workflows/ci.yml"; echo s > "$VICTIM/secret/key"
victim_ok() { [[ -f "$VICTIM/workflows/ci.yml" && -f "$VICTIM/secret/key" ]]; }

LTREE="$TMP/tree-linked"; mkdir -p "$LTREE"; echo readme > "$LTREE/README.md"
ln -s "$VICTIM" "$LTREE/.github"
CARD=$(new_card link-github)
run "$LTREE" "$CARD"
if [[ $RC -ne 0 && "$OUT" == *"'.github' is a symlink"* && ! -e "$CARD/repo" && "$(stage_count "$CARD")" == 0 ]] && victim_ok; then
  pass "a symlinked .github is refused, the link target is untouched, nothing is left behind"
else
  fail "a symlinked .github is refused, the link target is untouched, nothing is left behind (rc=$RC, out: $OUT)"
fi

rm "$LTREE/.github"; mkdir -p "$LTREE/.github/workflows"; echo ci > "$LTREE/.github/workflows/ci.yml"
ln -s "$VICTIM" "$LTREE/docs"
for excl in '["docs/secret"]' '["docs/secret/"]' '["docs"]' '["docs/"]'; do
  CARD=$(new_card "link-docs-$TESTS" "$excl")
  run "$LTREE" "$CARD"
  if [[ $RC -ne 0 && "$OUT" == *"is a symlink"* && ! -e "$CARD/repo" ]] && victim_ok; then
    pass "exclude $excl through a symlinked docs is refused and the link target is untouched"
  else
    fail "exclude $excl through a symlinked docs is refused and the link target is untouched (rc=$RC, out: $OUT)"
  fi
done

CARD=$(new_card double-slash '["docs//secret"]')
run "$LTREE" "$CARD"
if [[ $RC -ne 0 && "$OUT" == *"refusing"* && ! -e "$CARD/repo" ]] && victim_ok; then
  pass "an exclude with an empty component is refused"
else
  fail "an exclude with an empty component is refused (rc=$RC, out: $OUT)"
fi

echo ""
echo "=== $TESTS tests, $FAILURES failures ==="
[[ $FAILURES -eq 0 ]]
