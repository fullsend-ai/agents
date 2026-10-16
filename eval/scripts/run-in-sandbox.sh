#!/usr/bin/env bash
# Run a repository's own test command on a checkout inside a throwaway OpenShell
# sandbox, instead of on the machine that runs the eval.
#
#   run-in-sandbox.sh <checkout-dir> <command> <timeout-s> <log-file>
#
# The checkout is agent-written code built from untrusted inputs (or, for
# check-case.sh, an upstream snapshot). On the eval host it would run with the
# host's home directory in reach: gcloud application-default credentials, the
# gh config, ~/.npmrc, ~/.ssh. So it runs where the coding agent itself ran:
#
#   - image:    the coder's sandbox image from harness/code.yaml (same toolchains
#               the agent used to run these tests, same pin)
#   - policy:   policies/base.yaml from the same harness
#   - network:  only the package-registries provider is attached. It carries no
#               credential and opens the npm, PyPI and Go module registries to
#               the package managers only; everything else, GitHub included, is
#               unreachable. fullsend creates that provider on the gateway for
#               every coder run, so it exists wherever the coder has run once.
#   - identity: the sandbox user, HOME=/sandbox, no host environment at all
#
# Exit status: the command's own exit code; 124 when the command hit the
# timeout; 125 when the sandbox could not be created, loaded or reached (the
# log file says why). Because a command can itself exit 124 or 125, the
# classification is also written to <log-file>.status as one word: "command"
# (exit code is the command's), "timeout" or "sandbox"; callers read that
# file, not the exit code. The log file holds the command's combined output.
set -uo pipefail
DIR="${1:?usage: run-in-sandbox.sh <checkout-dir> <command> <timeout-s> <log-file>}"
CMD="${2:?command}"; TMO="${3:?timeout-s}"; LOG="${4:?log-file}"
AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="${EVAL_SANDBOX_HARNESS:-$AGENTS_ROOT/harness/code.yaml}"
PROVIDER="${EVAL_SANDBOX_PROVIDER:-package-registries}"
READY_TIMEOUT="${EVAL_SANDBOX_READY_TIMEOUT:-900}"
# Memory for the test run: jest-style runners spawn a worker per CPU and the default
# sandbox limit SIGKILLs them (odh-dashboard, 2026-10-14). Override with EVAL_SANDBOX_MEMORY.
STATUS="$LOG.status"
sandbox_fail() { echo "$1" | tee -a "$LOG" >&2; echo sandbox > "$STATUS"; exit 125; }
: > "$LOG"; echo sandbox > "$STATUS"   # until the command reports its own status
for c in openshell yq tar timeout; do
  command -v "$c" >/dev/null || sandbox_fail "run-in-sandbox: $c is required but not found in PATH"
done
[[ -d "$DIR" ]] || sandbox_fail "run-in-sandbox: not a directory: $DIR"
[[ -f "$HARNESS" ]] || sandbox_fail "run-in-sandbox: harness not found: $HARNESS"
IMAGE=$(yq -r '.image // ""' "$HARNESS"); POLICY_REL=$(yq -r '.policy // ""' "$HARNESS")
[[ -n "$IMAGE" && -n "$POLICY_REL" ]] || sandbox_fail "run-in-sandbox: $HARNESS has no image/policy"
POLICY="$(dirname "$HARNESS")/../$POLICY_REL"
[[ -f "$POLICY" ]] || POLICY="$AGENTS_ROOT/$POLICY_REL"
[[ -f "$POLICY" ]] || sandbox_fail "run-in-sandbox: policy not found: $POLICY_REL"
if ! openshell provider get "$PROVIDER" >/dev/null 2>&1 </dev/null; then
  sandbox_fail "run-in-sandbox: OpenShell provider '$PROVIDER' is not on the gateway. fullsend creates it on the first coder run; run one, or create it from fullsend's fullsend-package-registries profile."
fi

NAME="eval-reg-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"  # openshell caps names at 19 chars
TARBALL=$(mktemp "${TMPDIR:-/tmp}/eval-reg-XXXXXX")  # BSD mktemp wants the Xs last
cleanup() {
  # shellcheck disable=SC2317 # invoked indirectly via trap
  rm -f "$TARBALL"
  # shellcheck disable=SC2317
  openshell sandbox delete "$NAME" >/dev/null 2>&1 </dev/null || true
}
trap cleanup EXIT

# All openshell calls take </dev/null: the CLI streams stdin to the remote
# command, and an inherited pipe that never closes makes `exec` hang.
echo "run-in-sandbox: creating $NAME from $IMAGE" >&2
if ! openshell sandbox create --name "$NAME" --keep --no-auto-providers --no-tty \
      --from "$IMAGE" --policy "$POLICY" --provider "$PROVIDER" \
      --memory "${EVAL_SANDBOX_MEMORY:-8Gi}" \
      --detach -- sleep infinity </dev/null >>"$LOG" 2>&1; then
  if ! openshell sandbox get "$NAME" >/dev/null 2>&1 </dev/null; then
    sandbox_fail "run-in-sandbox: sandbox create failed"
  fi
fi
deadline=$(( $(date +%s) + READY_TIMEOUT ))
# Read the whole status, then test it: `get | grep -q` under pipefail is a
# race, since the CLI exits 101 when grep closes the pipe first, and the loop
# then never sees Ready (2026-10-16, three runs timed out on a Ready sandbox).
until state=$(openshell sandbox get "$NAME" 2>/dev/null </dev/null || true); [[ "$state" == *"Phase: Ready"* ]]; do
  if (( $(date +%s) > deadline )); then
    sandbox_fail "run-in-sandbox: sandbox $NAME not Ready after ${READY_TIMEOUT}s (last status: $(printf '%s' "$state" | grep -m1 'Phase:' || echo unknown))"
  fi
  sleep 3
done

# Ship the checkout as one archive (openshell's own upload filters by
# .gitignore and skips symlink targets; a tarball keeps the tree exact).
if ! COPYFILE_DISABLE=1 tar --no-xattrs -czf "$TARBALL" -C "$DIR" . 2>>"$LOG"; then
  sandbox_fail "run-in-sandbox: could not archive $DIR"
fi
if ! openshell sandbox upload "$NAME" "$TARBALL" /tmp/ </dev/null >>"$LOG" 2>&1; then
  sandbox_fail "run-in-sandbox: upload to $NAME failed"
fi
remote_tar="/tmp/$(basename "$TARBALL")"

# The sandbox shell does not inherit the image's PATH; set what the image
# itself declares, plus the Go env the coder harness sets. The egress proxy
# drops a few connections when a Go build fetches ~200 modules at once
# ("unexpected EOF" from proxy.golang.org); a pipe-separated GOPROXY list
# retries the same proxy, since Go falls through on any error at a '|'. npm
# gets retries and fewer sockets for the same reason. Browser-binary
# post-install downloads (Cypress, Puppeteer, Playwright) go to hosts the
# policy does not allow and nothing in the sandbox can run a browser, so
# they are skipped.
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
remote_script="set -e
export PATH=/usr/local/go/bin:/sandbox/.venv/bin:/usr/local/bin:/usr/bin:/bin:/sandbox/go/bin
export HOME=/sandbox GOPATH=/sandbox/go GOMODCACHE=/sandbox/go/pkg/mod LANG=C.UTF-8 TERM=dumb CI=1
export GOPROXY='https://proxy.golang.org|https://proxy.golang.org|https://proxy.golang.org'
export npm_config_fetch_retries=5 npm_config_fetch_retry_mintimeout=20000 npm_config_fetch_retry_maxtimeout=120000 npm_config_maxsockets=6
export CYPRESS_INSTALL_BINARY=0 PUPPETEER_SKIP_DOWNLOAD=1 PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
mkdir -p /sandbox/workspace/regression && tar -xzf $(q "$remote_tar") -C /sandbox/workspace/regression
cd /sandbox/workspace/regression
cmd_rc=0; bash -o pipefail -c $(q "$CMD") || cmd_rc=\$?
printf '\\n__EVAL_RC__=%s\\n' \"\$cmd_rc\""
# The command's own status travels on a sentinel line, not in the exec exit
# code: openshell's code is the command's only when the sandbox lived to the
# end, and a dropped relay, an evicted sandbox or an OOM kill would otherwise
# read as "tests failed" (while a command that itself exits 125 would read as
# sandbox_failed). A missing sentinel means the sandbox died first. Only a
# whole line of the exact shape counts, so test output that quotes the
# sentinel text is neither read as a status nor stripped from the log; the
# newline printed first keeps the sentinel on its own line when the command's
# last output had none (at the cost of one blank line in the log when it did).
echo "run-in-sandbox: running the command (timeout ${TMO}s)" >&2
t0=$(date +%s); exec_rc=0
timeout "$(( TMO + 60 ))" openshell sandbox exec --name "$NAME" --no-tty --timeout "$TMO" \
  -- sh -c "$remote_script" </dev/null >>"$LOG" 2>&1 || exec_rc=$?
elapsed=$(( $(date +%s) - t0 ))
# A timeout outranks any sentinel: the wrapper prints its line and exits at
# once, so a sentinel followed by a run that hit the limit was printed by the
# command itself (test output on the PR head), not by the wrapper.
if (( exec_rc == 124 || elapsed >= TMO )); then
  echo "run-in-sandbox: command timed out after ${TMO}s" >>"$LOG"; echo timeout > "$STATUS"; exit 124
fi
sentinel=$(tr -d '\r' < "$LOG" | grep -o '^__EVAL_RC__=[0-9]\{1,\}$' | tail -n 1)
if [[ -n "$sentinel" ]]; then
  rc="${sentinel#__EVAL_RC__=}"
  sed -i.bak '/^__EVAL_RC__=[0-9]\{1,\}[[:cntrl:]]*$/d' "$LOG" && rm -f "$LOG.bak"
  echo command > "$STATUS"
  exit "$rc"
fi
sandbox_fail "run-in-sandbox: the sandbox did not return the command's status (openshell exec exit ${exec_rc} after ${elapsed}s)"
