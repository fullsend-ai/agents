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
# log file says why). The log file holds the command's combined output.
set -uo pipefail
DIR="${1:?usage: run-in-sandbox.sh <checkout-dir> <command> <timeout-s> <log-file>}"
CMD="${2:?command}"; TMO="${3:?timeout-s}"; LOG="${4:?log-file}"
AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS="${EVAL_SANDBOX_HARNESS:-$AGENTS_ROOT/harness/code.yaml}"
PROVIDER="${EVAL_SANDBOX_PROVIDER:-package-registries}"
READY_TIMEOUT="${EVAL_SANDBOX_READY_TIMEOUT:-900}"
for c in openshell yq tar timeout; do
  command -v "$c" >/dev/null || { echo "run-in-sandbox: $c is required but not found in PATH" | tee "$LOG" >&2; exit 125; }
done
[[ -d "$DIR" ]] || { echo "run-in-sandbox: not a directory: $DIR" | tee "$LOG" >&2; exit 125; }
[[ -f "$HARNESS" ]] || { echo "run-in-sandbox: harness not found: $HARNESS" | tee "$LOG" >&2; exit 125; }
IMAGE=$(yq -r '.image // ""' "$HARNESS"); POLICY_REL=$(yq -r '.policy // ""' "$HARNESS")
[[ -n "$IMAGE" && -n "$POLICY_REL" ]] || { echo "run-in-sandbox: $HARNESS has no image/policy" | tee "$LOG" >&2; exit 125; }
POLICY="$(dirname "$HARNESS")/../$POLICY_REL"
[[ -f "$POLICY" ]] || POLICY="$AGENTS_ROOT/$POLICY_REL"
[[ -f "$POLICY" ]] || { echo "run-in-sandbox: policy not found: $POLICY_REL" | tee "$LOG" >&2; exit 125; }
if ! openshell provider get "$PROVIDER" >/dev/null 2>&1 </dev/null; then
  echo "run-in-sandbox: OpenShell provider '$PROVIDER' is not on the gateway. fullsend creates it on the first coder run; run one, or create it from fullsend's fullsend-package-registries profile." | tee "$LOG" >&2
  exit 125
fi

NAME="eval-reg-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"  # openshell caps names at 19 chars
TARBALL=$(mktemp "${TMPDIR:-/tmp}/eval-reg-XXXXXX")  # BSD mktemp wants the Xs last
cleanup() {
  rm -f "$TARBALL"
  openshell sandbox delete "$NAME" >/dev/null 2>&1 </dev/null || true
}
trap cleanup EXIT
: > "$LOG"

# All openshell calls take </dev/null: the CLI streams stdin to the remote
# command, and an inherited pipe that never closes makes `exec` hang.
echo "run-in-sandbox: creating $NAME from $IMAGE" >&2
if ! openshell sandbox create --name "$NAME" --keep --no-auto-providers --no-tty \
      --from "$IMAGE" --policy "$POLICY" --provider "$PROVIDER" \
      --detach -- sleep infinity </dev/null >>"$LOG" 2>&1; then
  if ! openshell sandbox get "$NAME" >/dev/null 2>&1 </dev/null; then
    echo "run-in-sandbox: sandbox create failed (see $LOG)" >&2; exit 125
  fi
fi
deadline=$(( $(date +%s) + READY_TIMEOUT ))
until openshell sandbox get "$NAME" 2>/dev/null </dev/null | grep -q 'Phase: Ready'; do
  if (( $(date +%s) > deadline )); then
    echo "run-in-sandbox: sandbox $NAME not Ready after ${READY_TIMEOUT}s" | tee -a "$LOG" >&2; exit 125
  fi
  sleep 3
done

# Ship the checkout as one archive (openshell's own upload filters by
# .gitignore and skips symlink targets; a tarball keeps the tree exact).
if ! COPYFILE_DISABLE=1 tar --no-xattrs -czf "$TARBALL" -C "$DIR" . 2>>"$LOG"; then
  echo "run-in-sandbox: could not archive $DIR" | tee -a "$LOG" >&2; exit 125
fi
if ! openshell sandbox upload "$NAME" "$TARBALL" /tmp/ </dev/null >>"$LOG" 2>&1; then
  echo "run-in-sandbox: upload to $NAME failed (see $LOG)" >&2; exit 125
fi
remote_tar="/tmp/$(basename "$TARBALL")"

# The sandbox shell does not inherit the image's PATH; set what the image
# itself declares, plus the Go env the coder harness sets. The egress proxy
# drops a few connections when a Go build fetches ~200 modules at once
# ("unexpected EOF" from proxy.golang.org); a pipe-separated GOPROXY list
# retries the same proxy, since Go falls through on any error at a '|'.
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
remote_script="set -e
export PATH=/usr/local/go/bin:/sandbox/.venv/bin:/usr/local/bin:/usr/bin:/bin:/sandbox/go/bin
export HOME=/sandbox GOPATH=/sandbox/go GOMODCACHE=/sandbox/go/pkg/mod LANG=C.UTF-8 TERM=dumb CI=1
export GOPROXY='https://proxy.golang.org|https://proxy.golang.org|https://proxy.golang.org'
mkdir -p /sandbox/workspace/regression && tar -xzf $(q "$remote_tar") -C /sandbox/workspace/regression
cd /sandbox/workspace/regression
exec bash -o pipefail -c $(q "$CMD")"
echo "run-in-sandbox: running the command (timeout ${TMO}s)" >&2
rc=0
timeout "$(( TMO + 60 ))" openshell sandbox exec --name "$NAME" --no-tty --timeout "$TMO" \
  -- sh -c "$remote_script" </dev/null >>"$LOG" 2>&1 || rc=$?
if (( rc == 124 )); then echo "run-in-sandbox: command timed out after ${TMO}s" >>"$LOG"; fi
exit "$rc"
