#!/usr/bin/env bash
# after_each hook: capture fixture state for judges.
#
# Snapshots the GitHub issue/PR state into output/fixture-state.json
# so judges can evaluate the agent's work.
#
# Required env (forward-propagated from setup-fixture.sh):
#   EPHEMERAL_REPO  — org/name of the ephemeral repo
#   FIXTURE_NUMBER  — issue or PR number
#   FIXTURE_TYPE    — "issue" or "pull_request"
#   FIXTURE_URL     — full URL of the fixture
#   FORGE           — "github"
#
# Required env (set by harness):
#   CASE_WORKSPACE  — path to the case workspace
#
# Optional env (set by harness):
#   CASE_SOURCE_DIR — original case directory; read to decide whether the case
#                     needs a PR diff captured. Missing means "capture it".
set -euo pipefail

CASE_WORKSPACE="${CASE_WORKSPACE:?CASE_WORKSPACE is required}"
EPHEMERAL_REPO="${EPHEMERAL_REPO:?EPHEMERAL_REPO is required}"
FIXTURE_NUMBER="${FIXTURE_NUMBER:?FIXTURE_NUMBER is required}"
FIXTURE_TYPE="${FIXTURE_TYPE:?FIXTURE_TYPE is required}"
FIXTURE_URL="${FIXTURE_URL:?FIXTURE_URL is required}"

OUTPUT_DIR="${CASE_WORKSPACE}/output"
mkdir -p "$OUTPUT_DIR"
STATE_FILE="${OUTPUT_DIR}/fixture-state.json"

# Run a command up to 3 times; print stdout on success. Used for flaky gh calls.
# Suppress stderr on early attempts; keep it on the final attempt for diagnostics.
retry_cmd() {
  local attempt out
  for attempt in 1 2 3; do
    if [[ $attempt -lt 3 ]]; then
      if out=$("$@" 2>/dev/null); then
        printf '%s' "$out"
        return 0
      fi
      sleep $((attempt))
    else
      if out=$("$@"); then
        printf '%s' "$out"
        return 0
      fi
      return 1
    fi
  done
  return 1
}

# Best-effort gh pr view for changed file paths. On persistent failure returns
# non-zero so callers can record files_fetch_failed instead of a silent [].
fetch_pr_files() {
  local num="$1"
  local files
  if files=$(retry_cmd gh pr view "$num" --repo "$EPHEMERAL_REPO" --json files \
    --jq '[(.files // [])[].path]'); then
    printf '%s' "$files"
    return 0
  fi
  return 1
}

# Best-effort gh pr diff, written to output/pr-<num>.diff so content-level
# judges (removed_symbols in eval/code/eval.yaml) can inspect what the PR
# actually changed, not just which files it touched. On persistent failure
# returns non-zero so callers can record diff_fetch_failed instead of a
# missing file being indistinguishable from "capture never ran".
fetch_pr_diff() {
  local num="$1"
  local diff attempt
  # Non-empty is part of success: retry_cmd passes on exit status alone,
  # and an exit-0 empty body during post-creation replication would
  # short-circuit the readiness poll below — recording a blank diff as
  # healthy and letting removed_symbols blame the agent for a capture
  # gap. A PR here always changes files, so an empty diff is never valid.
  if diff=$(retry_cmd gh pr diff "$num" --repo "$EPHEMERAL_REPO") && [[ -n "$diff" ]]; then
    printf '%s\n' "$diff" > "${OUTPUT_DIR}/pr-${num}.diff"
    return 0
  fi
  # retry_cmd's ~3s of backoff lands immediately after PR creation, exactly
  # when the API may still be replicating. Poll a little longer before giving
  # up: removed_symbols runs at min_pass_rate 1.0, so a transient miss here
  # fails an otherwise-correct fix. Mirrors resolve_head_sha's readiness poll;
  # worst case ~10s more, well inside the 60s after_each timeout.
  echo "WARNING: gh pr diff not ready for PR #${num}; polling..." >&2
  for attempt in 1 2 3 4; do
    sleep $((attempt))
    if diff=$(gh pr diff "$num" --repo "$EPHEMERAL_REPO" 2>/dev/null) && [[ -n "$diff" ]]; then
      printf '%s\n' "$diff" > "${OUTPUT_DIR}/pr-${num}.diff"
      return 0
    fi
  done
  return 1
}

# Only cases declaring removed_symbols consume output/pr-<num>.diff, so the
# extra `gh pr diff` call and its failure surface are skipped for the rest
# (001-fix-add declares none). Defaults to capturing when the annotations
# cannot be read — a judge must never fail for want of an artifact this
# script decided on its own to skip.
case_wants_pr_diff() {
  local annotations="${CASE_SOURCE_DIR:-}/annotations.yaml"
  [[ -n "${CASE_SOURCE_DIR:-}" && -f "$annotations" ]] || return 0
  grep -qE '^[[:space:]]*removed_symbols[[:space:]]*:' "$annotations"
}

# Build/test gate for removed_symbols cases. The judge is diff-scoped, so a
# usage site commented out in place (one real deletion line plus an exempt
# comment addition) satisfies the diff inspection while the tree no longer
# compiles — only building and testing the actual PR head catches that.
# Pure half: given a checkout, emit {"build_exit":N,"test_exit":N}, or a
# recorded {"skipped":reason} when there is nothing to build (no go.mod) or
# nothing to build WITH (no go toolchain) — recorded rather than silent so
# the fixture_checks judge message shows why nothing was graded.
run_go_checks() {
  local dir="$1" build_exit=0 test_exit=0
  if [[ ! -f "${dir}/go.mod" ]]; then
    printf '{"skipped":"no go.mod"}'
    return 0
  fi
  if ! command -v go >/dev/null 2>&1; then
    printf '{"skipped":"go not installed"}'
    return 0
  fi
  # The checkout is agent-authored code, and `go test` compiles and RUNS
  # it. This is the one place that output executes outside the podman
  # sandbox, on a runner whose environment carries live credentials
  # (EVAL_GH_TOKEN, GOOGLE_APPLICATION_CREDENTIALS, OIDC id-token) under
  # pull_request_target. The scrubbed environment below is load-bearing —
  # do not simplify it away: env -i drops every runner secret from the
  # child, GOPROXY=off keeps the build off the network, -mod=readonly
  # stops an agent-edited go.mod from fetching, GOTOOLCHAIN=local pins
  # the toolchain, CGO_ENABLED=0 removes the C toolchain from the attack
  # surface, and HOME/GOPATH/GOCACHE keep all writes inside the scratch
  # dir. Each invocation gets its own timeout so an agent-written test
  # that blocks records exit 124 instead of overrunning the hook budget
  # (see after_each in eval/code/eval.yaml for the 180s derivation);
  # `timeout` is coreutils — present on CI, absent on stock macOS, where
  # the gate runs unbounded rather than not at all.
  local godir scratch
  godir="$(dirname "$(command -v go)")"
  scratch="$(mktemp -d)"
  mkdir -p "${scratch}/home"
  local scrub=(env -i "PATH=${godir}:/usr/bin:/bin" "HOME=${scratch}/home"
    GOTOOLCHAIN=local GOPROXY=off GOFLAGS=-mod=readonly CGO_ENABLED=0
    "GOCACHE=${scratch}/gocache" "GOPATH=${scratch}/gopath")
  # `runner` is never an empty array: expanding one under `set -u` is an
  # unbound-variable error on bash 3.2 (macOS's /bin/bash).
  local runner=(go)
  command -v timeout >/dev/null 2>&1 && runner=(timeout 45 go)
  (cd "$dir" && "${scrub[@]}" "${runner[@]}" build ./...) >/dev/null 2>&1 || build_exit=$?
  (cd "$dir" && "${scrub[@]}" "${runner[@]}" test ./...) >/dev/null 2>&1 || test_exit=$?
  rm -rf "$scratch"
  printf '{"build_exit":%d,"test_exit":%d}' "$build_exit" "$test_exit"
}

# Clone half: shallow-clone the PR head branch and run run_go_checks on it.
# Clone attempts get a fresh target dir each round (a half-written dir from
# a failed attempt would make every retry fail with "already exists").
# A persistent clone failure is recorded as {"clone_failed":true} and the
# fixture_checks judge fails on it — same evidence-must-exist stance as
# diff_fetch_failed, since this too runs at min_pass_rate 1.0.
run_pr_checks() {
  local repo="$1" head_ref="$2" tmp attempt out
  if [[ -z "$head_ref" ]]; then
    printf '{"clone_failed":true}'
    return 0
  fi
  tmp=$(mktemp -d)
  out='{"clone_failed":true}'
  # 6 attempts with linear backoff (~15s), matching resolve_head_sha's
  # patience: cloning a branch pushed seconds earlier races the same
  # replication window its ref read does, and deserves the same budget.
  # The WARNING makes a slow-but-successful clone distinguishable from a
  # genuinely broken one in the run artifacts.
  for attempt in 1 2 3 4 5 6; do
    rm -rf "${tmp}/co"
    if gh repo clone "$repo" "${tmp}/co" -- --depth 1 --branch "$head_ref" >/dev/null 2>&1; then
      out=$(run_go_checks "${tmp}/co")
      break
    fi
    if [[ $attempt -eq 1 ]]; then
      echo "WARNING: clone of ${repo}@${head_ref} not ready; retrying..." >&2
    fi
    [[ $attempt -lt 6 ]] && sleep "$attempt"
  done
  rm -rf "$tmp"
  printf '%s' "$out"
}

# Resolve branch tip SHA via git refs API, polling if still at baseline.
# Poll up to 6 times with linear backoff (~21s total, within 60s after_each timeout).
# Prefer refs API over PR headRefOid — the latter can lag briefly after post-fix push.
#
# Sets globals RESOLVED_HEAD_SHA and HEAD_SHA_POLL_EXHAUSTED instead of
# printing to stdout, so callers can distinguish "polling exhausted while
# still at baseline" (possible push-propagation delay) from "confirmed no
# new commit" — printing over stdout and invoking via $(...) would lose
# HEAD_SHA_POLL_EXHAUSTED to the command-substitution subshell.
resolve_head_sha() {
  local repo="$1" head_ref="$2" baseline="${3:-}" initial_sha="${4:-}"
  local ref_sha attempt
  RESOLVED_HEAD_SHA="$initial_sha"
  HEAD_SHA_POLL_EXHAUSTED="false"

  if [[ ! "$head_ref" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "ERROR: unexpected PR head ref: ${head_ref}" >&2
    return 1
  fi

  if ref_sha=$(retry_cmd gh api "repos/${repo}/git/ref/heads/${head_ref}" \
    --jq '.object.sha'); then
    RESOLVED_HEAD_SHA="$ref_sha"
  fi

  if [[ -n "$baseline" && "$RESOLVED_HEAD_SHA" == "$baseline" ]]; then
    echo "WARNING: PR/branch tip still equals pre_agent_head; polling for push..." >&2
    for attempt in 1 2 3 4 5 6; do
      sleep $((attempt))
      if ref_sha=$(gh api "repos/${repo}/git/ref/heads/${head_ref}" \
        --jq '.object.sha' 2>/dev/null); then
        RESOLVED_HEAD_SHA="$ref_sha"
        if [[ "$RESOLVED_HEAD_SHA" != "$baseline" ]]; then
          break
        fi
      fi
    done
    if [[ "$RESOLVED_HEAD_SHA" == "$baseline" ]]; then
      HEAD_SHA_POLL_EXHAUSTED="true"
      echo "WARNING: polling exhausted after 6 attempts; head_sha still equals pre_agent_head (${baseline}). This may be a stale/failed read rather than proof the push never happened." >&2
    fi
  fi

  return 0
}

# Compare pre_agent_head...head_sha to get only the files touched by the
# fix run itself (not the fixture PR's original files). Prints a JSON array
# of filenames and returns 0 when there's nothing to compare — missing
# baseline/head_sha, or head_sha still equal to baseline — since that is a
# valid "no new files" result, not a fetch failure. Returns non-zero only
# when the gh api compare call itself fails.
files_changed_since() {
  local repo="$1" baseline="$2" head_sha="$3"
  if [[ -z "$baseline" || -z "$head_sha" || "$baseline" == "$head_sha" ]]; then
    printf '[]'
    return 0
  fi
  local files
  if files=$(retry_cmd gh api "repos/${repo}/compare/${baseline}...${head_sha}" \
    --jq '[(.files // [])[].filename]'); then
    printf '%s' "$files"
    return 0
  fi
  return 1
}

case "${FIXTURE_TYPE}" in
  issue)
    if ! issue_json=$(retry_cmd gh issue view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" \
      --json state,labels,assignees,milestone,title); then
      echo "ERROR: gh issue view failed for #${FIXTURE_NUMBER} after retries" >&2
      exit 1
    fi
    if ! comments_raw=$(retry_cmd gh issue view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" \
      --json comments); then
      echo "ERROR: gh issue view (comments) failed for #${FIXTURE_NUMBER} after retries" >&2
      exit 1
    fi
    comments_json=$(printf '%s' "$comments_raw" | jq \
      '[.comments[] | {author: .author.login, body: .body, created_at: .createdAt}]')
    # Code agent post-script opens exactly one PR today; --limit 1 is enough.
    # Raise the limit (or filter by headRefName) if a future case opens multiple.
    # gh pr list is best-effort so a transient API blip still yields fixture-state.json.
    if ! prs_json=$(retry_cmd gh pr list --repo "$EPHEMERAL_REPO" --state all --limit 1 \
      --json number,title,url,state,headRefName,baseRefName); then
      echo "WARNING: gh pr list failed for ${EPHEMERAL_REPO}; recording pull_requests=[]" >&2
      prs_json='[]'
    fi
    if [[ -z "$prs_json" ]]; then
      prs_json='[]'
    fi

    # Pass 1 — cheap reads only, then write fixture-state.json BEFORE the
    # expensive diff/clone/build stage below. The hook runs under
    # after_each's timeout, and everything stacked in front of the state
    # write is evidence lost if the process group is killed: with this
    # ordering an overrun in the gate degrades to a fixture_checks
    # failure ("no build/test checks captured"), instead of erasing the
    # input of every judge at once. checks:null / diff_fetch_failed:false
    # are the pre-gate placeholders the judges already fail closed on.
    pr_lines=()
    while IFS= read -r pr; do
      [[ -z "$pr" ]] && continue
      num=$(printf '%s' "$pr" | jq -r '.number')
      if files=$(fetch_pr_files "$num"); then
        pr_lines+=("$(printf '%s' "$pr" | jq -c --argjson files "$files" \
          '. + {head: .headRefName, base: .baseRefName, files: $files, files_fetch_failed: false, diff_fetch_failed: false, checks: null}
           | del(.headRefName, .baseRefName)')")
      else
        echo "WARNING: gh pr view failed for PR #${num}; marking files_fetch_failed" >&2
        pr_lines+=("$(printf '%s' "$pr" | jq -c \
          '. + {head: .headRefName, base: .baseRefName, files: null, files_fetch_failed: true, diff_fetch_failed: false, checks: null}
           | del(.headRefName, .baseRefName)')")
      fi
    done < <(printf '%s' "$prs_json" | jq -c '.[]')
    if [[ ${#pr_lines[@]} -eq 0 ]]; then
      prs_with_files='[]'
    else
      prs_with_files=$(printf '%s\n' "${pr_lines[@]}" | jq -s '.')
    fi

    jq -n \
      --arg fixture_type "issue" \
      --arg fixture_url "$FIXTURE_URL" \
      --argjson issue "$issue_json" \
      --argjson comments "$comments_json" \
      --argjson pull_requests "$prs_with_files" \
      '{
        fixture_type: $fixture_type,
        fixture_url: $fixture_url,
        state: $issue.state,
        title: $issue.title,
        labels: [($issue.labels // [])[] | .name],
        assignees: [($issue.assignees // [])[] | .login],
        milestone: ($issue.milestone.title // null),
        comments: $comments,
        pull_requests: $pull_requests
      }' > "$STATE_FILE"

    # Pass 2 — the expensive stage: diff fetch (readiness poll), head
    # clone, and the sandboxed build/test gate. Results are merged into
    # the state written above; the tmp+mv keeps a kill mid-write from
    # corrupting what pass 1 already secured.
    if case_wants_pr_diff; then
      while IFS= read -r pr; do
        [[ -z "$pr" ]] && continue
        num=$(printf '%s' "$pr" | jq -r '.number')
        diff_failed=false
        if ! fetch_pr_diff "$num"; then
          echo "WARNING: gh pr diff failed for PR #${num}; marking diff_fetch_failed" >&2
          diff_failed=true
        fi
        checks_json=$(run_pr_checks "$EPHEMERAL_REPO" "$(printf '%s' "$pr" | jq -r '.headRefName // empty')")
        jq --argjson num "$num" --argjson diff_failed "$diff_failed" --argjson checks "$checks_json" \
          '.pull_requests |= map(if .number == $num
             then .diff_fetch_failed = $diff_failed | .checks = $checks
             else . end)' \
          "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
      done < <(printf '%s' "$prs_json" | jq -c '.[]')
    fi
    ;;

  pull_request)
    # One retried gh call for metadata + comments + reviews + files, then shape
    # with jq. On persistent failure still write fixture-state.json so judges
    # fail clearly instead of the after_each hook aborting.
    pre_agent_head="${PRE_AGENT_HEAD:-}"
    if [[ -z "$pre_agent_head" && -f "${OUTPUT_DIR}/pre-agent-head.txt" ]]; then
      pre_agent_head=$(cat "${OUTPUT_DIR}/pre-agent-head.txt")
    fi

    if ! pr_raw=$(retry_cmd gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" \
      --json state,labels,assignees,milestone,title,mergeable,reviewDecision,headRefOid,headRefName,comments,reviews,files); then
      echo "WARNING: gh pr view failed for PR #${FIXTURE_NUMBER} after retries; writing pr_fetch_failed state" >&2
      jq -n \
        --arg fixture_type "pull_request" \
        --arg fixture_url "$FIXTURE_URL" \
        --arg pre_agent_head "$pre_agent_head" \
        '{
          fixture_type: $fixture_type,
          fixture_url: $fixture_url,
          pr_fetch_failed: true,
          state: null,
          title: null,
          labels: [],
          assignees: [],
          milestone: null,
          mergeable: null,
          review_decision: null,
          comments: [],
          reviews: [],
          head_sha: null,
          head_ref: null,
          head_sha_poll_exhausted: null,
          files: null,
          files_fetch_failed: true,
          files_changed_since_pre_agent_head: null,
          files_changed_since_pre_agent_head_failed: true,
          pre_agent_head: (if $pre_agent_head == "" then null else $pre_agent_head end)
        }' > "$STATE_FILE"
      echo "Captured ${FIXTURE_TYPE} state -> ${STATE_FILE}"
      exit 0
    fi

    head_ref=$(printf '%s' "$pr_raw" | jq -r '.headRefName // empty')
    initial_sha=$(printf '%s' "$pr_raw" | jq -r '.headRefOid // empty')
    head_sha="$initial_sha"
    head_sha_poll_exhausted="false"
    if [[ -n "$head_ref" ]]; then
      if resolve_head_sha "$EPHEMERAL_REPO" "$head_ref" "$pre_agent_head" "$initial_sha"; then
        head_sha="$RESOLVED_HEAD_SHA"
        head_sha_poll_exhausted="$HEAD_SHA_POLL_EXHAUSTED"
      else
        echo "WARNING: resolve_head_sha failed for ${head_ref}; using headRefOid" >&2
        head_sha="$initial_sha"
      fi
    fi
    resolved_head_sha=$(if [[ -z "$head_sha" ]]; then printf '%s' "$initial_sha"; else printf '%s' "$head_sha"; fi)

    # expected_files must prove the *fix run's own commit(s)* touched the
    # declared paths — the PR-aggregate `files` list below already includes
    # the fixture's original files and would pass even if the fix pushed
    # nothing relevant. Compare pre_agent_head...head_sha instead.
    files_since_failed="false"
    if ! files_since=$(files_changed_since "$EPHEMERAL_REPO" "$pre_agent_head" "$resolved_head_sha"); then
      echo "WARNING: gh api compare failed for ${pre_agent_head}...${resolved_head_sha}; marking files_changed_since_pre_agent_head_failed" >&2
      files_since='null'
      files_since_failed="true"
    fi

    jq -n \
      --arg fixture_type "pull_request" \
      --arg fixture_url "$FIXTURE_URL" \
      --argjson pr "$pr_raw" \
      --arg head_sha "$head_sha" \
      --arg pre_agent_head "$pre_agent_head" \
      --argjson files_since_pre_agent_head "$files_since" \
      --arg files_since_pre_agent_head_failed "$files_since_failed" \
      --arg head_sha_poll_exhausted "$head_sha_poll_exhausted" \
      '{
        fixture_type: $fixture_type,
        fixture_url: $fixture_url,
        pr_fetch_failed: false,
        state: $pr.state,
        title: $pr.title,
        labels: [($pr.labels // [])[] | .name],
        assignees: [($pr.assignees // [])[] | .login],
        milestone: ($pr.milestone.title // null),
        mergeable: $pr.mergeable,
        review_decision: $pr.reviewDecision,
        comments: [($pr.comments // [])[] | {author: .author.login, body: .body, created_at: .createdAt}],
        reviews: [($pr.reviews // [])[] | {author: .author.login, state: .state, body: .body}],
        head_sha: (if $head_sha == "" then $pr.headRefOid else $head_sha end),
        head_ref: $pr.headRefName,
        head_sha_poll_exhausted: ($head_sha_poll_exhausted == "true"),
        files: [($pr.files // [])[] | .path],
        files_fetch_failed: false,
        files_changed_since_pre_agent_head: $files_since_pre_agent_head,
        files_changed_since_pre_agent_head_failed: ($files_since_pre_agent_head_failed == "true"),
        pre_agent_head: (if $pre_agent_head == "" then null else $pre_agent_head end)
      }' > "$STATE_FILE"
    ;;

  *)
    echo "ERROR: unsupported fixture_type: ${FIXTURE_TYPE}" >&2
    exit 1
    ;;
esac

echo "Captured ${FIXTURE_TYPE} state -> ${STATE_FILE}"
