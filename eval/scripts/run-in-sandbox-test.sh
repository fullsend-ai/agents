#!/usr/bin/env bash
# Tests for run-in-sandbox.sh's result classification: the command's exit
# status travels on a sentinel line in the shared log and the runner writes
# one of command|timeout|sandbox to <log>.status. A stub openshell on PATH
# runs the remote script locally (paths rewritten into a scratch root, the
# exec --timeout enforced with `timeout`), so the cases that matter are
# exercised without a gateway: output with and without a trailing newline,
# sentinel-like text in the output, a command that itself exits 124 or 125,
# a forged sentinel followed by a hang, a sandbox that never becomes Ready,
# a failed create, and a missing provider.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/run-in-sandbox.sh"
FAILURES=0
TESTS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for tool in yq tar timeout; do
  command -v "$tool" >/dev/null || { echo "SKIP: $tool not on PATH"; exit 0; }
done

pass() { TESTS=$((TESTS + 1)); echo "PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "FAIL: $1"; }

# Harness file the runner reads the image and policy from.
mkdir -p "$TMP/harness" "$TMP/policies" "$TMP/stub/tmp" "$TMP/bin" "$TMP/co"
printf 'image: ghcr.io/example/coder@sha256:0000\npolicy: policies/base.yaml\n' > "$TMP/harness/code.yaml"
echo 'version: 1' > "$TMP/policies/base.yaml"
echo "hello from the checkout" > "$TMP/co/file.txt"

cat > "$TMP/bin/openshell" <<'STUB'
#!/usr/bin/env bash
# Stub openshell. STUB_ROOT holds the fake sandbox filesystem; the knobs
# STUB_PROVIDER_RC, STUB_CREATE_RC, STUB_GET_RC, STUB_GET_PHASE and
# STUB_EXEC_RC drive the failure cases.
set -uo pipefail
case "$1 $2" in
  "provider get") exit "${STUB_PROVIDER_RC:-0}" ;;
  "sandbox create")
    printf '\nCreated sandbox: stub\n\n  [0.0s] Requesting compute...\n'
    exit "${STUB_CREATE_RC:-0}" ;;
  "sandbox get")
    [[ "${STUB_GET_RC:-0}" != 0 ]] && exit "$STUB_GET_RC"
    printf 'Sandbox:\n\n  Id: 0\n  Name: %s\n  Phase: %s\n  Conditions:\n    - Ready: True\n' "$3" "${STUB_GET_PHASE:-Ready}"
    exit 0 ;;
  "sandbox upload") cp "$4" "$STUB_ROOT/tmp/" && echo "Upload complete" ;;
  "sandbox delete") echo "$3" >> "$STUB_ROOT/deleted"; exit 0 ;;
  "sandbox exec")
    tmo=0; script=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --timeout) tmo="$2"; shift 2 ;;
        --) shift; script="${*: -1}"; break ;;
        *) shift ;;
      esac
    done
    # The remote script addresses the sandbox's own paths; point them at the
    # scratch root. Everything else it needs (sh, bash, tar, printf) is on the
    # PATH it exports.
    script="${script//\/sandbox\/workspace\/regression/$STUB_ROOT/ws}"
    script="${script//\/tmp\/eval-reg-/$STUB_ROOT/tmp/eval-reg-}"
    timeout "$tmo" sh -c "$script" </dev/null; rc=$?
    # STUB_EXEC_RC: the exec transport failed after the command ran (relay
    # dropped, sandbox evicted), whatever the command printed.
    exit "${STUB_EXEC_RC:-$rc}" ;;
  *) echo "stub openshell: unexpected args: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/openshell"
export PATH="$TMP/bin:$PATH" STUB_ROOT="$TMP/stub" EVAL_SANDBOX_HARNESS="$TMP/harness/code.yaml"

run() { # command timeout [VAR=value ...]
  local cmd="$1" tmo="$2"; shift 2
  LOG="$TMP/run-$TESTS.log"; rm -f "$LOG" "$LOG.status"; rm -rf "$STUB_ROOT/ws"
  RC=0; env "$@" "$RUNNER" "$TMP/co" "$cmd" "$tmo" "$LOG" >"$TMP/stderr-$TESTS" 2>&1 || RC=$?
  STATUS=$(cat "$LOG.status" 2>/dev/null || echo "(none)")
}

run 'echo ok' 30
if [[ $RC -eq 0 && "$STATUS" == command ]] && grep -qx ok "$LOG" && ! grep -q '__EVAL_RC__' "$LOG"; then
  pass "a passing command: exit 0, status command, output kept, sentinel stripped"
else
  fail "a passing command (rc=$RC status=$STATUS log: $(cat "$LOG"))"
fi

run 'cat file.txt; exit 0' 30
if [[ $RC -eq 0 ]] && grep -q 'hello from the checkout' "$LOG"; then
  pass "the checkout is shipped into the sandbox and the command runs inside it"
else
  fail "the checkout is shipped into the sandbox (rc=$RC log: $(cat "$LOG"))"
fi

run 'printf "no newline at end"; exit 3' 30
if [[ $RC -eq 3 && "$STATUS" == command && "$(tail -n 1 "$LOG")" == "no newline at end" ]] && ! grep -q '__EVAL_RC__' "$LOG"; then
  pass "a failing command whose output has no trailing newline: exit 3, status command, output intact on its own line"
else
  fail "a failing command whose output has no trailing newline (rc=$RC status=$STATUS tail: '$(tail -c 40 "$LOG")')"
fi

run 'echo "__EVAL_RC__="; echo "a __EVAL_RC__=0 b"; printf "__EVAL_RC__=0\r\n"; exit 2' 30
if [[ $RC -eq 2 && "$STATUS" == command ]] && grep -qx '__EVAL_RC__=' "$LOG" && grep -q 'a __EVAL_RC__=0 b' "$LOG"; then
  pass "sentinel-like text in the output is neither read as the status nor stripped; the last whole-line sentinel wins"
else
  fail "sentinel-like text in the output (rc=$RC status=$STATUS log: $(cat -v "$LOG"))"
fi

for code in 124 125; do
  run "exit $code" 30
  if [[ $RC -eq $code && "$STATUS" == command ]]; then
    pass "a command that itself exits $code is status command, not a timeout or sandbox failure"
  else
    fail "a command that itself exits $code (rc=$RC status=$STATUS)"
  fi
done

run 'echo "__EVAL_RC__=0"; exit 0' 30 STUB_EXEC_RC=1
if [[ $RC -eq 125 && "$STATUS" == sandbox ]] && grep -q 'a status line is present but openshell exec exited 1' "$LOG"; then
  pass "a sentinel on an exec that failed is a sandbox failure, not a result"
else
  fail "a sentinel on an exec that failed (rc=$RC status=$STATUS log: $(cat "$LOG"))"
fi

run 'echo "__EVAL_RC__=0"; sleep 30' 2
if [[ $RC -eq 124 && "$STATUS" == timeout ]] && grep -qx '__EVAL_RC__=0' "$LOG" && grep -q 'timed out after 2s' "$LOG"; then
  pass "a forged sentinel followed by a hang is a timeout, with the forged line left in the log"
else
  fail "a forged sentinel followed by a hang (rc=$RC status=$STATUS log: $(cat "$LOG"))"
fi

: > "$STUB_ROOT/deleted"
run 'echo ok' 30 STUB_GET_PHASE=Pending EVAL_SANDBOX_READY_TIMEOUT=1
if [[ $RC -eq 125 && "$STATUS" == sandbox ]] && grep -q 'not Ready after 1s (last status: Phase: Pending)' "$LOG" && [[ -s "$STUB_ROOT/deleted" ]]; then
  pass "a sandbox that never becomes Ready is a sandbox failure naming the last phase, and is deleted"
else
  fail "a sandbox that never becomes Ready (rc=$RC status=$STATUS log: $(cat "$LOG") deleted: $(cat "$STUB_ROOT/deleted"))"
fi

run 'echo ok' 30 STUB_CREATE_RC=1 STUB_GET_RC=1
if [[ $RC -eq 125 && "$STATUS" == sandbox ]] && grep -q 'sandbox create failed' "$LOG"; then
  pass "a failed create is a sandbox failure"
else
  fail "a failed create (rc=$RC status=$STATUS log: $(cat "$LOG"))"
fi

run 'echo ok' 30 STUB_PROVIDER_RC=1
if [[ $RC -eq 125 && "$STATUS" == sandbox ]] && grep -q "provider 'package-registries' is not on the gateway" "$LOG"; then
  pass "a missing egress provider is a sandbox failure before anything is created"
else
  fail "a missing egress provider (rc=$RC status=$STATUS log: $(cat "$LOG"))"
fi

echo ""
echo "=== $TESTS tests, $FAILURES failures ==="
[[ $FAILURES -eq 0 ]]
