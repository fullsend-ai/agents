#!/usr/bin/env bash
# after_each hook (eval/local/code-rhai): save what the judges need from the agent's
# PR before the ephemeral repo is deleted, and run the repo's own tests on it.
#
# Needs output/fixture-state.json from capture-fixture.sh. Writes two trees:
#
#   output/   (read by the Python check judges)
#     pr.json            number, url, head, base, title, body, files, +/-
#     agent-outcome.json {"outcome":"pr"|"declined"|"failed", ...}: "declined" =
#                        the agent finished cleanly, opened no PR, and left a
#                        final message (its stated reason); the judges branch
#                        on this. A capture or fixture failure is "failed" with
#                        "infrastructure": true, whatever the agent said, and
#                        output/infrastructure-failure.json is written, which
#                        run-functional.sh counts as a case failure (the hook's
#                        own exit code is swallowed by the harness's
#                        continue-on-failure hook mode).
#     regression.json    {command, exit_code, timed_out, sandbox_failed, ...}
#     regression.log     raw test output (run inside a throwaway OpenShell
#                        sandbox by run-in-sandbox.sh, never on this host)
#
#   judge/    (staged into the agent judge's working directory, read with tools)
#     task.md            the task description the agent was given (input.yaml)
#     notes.md           annotations.judge_notes, or "none"
#     pr.md              PR title, URL, files changed, the agent's description
#     diff.patch         the PR diff (capped at PR_DIFF_MAX_BYTES, default 400000)
#     tests.md           regression command, exit code, tail of the log
#     pr-head/           full checkout of the PR head, no .git / .venv / node_modules
#     agent-final-message.md  the agent's last message (always written)
#     repo-snapshot/     on a decline only: the repository the agent was given,
#                        so the decline judge can check the stated reason
#
# If no PR exists, pr.json records pr_found=false and the rest is skipped.
set -euo pipefail

CASE_WORKSPACE="${CASE_WORKSPACE:?CASE_WORKSPACE is required}"
CASE_SOURCE_DIR="${CASE_SOURCE_DIR:?CASE_SOURCE_DIR is required}"
EPHEMERAL_REPO="${EPHEMERAL_REPO:?EPHEMERAL_REPO is required}"
OUTPUT_DIR="${CASE_WORKSPACE}/output"
JUDGE_DIR="${CASE_WORKSPACE}/judge"
STATE_FILE="${OUTPUT_DIR}/fixture-state.json"
ANNOTATIONS="${CASE_SOURCE_DIR}/annotations.yaml"
INPUT="${CASE_SOURCE_DIR}/input.yaml"
MAX_BYTES="${PR_DIFF_MAX_BYTES:-400000}"
mkdir -p "$OUTPUT_DIR" "$JUDGE_DIR"

final_msg=""
json_str() { # one JSON string literal, without jq (which may be the missing tool)
  # Control characters are dropped or spaced rather than escaped: the values
  # are this script's own messages, and a reader must never get invalid JSON.
  local v; v=$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')
  v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//$'\n'/ }"; v="${v//$'\t'/ }"; v="${v//$'\r'/ }"
  printf '"%s"' "$v"
}
write_marker() { # reason: the file run-functional.sh counts as a case failure
  printf '{"reason": %s, "hook": "capture-pr-artifacts.sh", "at": "%s"}\n' \
    "$(json_str "$1")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUTPUT_DIR/infrastructure-failure.json"
}
write_outcome() { # outcome reason [infrastructure:true|false]
  # The one writer of agent-outcome.json. jq escapes anything; the printf
  # form exists for the case where jq is the missing tool and carries the
  # same keys (final_msg is necessarily empty before the tool check passes).
  if command -v jq >/dev/null; then
    jq -n -c --arg o "$1" --arg r "$2" --arg m "$final_msg" --argjson infra "${3:-false}" \
      '{outcome: $o, reason: $r, infrastructure: $infra, final_message_chars: ($m|length), final_message_excerpt: $m[0:400]}' \
      > "$OUTPUT_DIR/agent-outcome.json"
  else
    printf '{"outcome": %s, "reason": %s, "infrastructure": %s, "final_message_chars": 0, "final_message_excerpt": ""}\n' \
      "$(json_str "$1")" "$(json_str "$2")" "${3:-false}" > "$OUTPUT_DIR/agent-outcome.json"
  fi
  # The outcome is known from here on; a later failure is a gap in the
  # artifacts, not in knowing what the agent did.
  trap - ERR
}
# Anything that exits this script before an outcome is recorded is a capture
# failure (a fixture record jq cannot parse, a gh call that errored). set -e
# alone would leave neither an outcome nor a marker, and the harness swallows
# the hook's exit code, so the case would read as clean. The trap routes
# every such exit through the same two files infra_fail writes.
on_err() { # line exit-code
  local why="capture hook aborted at line $1 (exit $2)"
  write_marker "$why"
  write_outcome failed "$why" true
  echo "outcome: failed, infrastructure ($why)" >&2
}
trap 'on_err "$LINENO" "$?"' ERR

# A missing tool is a capture failure too, and must leave the same two files.
missing=()
for cmd in gh yq jq git timeout rsync openshell run-in-sandbox.sh; do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
  why="required tools not found in PATH: ${missing[*]}"
  write_marker "$why"
  write_outcome failed "$why" true
  echo "ERROR: $why" >&2
  echo "outcome: failed, infrastructure ($why)" >&2
  exit 1
fi

# Task description and author notes: always written, so the judge can read
# them even when the run produced nothing to grade.
{
  echo "# Task description given to the agent"; echo
  echo "## Title"; echo; yq -r '.fixture.title' "$INPUT"; echo
  echo "## Body"; echo; yq -r '.fixture.body' "$INPUT"
} > "$JUDGE_DIR/task.md"
notes=$(yq -r '.judge_notes // ""' "$ANNOTATIONS")
{
  echo "# Notes from the case author"; echo
  echo "Things the task leaves open, or that must not be held against the agent."; echo
  if [[ -n "$notes" ]]; then printf '%s\n' "$notes"; else echo "none"; fi
} > "$JUDGE_DIR/notes.md"

# The agent's final message, whatever the runtime (extract-final-message.py
# understands the Claude Code, pi and codex transcript shapes).
run_dir=$(find "$OUTPUT_DIR" -maxdepth 1 -type d -name 'fs-cod-*' | head -1)
if [[ -n "$run_dir" ]]; then
  final_msg=$(extract-final-message.py "$run_dir" 2>/dev/null || true)
fi
{
  echo "# The agent's final message"; echo
  if [[ -n "$final_msg" ]]; then printf '%s\n' "$final_msg"; else echo "(no final message found in the transcript)"; fi
} > "$JUDGE_DIR/agent-final-message.md"

no_pr_files() { # reason: the pr.json / pr.md / regression files every no-PR path writes
  jq -n --arg r "$1" '{pr_found: false, reason: $r}' > "$OUTPUT_DIR/pr.json"
  printf '# Pull request\n\nNo pull request was produced: %s\n' "$1" > "$JUDGE_DIR/pr.md"
  # No PR head to test: say so explicitly, so the regression check can report
  # "not applicable" instead of mistaking a missing file for a failed capture.
  jq -n --arg r "$1" '{command: null, exit_code: null, not_applicable: true, reason: ("no PR: " + $r)}' \
    > "$OUTPUT_DIR/regression.json"
  printf '# Repository tests\n\nNot applicable: no pull request was produced.\n' > "$JUDGE_DIR/tests.md"
}

# An infrastructure or capture failure this script can name (the fixture
# record is missing, the PR head ref is malformed): nothing is known about
# what the agent did. Never "declined", whatever final message the agent left
# (the decline judge would grade a reason the agent never gave). The harness
# runs after_each hooks with continue-on-failure, so a non-zero exit here
# never reaches the run result; the marker file is what run-functional.sh
# counts as a case failure. Failures this script did not anticipate reach the
# same two files through the ERR trap above.
infra_fail() {
  no_pr_files "$1"
  write_marker "$1"
  write_outcome failed "$1" true
  echo "outcome: failed, infrastructure ($1)" >&2
  exit 1
}

no_pr() {
  no_pr_files "$1"
  # Declined = the run finished (metrics.json exists) and the agent said why;
  # otherwise the run failed or produced nothing readable. Only for the one
  # path where the fixture record was read and no agent PR was in it.
  if [[ -n "$final_msg" && -f "$run_dir/metrics.json" ]]; then
    write_outcome declined "$1"
    # Stage the repository the agent was given so the decline judge can
    # verify claims like "this endpoint already exists".
    rsync -a --exclude .git "$CASE_SOURCE_DIR/repo/" "$JUDGE_DIR/repo-snapshot/"
    echo "outcome: declined (final message ${#final_msg} chars); staged repo-snapshot/"
  else
    write_outcome failed "$1"
    echo "outcome: failed ($1)"
  fi
  exit 0
}
[[ -f "$STATE_FILE" ]] || infra_fail "fixture-state.json missing; capture-fixture.sh did not run"
# Only the agent's own PR counts: fullsend's post-script pushes agent/<issue>-<slug>
# branches. Anything else on the throwaway repo (Dependabot, for one) is ignored.
pr=$(jq -c '[(.pull_requests // [])[] | select(((.state|ascii_upcase) == "OPEN" or (.state|ascii_upcase) == "MERGED") and ((.head // "") | startswith("agent/")))] | first // empty' "$STATE_FILE")
[[ -n "$pr" ]] || no_pr "no open/merged PR on an agent/ branch in fixture-state.json"
num=$(jq -r .number <<<"$pr")
head_ref=$(jq -r '.head // empty' <<<"$pr")
[[ "$head_ref" =~ ^[A-Za-z0-9._/-]+$ ]] || infra_fail "unexpected head ref: $head_ref"

# PR metadata + the agent's own description.
gh pr view "$num" --repo "$EPHEMERAL_REPO" --json number,url,title,body,headRefName,baseRefName,headRefOid,files,additions,deletions \
  --jq '{pr_found: true, number, url, title, body, head: .headRefName, base: .baseRefName, head_sha: .headRefOid,
         additions, deletions, files: [.files[].path]}' > "$OUTPUT_DIR/pr.json"
{
  echo "# Pull request"; echo
  echo "Title: $(jq -r .title "$OUTPUT_DIR/pr.json")"
  echo "URL: $(jq -r .url "$OUTPUT_DIR/pr.json")"
  echo "Branch: $(jq -r .head "$OUTPUT_DIR/pr.json") -> $(jq -r .base "$OUTPUT_DIR/pr.json")"
  echo "Files changed: $(jq -r '.files|length' "$OUTPUT_DIR/pr.json") (+$(jq -r .additions "$OUTPUT_DIR/pr.json") / -$(jq -r .deletions "$OUTPUT_DIR/pr.json"))"; echo
  jq -r '.files[] | "- " + .' "$OUTPUT_DIR/pr.json"; echo
  echo "## Description written by the agent"; echo
  # fullsend's post-script appends a "Post-script verification" checklist
  # (branch name, secret scans) to every PR it opens. That is pipeline
  # boilerplate, identical on every PR, so it is dropped from the judge's copy.
  # output/pr.json and the PR on GitHub keep the full text.
  jq -r '.body // "(empty)"' "$OUTPUT_DIR/pr.json" | sed '/^### Post-script verification/,$d'
} > "$JUDGE_DIR/pr.md"

write_outcome pr "agent PR #${num}"

# Diff, size-capped so the judge's reading stays bounded.
diff_rc=0
gh pr diff "$num" --repo "$EPHEMERAL_REPO" > "$JUDGE_DIR/diff.full" 2> "$JUDGE_DIR/diff.err" || diff_rc=$?
if (( diff_rc != 0 )); then
  # Never hand the judge an empty diff that looks like a real one.
  printf '[DIFF CAPTURE FAILED: `gh pr diff` exited %s. Judge the change from pr-head/ only.]\n%s\n' \
    "$diff_rc" "$(cat "$JUDGE_DIR/diff.err")" > "$JUDGE_DIR/diff.full"
  jq --argjson rc "$diff_rc" '. + {diff_captured: false, diff_exit_code: $rc}' "$OUTPUT_DIR/pr.json" > "$OUTPUT_DIR/pr.json.tmp" \
    && mv "$OUTPUT_DIR/pr.json.tmp" "$OUTPUT_DIR/pr.json"
  echo "WARNING: gh pr diff failed (exit $diff_rc); recorded in pr.json and diff.patch" >&2
fi
rm -f "$JUDGE_DIR/diff.err"
size=$(wc -c < "$JUDGE_DIR/diff.full" | tr -d ' ')
if (( size > MAX_BYTES )); then
  head -c "$MAX_BYTES" "$JUDGE_DIR/diff.full" > "$JUDGE_DIR/diff.patch"
  printf '\n\n[diff truncated by capture-pr-artifacts.sh: %s of %s bytes shown; the full change is in pr-head/]\n' "$MAX_BYTES" "$size" >> "$JUDGE_DIR/diff.patch"
else
  mv "$JUDGE_DIR/diff.full" "$JUDGE_DIR/diff.patch"
fi
rm -f "$JUDGE_DIR/diff.full"
echo "Saved PR #${num} metadata and diff (${size} bytes)"

# Checkout of the PR head for the judge to read around the change.
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# shellcheck disable=SC2016 # expanded by git at credential time, as in setup-fixture.sh
GH_CRED_HELPER='!f(){ echo "password=${GH_TOKEN}"; };f'
cmd=$(yq -r '.regression_tests.command // ""' "$ANNOTATIONS")
tmo=$(yq -r '.test_timeout_s // 1800' "$ANNOTATIONS")
if ! git -c "credential.helper=${GH_CRED_HELPER}" clone --quiet --branch "$head_ref" \
     "https://x-access-token@github.com/${EPHEMERAL_REPO}.git" "$WORK/pr"; then
  jq -n --arg c "$cmd" '{command: $c, exit_code: null, clone_failed: true}' > "$OUTPUT_DIR/regression.json"
  printf '# Repository tests\n\nCould not clone the PR head; tests not run.\n' > "$JUDGE_DIR/tests.md"
  exit 0
fi
rsync -a --exclude .git --exclude .venv --exclude node_modules "$WORK/pr/" "$JUDGE_DIR/pr-head/"
echo "Saved PR head checkout -> ${JUDGE_DIR}/pr-head/ ($(find "$JUDGE_DIR/pr-head" -type f | wc -l | tr -d ' ') files)"

# Regression tests on the PR head, using the repo's own command from annotations.
if [[ -z "$cmd" || "$cmd" == "TODO" ]]; then
  jq -n '{command: null, exit_code: null, skipped: true, reason: "annotations.regression_tests.command not set"}' > "$OUTPUT_DIR/regression.json"
  printf '# Repository tests\n\nNot run: no regression command is set for this case.\n' > "$JUDGE_DIR/tests.md"
  exit 0
fi
echo "Running regression tests: $cmd"
rc=0
# The PR head is agent-written code built from untrusted inputs. It runs in a
# throwaway OpenShell sandbox (the coder's image, registry-only network, no
# credentials), not on this host: see run-in-sandbox.sh for what is and is
# not isolated.
run-in-sandbox.sh "$WORK/pr" "$cmd" "$tmo" "$OUTPUT_DIR/regression.log" || rc=$?
# Classification comes from the runner's status file, not the exit code: a
# test command can itself exit 124 or 125.
status=$(cat "$OUTPUT_DIR/regression.log.status" 2>/dev/null || echo sandbox)
timed_out=false; [[ "$status" == timeout ]] && timed_out=true
sandbox_failed=false; [[ "$status" == sandbox ]] && sandbox_failed=true
rm -f "$OUTPUT_DIR/regression.log.status"
jq -n --arg c "$cmd" --argjson rc "$rc" --argjson to "$timed_out" --argjson sf "$sandbox_failed" --argjson t "$tmo" \
  '{command: $c, exit_code: $rc, timed_out: $to, sandbox_failed: $sf, timeout_s: $t, log: "output/regression.log"}' > "$OUTPUT_DIR/regression.json"
{
  echo "# Repository tests on the PR head"; echo
  echo "Command: $cmd"
  echo "Run inside a throwaway OpenShell sandbox built from the coding agent's image."
  if [[ "$sandbox_failed" == true ]]; then echo "Result: NOT RUN, the sandbox could not be set up (exit 125); this says nothing about the PR"
  elif [[ "$timed_out" == true ]]; then echo "Result: TIMED OUT after ${tmo}s"
  elif [[ $rc -eq 0 ]]; then echo "Result: PASSED (exit 0)"
  else echo "Result: FAILED (exit $rc)"; fi
  echo; echo "Last 60 lines of output:"; echo; echo '```'; tail -60 "$OUTPUT_DIR/regression.log"; echo '```'
} > "$JUDGE_DIR/tests.md"
echo "Regression tests: exit $rc"
