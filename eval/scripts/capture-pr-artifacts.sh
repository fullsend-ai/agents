#!/usr/bin/env bash
# after_each hook (eval/dev/code-rhai): save what the judges need from the agent's
# PR before the ephemeral repo is deleted, and run the repo's own tests on it.
#
# Needs output/fixture-state.json from capture-fixture.sh. Writes two trees:
#
#   output/   (read by the Python check judges)
#     pr.json            number, url, head, base, title, body, files, +/-
#     agent-outcome.json {"outcome":"pr"|"declined"|"failed", ...}: "declined" =
#                        the agent finished cleanly, opened no PR, and left a
#                        final message (its stated reason); the judges branch
#                        on this
#     regression.json    {command, exit_code, timed_out, ...}
#     regression.log     raw test output
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
for cmd in gh yq jq git timeout rsync; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd is required but not found in PATH" >&2; exit 1; }
done

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
final_msg=""
if [[ -n "$run_dir" ]]; then
  final_msg=$(extract-final-message.py "$run_dir" 2>/dev/null || true)
fi
{
  echo "# The agent's final message"; echo
  if [[ -n "$final_msg" ]]; then printf '%s\n' "$final_msg"; else echo "(no final message found in the transcript)"; fi
} > "$JUDGE_DIR/agent-final-message.md"

write_outcome() { # outcome reason
  jq -n -c --arg o "$1" --arg r "$2" --arg m "$final_msg" \
    '{outcome: $o, reason: $r, final_message_chars: ($m|length), final_message_excerpt: $m[0:400]}' \
    > "$OUTPUT_DIR/agent-outcome.json"
}

no_pr() {
  jq -n --arg r "$1" '{pr_found: false, reason: $r}' > "$OUTPUT_DIR/pr.json"
  printf '# Pull request\n\nNo pull request was produced: %s\n' "$1" > "$JUDGE_DIR/pr.md"
  # Declined = the run finished (metrics.json exists) and the agent said why;
  # otherwise the run failed or produced nothing readable.
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
[[ -f "$STATE_FILE" ]] || no_pr "fixture-state.json missing; capture-fixture.sh did not run"
# Only the agent's own PR counts: fullsend's post-script pushes agent/<issue>-<slug>
# branches. Anything else on the throwaway repo (Dependabot, for one) is ignored.
pr=$(jq -c '[(.pull_requests // [])[] | select(((.state|ascii_upcase) == "OPEN" or (.state|ascii_upcase) == "MERGED") and ((.head // "") | startswith("agent/")))] | first // empty' "$STATE_FILE")
[[ -n "$pr" ]] || no_pr "no open/merged PR on an agent/ branch in fixture-state.json"
num=$(jq -r .number <<<"$pr")
head_ref=$(jq -r '.head // empty' <<<"$pr")
[[ "$head_ref" =~ ^[A-Za-z0-9._/-]+$ ]] || no_pr "unexpected head ref: $head_ref"

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
gh pr diff "$num" --repo "$EPHEMERAL_REPO" > "$JUDGE_DIR/diff.full" || : > "$JUDGE_DIR/diff.full"
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
( cd "$WORK/pr" && timeout "$tmo" bash -o pipefail -c "$cmd" ) > "$OUTPUT_DIR/regression.log" 2>&1 || rc=$?
timed_out=false; [[ $rc -eq 124 ]] && timed_out=true
jq -n --arg c "$cmd" --argjson rc "$rc" --argjson to "$timed_out" --argjson t "$tmo" \
  '{command: $c, exit_code: $rc, timed_out: $to, timeout_s: $t, log: "output/regression.log"}' > "$OUTPUT_DIR/regression.json"
{
  echo "# Repository tests on the PR head"; echo
  echo "Command: $cmd"
  if [[ "$timed_out" == true ]]; then echo "Result: TIMED OUT after ${tmo}s"
  elif [[ $rc -eq 0 ]]; then echo "Result: PASSED (exit 0)"
  else echo "Result: FAILED (exit $rc)"; fi
  echo; echo "Last 60 lines of output:"; echo; echo '```'; tail -60 "$OUTPUT_DIR/regression.log"; echo '```'
} > "$JUDGE_DIR/tests.md"
echo "Regression tests: exit $rc"
