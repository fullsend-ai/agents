#!/usr/bin/env bash
# Sanity-check an eval/dev/code-rhai case before spending an agent run on it:
#   1. input.yaml holds real epic text (no TODO/PLACEHOLDER)
#   2. annotations has a regression command (judge_notes is optional)
#   3. the regression command passes on the bare snapshot (scratch copy of repo/)
# A failing 3 means the case is mis-cut or the command is wrong, not the agent.
set -uo pipefail
CASE_DIR="${1:?usage: check-case.sh <case-dir>}"
CASE_DIR="$(cd "$CASE_DIR" && pwd)"
ANN="$CASE_DIR/annotations.yaml"
for cmd in yq timeout; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found" >&2; exit 1; }; done
[[ -f "$ANN" && -f "$CASE_DIR/input.yaml" ]] || { echo "ERROR: not a case dir: $CASE_DIR" >&2; exit 1; }
# repo/ is not committed (the case is a card); rebuild it from the snapshot commit.
[[ -d "$CASE_DIR/repo" ]] || "$(dirname "$0")/materialize-case.sh" "$CASE_DIR"
fail=0
if grep -qE 'TODO|PLACEHOLDER' "$CASE_DIR/input.yaml"; then echo "BAD  1. input.yaml still has TODO/PLACEHOLDER text"; fail=1; else echo "OK   1. input.yaml has epic text"; fi
cmd=$(yq -r '.regression_tests.command // ""' "$ANN"); notes=$(yq -r '.judge_notes // ""' "$ANN")
if [[ -z "$cmd" || "$cmd" == "TODO" ]]; then echo "BAD  2. regression_tests.command not set"; fail=1; else echo "OK   2. regression command: $cmd"; fi
if [[ "$notes" =~ TODO ]]; then echo "BAD  2. judge_notes still says TODO (leave it empty if there is nothing to note)"; fail=1; fi
if [[ -n "$cmd" && "$cmd" != "TODO" ]]; then
  tmo=$(yq -r '.test_timeout_s // 1800' "$ANN")
  WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
  cp -a "$CASE_DIR/repo/." "$WORK/"
  rc=0; ( cd "$WORK" && timeout "$tmo" env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
      LANG="${LANG:-C.UTF-8}" TERM=dumb CI=1 bash -o pipefail -c "$cmd" ) > "$CASE_DIR/.check-regression.log" 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then echo "OK   3. regression command passes on the bare snapshot"; rm -f "$CASE_DIR/.check-regression.log";
  else echo "BAD  3. regression command exit $rc on the bare snapshot (log: $CASE_DIR/.check-regression.log)"; fail=1; fi
fi
[[ $fail -eq 0 ]] && echo "All checks passed." || exit 1
