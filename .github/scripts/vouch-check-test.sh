#!/usr/bin/env bash
# vouch-check-test.sh — Tests for the inline script in .github/workflows/vouch-check.yml
#
# Run from the repo root: bash .github/scripts/vouch-check-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${SCRIPT_DIR}/../workflows/vouch-check.yml"
FAILURES=0
TESTS=0

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: vouch-check-test (node not available)"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Extract the github-script body from the workflow. The script block is
# indented 12 spaces under `script: |`; blank lines are dropped (harmless).
extract_script() {
  awk '
    /^[[:space:]]*script: \|/ { in_script = 1; next }
    in_script && /^ {12}/ { sub(/^ {12}/, ""); print }
  ' "${WORKFLOW}"
}

# Node harness: reads the script body on stdin and the scenario name from
# argv[2], stubs github/context/core, runs the script, and asserts on the
# recorded side effects. Exits 0 on pass, 1 on fail.
cat > "${TMP_DIR}/harness.js" <<'HARNESS'
'use strict';
const fs = require('fs');

const source = fs.readFileSync(0, 'utf8');
const scenario = process.argv[2];

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

async function runScenario({ authorType, permissionStatus, permissionError, contentError, contentUsernames, createCommentError }) {
  const calls = { setFailed: [], warning: [], pullsUpdate: 0, createComment: 0, logs: [] };

  const context = {
    repo: { owner: 'fullsend-ai', repo: 'agents' },
    payload: { pull_request: { number: 42, user: { login: 'alice', type: authorType } } },
  };

  const github = {
    rest: {
      repos: {
        getCollaboratorPermissionLevel: async () => {
          if (permissionError) throw permissionError;
          if (permissionStatus === 404) {
            const err = new Error('Not Found');
            err.status = 404;
            throw err;
          }
          return { data: { role_name: 'read' } };
        },
        getContent: async () => {
          if (contentError) throw contentError;
          const usernames = contentUsernames || ['bob'];
          return { data: { content: Buffer.from(usernames.join('\n')).toString('base64') } };
        },
      },
      pulls: { update: async () => { calls.pullsUpdate += 1; } },
      issues: { createComment: async () => { if (createCommentError) throw createCommentError; calls.createComment += 1; } },
    },
  };

  const core = { setFailed: (m) => calls.setFailed.push(String(m)), warning: (m) => calls.warning.push(String(m)) };
  const consoleStub = { log: (...a) => calls.logs.push(a.join(' ')) };

  const fn = new AsyncFunction('context', 'github', 'core', 'console', 'Buffer', source);
  await fn(context, github, core, consoleStub, Buffer);

  return calls;
}

function fail(reason) {
  console.log('FAIL', scenario, '—', reason);
  process.exit(1);
}

(async () => {
  if (scenario === 'db-outage') {
    const calls = await runScenario({
      authorType: 'User',
      permissionStatus: 404,
      contentError: new Error('canonical Vouch DB unavailable'),
    });
    const failed = calls.setFailed.some((m) => m.includes('Could not read VOUCHED.td'));
    const leftOpen = calls.pullsUpdate === 0;
    const noComment = calls.createComment === 0;
    if (!(failed && leftOpen && noComment)) {
      fail(JSON.stringify(calls));
    }
    console.log('PASS db-outage');
    process.exit(0);
  }

  if (scenario === 'not-vouched') {
    const calls = await runScenario({
      authorType: 'User',
      permissionStatus: 404,
      contentUsernames: ['bob'],
    });
    if (!(calls.setFailed.length === 0 && calls.pullsUpdate === 1 && calls.createComment === 1)) {
      fail(JSON.stringify(calls));
    }
    console.log('PASS not-vouched');
    process.exit(0);
  }

  if (scenario === 'sanitize') {
    const hostile = 'boom::set-output name=x\n\u001b[31mRED\u001b[0m\r\nnext';
    const calls = await runScenario({
      authorType: 'User',
      permissionStatus: 404,
      contentError: new Error(hostile),
    });
    const msg = calls.setFailed.find((m) => m.includes('Could not read VOUCHED.td'));
    if (!msg) fail('no setFailed message recorded');
    if (msg.includes('\n') || msg.includes('\r') || msg.includes('::') || msg.includes('\u001b')) {
      fail('raw control characters leaked: ' + JSON.stringify(msg));
    }
    console.log('PASS sanitize');
    process.exit(0);
  }

  if (scenario === 'collaborator-error') {
    const hostile = 'boom::set-output name=x\n\u001b[31mRED\u001b[0m';
    const permErr = new Error(hostile);
    permErr.status = 403;
    const calls = await runScenario({
      authorType: 'User',
      permissionError: permErr,
    });
    const msg = calls.setFailed.find((m) => m.includes('Could not check collaborator permission'));
    if (!msg) fail('no collaborator setFailed message recorded');
    if (msg.includes('\n') || msg.includes('\r') || msg.includes('::') || msg.includes('\u001b')) {
      fail('raw control characters leaked: ' + JSON.stringify(msg));
    }
    if (calls.pullsUpdate !== 0 || calls.createComment !== 0) {
      fail('collaborator error proceeded to close/comment: ' + JSON.stringify(calls));
    }
    console.log('PASS collaborator-error');
    process.exit(0);
  }

  if (scenario === 'comment-error') {
    const hostile = 'boom::set-output name=x\n\u001b[31mRED\u001b[0m';
    const calls = await runScenario({
      authorType: 'User',
      permissionStatus: 404,
      contentUsernames: ['bob'],
      createCommentError: new Error(hostile),
    });
    const msg = calls.warning.find((m) => m.includes('Could not post explanation comment'));
    if (!msg) fail('no warning message recorded');
    if (msg.includes('\n') || msg.includes('\r') || msg.includes('::') || msg.includes('\u001b')) {
      fail('raw control characters leaked in warning: ' + JSON.stringify(msg));
    }
    console.log('PASS comment-error');
    process.exit(0);
  }

  fail('unknown scenario ' + scenario);
})();
HARNESS

run_scenario() {
  extract_script | node "${TMP_DIR}/harness.js" "$1"
}

assert_pass() {
  local scenario="$1"
  local label="$2"
  TESTS=$((TESTS + 1))
  if run_scenario "${scenario}" >/dev/null 2>&1; then
    echo "PASS: ${label}"
  else
    echo "FAIL: ${label}"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- Test cases ---
assert_pass "db-outage" "db-outage: job fails and PR is left open"
assert_pass "not-vouched" "not-vouched: PR closed and comment posted (harness control)"
assert_pass "sanitize" "sanitize: API error text stripped of workflow-command characters"
assert_pass "collaborator-error" "collaborator-error: permission failure sanitized and does not close/comment"
assert_pass "comment-error" "comment-error: comment failure warning sanitized"

echo "=== ${TESTS} tests, ${FAILURES} failures ==="
if [[ "${FAILURES}" -gt 0 ]]; then
  exit 1
fi
