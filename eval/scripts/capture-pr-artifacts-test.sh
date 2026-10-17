#!/usr/bin/env bash
# Tests for capture-pr-artifacts.sh's outcome classification: every way the
# hook can end leaves output/agent-outcome.json, and every way it can fail
# to establish what the agent did also leaves output/infrastructure-failure.json
# (the marker run-functional.sh counts as a case failure), including a
# missing tool, a fixture record jq cannot parse, a failing gh call and a
# malformed head ref. The PR path is exercised with a stub gh, git and
# run-in-sandbox.sh, so the regression classification from the runner's
# status file is checked too.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/capture-pr-artifacts.sh"
FAILURES=0
TESTS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for tool in yq jq rsync timeout; do
  command -v "$tool" >/dev/null || { echo "SKIP: $tool not on PATH"; exit 0; }
done

pass() { TESTS=$((TESTS + 1)); echo "PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL: $1"; }

# Stubs for the tools that reach the network or a sandbox.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# STUB_GH_RC non-zero makes every call fail (a GitHub API error).
[[ "${STUB_GH_RC:-0}" != 0 ]] && exit "$STUB_GH_RC"
case "$1 $2" in
  "pr view") printf '{"pr_found": true, "number": 7, "url": "https://x/pull/7", "title": "T", "body": "B", "head": "agent/7-x", "base": "main", "head_sha": "abc", "additions": 1, "deletions": 0, "files": ["a.txt"]}\n' ;;
  "pr diff") printf 'diff --git a/a.txt b/a.txt\n+hello\n' ;;
  *) exit 0 ;;
esac
STUB
cat > "$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
# Only `git [-c ...] clone ... <url> <dir>` is expected: make the checkout.
for a in "$@"; do last="$a"; done
mkdir -p "$last" && echo hello > "$last/a.txt"
STUB
cat > "$TMP/bin/run-in-sandbox.sh" <<'STUB'
#!/usr/bin/env bash
# <checkout> <command> <timeout> <log>: writes the status file the way the
# real runner does, from STUB_SANDBOX_STATUS (command|timeout|sandbox) and
# STUB_SANDBOX_RC.
echo "stub ran: $2" > "$4"
echo "${STUB_SANDBOX_STATUS:-command}" > "$4.status"
exit "${STUB_SANDBOX_RC:-0}"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/openshell"
printf '#!/usr/bin/env bash\nprintf "%%s" "${STUB_FINAL_MSG:-}"\n' > "$TMP/bin/extract-final-message.py"
chmod +x "$TMP/bin/"*

# A PATH of symlinks to every real tool, minus the named ones, so a "missing
# tool" case is a real absence rather than a stub that exits non-zero.
make_path() { # dir tools-to-omit...
  local dir="$1"; shift
  mkdir -p "$dir"
  local d f n
  for d in "$TMP/bin" $(echo "$PATH" | tr ':' ' '); do
    for f in "$d"/*; do
      [[ -e "$f" ]] || continue
      n=$(basename "$f")
      [[ " $* " == *" $n "* ]] && continue
      [[ -e "$dir/$n" ]] || ln -s "$f" "$dir/$n"
    done
  done
}
make_path "$TMP/path-all"
make_path "$TMP/path-no-rsync" rsync
make_path "$TMP/path-no-jq-yq" jq yq

# A case workspace: output/ with a fixture record, a source dir with the card.
new_case() { # name fixture-state-json
  local ws="$TMP/$1"
  mkdir -p "$ws/output" "$ws/src/repo"
  printf 'fixture:\n  title: t\n  body: b\n' > "$ws/src/input.yaml"
  printf 'judge_notes: ""\nregression_tests:\n  command: "true"\ntest_timeout_s: 60\n' > "$ws/src/annotations.yaml"
  [[ -n "$2" ]] && printf '%s\n' "$2" > "$ws/output/fixture-state.json"
  echo "$ws"
}
run_hook() { # ws path-dir [VAR=value ...]
  local ws="$1" path="$2"; shift 2
  RC=0
  OUT=$(env -i PATH="$path" HOME="$TMP" CASE_WORKSPACE="$ws" CASE_SOURCE_DIR="$ws/src" EPHEMERAL_REPO=o/r "$@" bash "$HOOK" 2>&1) || RC=$?
}
field() { jq -r "$2" "$1" 2>/dev/null || echo "(unreadable)"; }
outcome() { field "$1/output/agent-outcome.json" '.outcome + "/" + (.infrastructure|tostring)'; }
marker() { field "$1/output/infrastructure-failure.json" '.reason'; }
valid_json() { jq -e . "$1" >/dev/null 2>&1; }

PR_STATE='{"pull_requests":[{"number":7,"state":"OPEN","head":"agent/7-x"}]}'

# --- infrastructure failures: marker + failed/infrastructure ---------------
WS=$(new_case no-rsync "$PR_STATE"); run_hook "$WS" "$TMP/path-no-rsync"
if [[ $RC -ne 0 && "$(outcome "$WS")" == "failed/true" && "$(marker "$WS")" == *"not found in PATH: rsync"* ]]; then
  pass "a missing tool leaves the marker and a failed/infrastructure outcome"
else
  fail "a missing tool leaves the marker and a failed/infrastructure outcome (rc=$RC, outcome=$(outcome "$WS"), marker=$(marker "$WS"), out: $OUT)"
fi

WS=$(new_case no-jq "$PR_STATE"); run_hook "$WS" "$TMP/path-no-jq-yq"
if [[ $RC -ne 0 ]] && valid_json "$WS/output/agent-outcome.json" && valid_json "$WS/output/infrastructure-failure.json" \
   && [[ "$(outcome "$WS")" == "failed/true" && "$(marker "$WS")" == *"yq jq"* ]]; then
  pass "with jq itself missing, both files are still written as valid JSON"
else
  fail "with jq itself missing, both files are still written as valid JSON (rc=$RC, out: $OUT)"
fi

WS=$(new_case no-record ""); run_hook "$WS" "$TMP/path-all"
if [[ $RC -ne 0 && "$(outcome "$WS")" == "failed/true" && "$(marker "$WS")" == *"fixture-state.json missing"* ]]; then
  pass "a missing fixture record is an infrastructure failure"
else
  fail "a missing fixture record is an infrastructure failure (rc=$RC, out: $OUT)"
fi

WS=$(new_case bad-record '{not json'); run_hook "$WS" "$TMP/path-all"
if [[ $RC -ne 0 && "$(outcome "$WS")" == "failed/true" && "$(marker "$WS")" == *"aborted at line"* ]]; then
  pass "a fixture record jq cannot parse goes through the ERR trap to the marker"
else
  fail "a fixture record jq cannot parse goes through the ERR trap to the marker (rc=$RC, outcome=$(outcome "$WS"), marker=$(marker "$WS"), out: $OUT)"
fi

WS=$(new_case bad-head '{"pull_requests":[{"number":7,"state":"OPEN","head":"agent/7 x;"}]}'); run_hook "$WS" "$TMP/path-all"
if [[ $RC -ne 0 && "$(outcome "$WS")" == "failed/true" && "$(marker "$WS")" == *"unexpected head ref"* ]] && valid_json "$WS/output/infrastructure-failure.json"; then
  pass "a malformed head ref is an infrastructure failure with a valid marker"
else
  fail "a malformed head ref is an infrastructure failure with a valid marker (rc=$RC, out: $OUT)"
fi

WS=$(new_case gh-fails "$PR_STATE"); run_hook "$WS" "$TMP/path-all" STUB_GH_RC=1
if [[ $RC -ne 0 && "$(outcome "$WS")" == "failed/true" && "$(marker "$WS")" == *"aborted at line"* ]]; then
  pass "a failing gh pr view goes through the ERR trap to the marker"
else
  fail "a failing gh pr view goes through the ERR trap to the marker (rc=$RC, outcome=$(outcome "$WS"), marker=$(marker "$WS"), out: $OUT)"
fi

# --- agent outcomes: no marker --------------------------------------------
WS=$(new_case no-pr '{"pull_requests":[]}'); run_hook "$WS" "$TMP/path-all"
if [[ $RC -eq 0 && "$(outcome "$WS")" == "failed/false" && ! -e "$WS/output/infrastructure-failure.json" ]]; then
  pass "no agent PR and no final message is an ordinary failure without a marker"
else
  fail "no agent PR and no final message is an ordinary failure without a marker (rc=$RC, outcome=$(outcome "$WS"), out: $OUT)"
fi

# A decline needs a clean run: run-fullsend.sh records how fullsend exited in
# output/run-status.json, and no_pr reads it before trusting the final message.
WS=$(new_case declined '{"pull_requests":[]}'); mkdir -p "$WS/output/fs-cod-1"; touch "$WS/output/fs-cod-1/metrics.json"
echo '{"exit_code": 0, "timed_out": false}' > "$WS/output/run-status.json"
run_hook "$WS" "$TMP/path-all" STUB_FINAL_MSG="I stopped because the endpoint already exists."
if [[ $RC -eq 0 && "$(outcome "$WS")" == "declined/false" && ! -e "$WS/output/infrastructure-failure.json" && -d "$WS/judge/repo-snapshot" ]]; then
  pass "no PR with a clean run and a final message is a decline, with the repo snapshot staged"
else
  fail "no PR with a clean run and a final message is a decline (rc=$RC, outcome=$(outcome "$WS"), out: $OUT)"
fi

WS=$(new_case timed-out '{"pull_requests":[]}'); mkdir -p "$WS/output/fs-cod-1"; touch "$WS/output/fs-cod-1/metrics.json"
echo '{"exit_code": 124, "timed_out": true}' > "$WS/output/run-status.json"
run_hook "$WS" "$TMP/path-all" STUB_FINAL_MSG="Still working on the tests, next I will..."
if [[ $RC -eq 0 && "$(outcome "$WS")" == "failed/false" && "$(field "$WS/output/agent-outcome.json" .reason)" == *"exited 124 (timed out)"* && ! -e "$WS/output/infrastructure-failure.json" ]]; then
  pass "no PR after a timed-out run is a failure naming the exit, however chatty the last message"
else
  fail "no PR after a timed-out run is a failure naming the exit (rc=$RC, outcome=$(outcome "$WS"), reason=$(field "$WS/output/agent-outcome.json" .reason), out: $OUT)"
fi

WS=$(new_case no-status '{"pull_requests":[]}'); mkdir -p "$WS/output/fs-cod-1"; touch "$WS/output/fs-cod-1/metrics.json"
run_hook "$WS" "$TMP/path-all" STUB_FINAL_MSG="I stopped because the endpoint already exists."
if [[ $RC -eq 0 && "$(outcome "$WS")" == "failed/false" && "$(field "$WS/output/agent-outcome.json" .reason)" == *"run status not recorded"* && ! -e "$WS/output/infrastructure-failure.json" ]]; then
  pass "no PR with a final message but no run-status.json is a failure saying the status was not recorded"
else
  fail "no PR with a final message but no run-status.json is a failure saying the status was not recorded (rc=$RC, outcome=$(outcome "$WS"), reason=$(field "$WS/output/agent-outcome.json" .reason), out: $OUT)"
fi

WS=$(new_case crashed '{"pull_requests":[]}'); mkdir -p "$WS/output/fs-cod-1"; touch "$WS/output/fs-cod-1/metrics.json"
echo '{"exit_code": 1, "timed_out": false}' > "$WS/output/run-status.json"
run_hook "$WS" "$TMP/path-all" STUB_FINAL_MSG="Almost there, let me just..."
if [[ $RC -eq 0 && "$(outcome "$WS")" == "failed/false" && "$(field "$WS/output/agent-outcome.json" .reason)" == *"fullsend run exited 1" ]]; then
  pass "no PR after a crashed run (exit 1, not timed out) is a failure naming the exit without a timeout note"
else
  fail "no PR after a crashed run is a failure naming the exit (rc=$RC, reason=$(field "$WS/output/agent-outcome.json" .reason), out: $OUT)"
fi

WS=$(new_case dependabot '{"pull_requests":[{"number":3,"state":"OPEN","head":"dependabot/npm/x"}]}'); run_hook "$WS" "$TMP/path-all"
if [[ $RC -eq 0 && "$(outcome "$WS")" == "failed/false" && "$(field "$WS/output/pr.json" .pr_found)" == "false" ]]; then
  pass "a PR on a non-agent branch does not count as the agent's PR"
else
  fail "a PR on a non-agent branch does not count as the agent's PR (rc=$RC, outcome=$(outcome "$WS"), out: $OUT)"
fi

# --- the PR path and the regression classification ------------------------
for spec in "command:0:PASSED (exit 0)" "command:3:FAILED (exit 3)" "command:125:FAILED (exit 125)" "timeout:124:TIMED OUT" "sandbox:125:NOT RUN"; do
  IFS=: read -r status rc_in expect <<< "$spec"
  WS=$(new_case "pr-$status-$rc_in" "$PR_STATE")
  run_hook "$WS" "$TMP/path-all" STUB_SANDBOX_STATUS="$status" STUB_SANDBOX_RC="$rc_in"
  reg="$WS/output/regression.json"
  if [[ $RC -eq 0 && "$(outcome "$WS")" == "pr/false" && ! -e "$WS/output/infrastructure-failure.json" \
        && "$(field "$reg" .exit_code)" == "$rc_in" \
        && "$(field "$reg" .timed_out)" == "$([[ $status == timeout ]] && echo true || echo false)" \
        && "$(field "$reg" .sandbox_failed)" == "$([[ $status == sandbox ]] && echo true || echo false)" \
        && -f "$WS/judge/diff.patch" && -f "$WS/judge/pr-head/a.txt" ]] \
     && grep -q "Result: $expect" "$WS/judge/tests.md" && [[ ! -e "$WS/output/regression.log.status" ]]; then
    pass "PR with sandbox status '$status' exit $rc_in: outcome pr, tests.md says $expect, status file consumed"
  else
    fail "PR with sandbox status '$status' exit $rc_in (rc=$RC, outcome=$(outcome "$WS"), regression=$(cat "$reg" 2>/dev/null), tests.md: $(grep Result "$WS/judge/tests.md" 2>/dev/null), out: $OUT)"
  fi
done

echo ""
echo "=== $TESTS tests, $FAILURES failures ==="
[[ $FAILURES -eq 0 ]]
