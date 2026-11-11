#!/usr/bin/env bash
# GENERATED from pre-code-cve.src.sh — DO NOT EDIT. Run: make script-build
# pre-code-cve.sh — DRAFT. Host gate in front of the code agent for a work
# item labelled `cve`. Selected by an overlay in harness/code.yaml; runs on
# the runner before the sandbox exists, then hands over to the ordinary
# pre-script.
#
# The code agent's trigger already requires the `cve:affected` label. A label
# says a verdict existed once. This gate checks the verdict itself:
#   1. a valid receipt exists for this work item (lib/cve-receipt.lib.sh);
#   2. it is for this repository, says known_affected, and carries a ready
#      plan the code agent is allowed to execute (not a rebuild);
#   3. it is still current: the assessed branch is at the assessed commit, or
#      nothing the plan depends on has changed since (the plan's change paths
#      and any dependency manifest or lockfile).
# Any failure skips the run with the reason. Nothing is widened: the receipt
# can stop a run or narrow it, never authorize more.
#
# Required env: ISSUE_URL, REPO_FULL_NAME, TARGET_REPO_DIR; GH_TOKEN (GitHub
#   work item) or JIRA_BASE_URL + JIRA_TOKEN [+ JIRA_USER_EMAIL] (Jira).

set -euo pipefail

: "${ISSUE_URL:?ISSUE_URL must be set}"
: "${REPO_FULL_NAME:?REPO_FULL_NAME must be set}"
: "${TARGET_REPO_DIR:?TARGET_REPO_DIR must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prescript-output.lib.sh
# BEGIN bundled: lib/prescript-output.lib.sh
# prescript-output.lib.sh — Write pre-script output protocol lines.
#
# The pre-script output protocol (fullsend docs/normative/prescript-output/v1,
# fullsend-ai/fullsend#4718) is the contract between `fullsend run` and a
# harness pre-script: the CLI exports FULLSEND_PRESCRIPT_OUTPUT naming a
# file, and the script appends key=value lines to it — `skipped=true` (plus
# an optional `reason`) stops the run before sandbox creation. Under a CLI
# that predates the protocol the variable is unset and writes are skipped,
# so the run proceeds — the protocol's version-skew contract.
#
# Source from a pre-script .src.sh:
#   source "${SCRIPT_DIR}/lib/prescript-output.lib.sh"

# shellcheck shell=bash

[[ -n "${PRESCRIPT_OUTPUT_SH_LOADED:-}" ]] && return 0
PRESCRIPT_OUTPUT_SH_LOADED=1

# prescript_output KEY VALUE — append a protocol line, if the CLI
# supports the protocol. Values must be single-line (protocol grammar).
prescript_output() {
  if [[ -n "${FULLSEND_PRESCRIPT_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "${FULLSEND_PRESCRIPT_OUTPUT}"
  fi
}
# END bundled: lib/prescript-output.lib.sh
# shellcheck source=lib/jira-auth.lib.sh
# BEGIN bundled: lib/jira-auth.lib.sh
# shellcheck shell=bash
# jira-auth.lib.sh — Jira credential-mode selection for host-side scripts.
#
# Shared by the Jira triage and scribe ops libraries and post-code.sh, and
# bundled into each script that sources it. Two credential modes
# (fullsend#9007):
#
#   token + email — bot user: Basic auth with email:token
#   token only    — service account: Bearer auth with the token
#
# An email that is empty or only whitespace counts as absent. A harness
# that maps an unset FULLSEND_JIRA_EMAIL to JIRA_USER_EMAIL yields an empty
# string, and that must select Bearer, never an empty-user Basic header.
#
# Every helper takes the token and email as arguments, so callers that
# withhold the credentials from their environment can pass saved copies.

[[ -n "${JIRA_AUTH_SH_LOADED:-}" ]] && return 0
JIRA_AUTH_SH_LOADED=1

# Print the email with surrounding whitespace removed. Empty output means
# no email, which selects Bearer auth.
#
# Usage: jira_auth_email <email>
jira_auth_email() {
  local email="$1"
  email="${email#"${email%%[![:space:]]*}"}"
  email="${email%"${email##*[![:space:]]}"}"
  printf '%s' "${email}"
}

# Run curl with the Authorization for the selected mode, followed by the
# caller's arguments. Fails without calling curl when the token is empty.
#
# Usage: jira_auth_curl <token> <email> [curl args...]
jira_auth_curl() {
  local token="$1"
  local email
  email="$(jira_auth_email "$2")"
  shift 2
  if [[ -z "${token}" ]]; then
    echo "ERROR: Jira token is empty" >&2
    return 1
  fi
  if [[ -n "${email}" ]]; then
    curl --user "${email}:${token}" "$@"
  else
    curl --oauth2-bearer "${token}" "$@"
  fi
}

# Run the fullsend CLI with the Jira credentials it reads from its
# environment: FULLSEND_JIRA_TOKEN always, FULLSEND_JIRA_EMAIL only for a
# bot user. In Bearer mode an inherited FULLSEND_JIRA_EMAIL is removed, so
# the CLI cannot pick Basic auth. The values go through the environment,
# never the command line.
#
# Usage: jira_auth_fullsend <fullsend-bin> <token> <email> [cli args...]
jira_auth_fullsend() {
  local bin="$1"
  local token="$2"
  local email
  email="$(jira_auth_email "$3")"
  shift 3
  if [[ -z "${token}" ]]; then
    echo "ERROR: Jira token is empty" >&2
    return 1
  fi
  if [[ -n "${email}" ]]; then
    FULLSEND_JIRA_TOKEN="${token}" FULLSEND_JIRA_EMAIL="${email}" "${bin}" "$@"
  else
    (
      unset FULLSEND_JIRA_EMAIL
      FULLSEND_JIRA_TOKEN="${token}" "${bin}" "$@"
    )
  fi
}
# END bundled: lib/jira-auth.lib.sh
# shellcheck source=lib/cve-receipt.lib.sh
# BEGIN bundled: lib/cve-receipt.lib.sh
# shellcheck shell=bash
# cve-receipt.lib.sh — DRAFT. A machine-readable record of the cve agent's
# verdict, so the code agent's host scripts can check it before and after
# coding instead of trusting a label or a prompt.
#
# post-cve writes it; pre-code-cve and post-code-cve read it.
#   GitHub: a hidden marker inside the sticky verdict comment
#           <!-- fullsend-cve-receipt:v1 <base64 JSON> -->
#           Only a comment authored by a bot account is accepted.
#   Jira:   the issue property `fullsend.cve.receipt`.
#
# Trust: whoever can edit the bot's comment (repository write access) or the
# issue property (Jira edit permission) can change a receipt. That is the same
# trust the `ready-to-code` label already carries. The receipt is therefore
# never used to widen anything: it can only stop a run, or narrow what a run
# may change. Every field is shape-checked on read.
#
# Receipt: {"v":1, "id", "repository", "ref", "commit", "status",
#           "plan_state", "option", "change_paths": [...]}

[[ -n "${CVE_RECEIPT_SH_LOADED:-}" ]] && return 0
CVE_RECEIPT_SH_LOADED=1

CVE_RECEIPT_PROPERTY="fullsend.cve.receipt"

# cve_receipt_build FINDING_JSON RESULT_JSON → receipt JSON on stdout
cve_receipt_build() {
  jq -n --slurpfile f "$1" --slurpfile r "$2" '{
    v: 1,
    id: $f[0].vulnerability.id,
    repository: $f[0].target.repository,
    ref: $f[0].target.ref,
    commit: $f[0].target.commit,
    status: $r[0].status,
    plan_state: ($r[0].remediation.plan_state // ""),
    option: ($r[0].remediation.option // ""),
    change_paths: ($r[0].remediation.change_paths // [])
  }'
}

# cve_receipt_valid → reads receipt JSON on stdin; prints it compact when the
# shape is acceptable, fails otherwise.
cve_receipt_valid() {
  jq -ce 'select(
    type == "object" and .v == 1
    and (.id | type == "string" and test("^(CVE-[0-9]{4}-[0-9]{4,}|GHSA(-[23456789cfghjmpqrvwx]{4}){3})$"))
    and (.repository | type == "string" and test("^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$"))
    and (.ref | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$") and (contains("..") | not))
    and (.commit | type == "string" and test("^[0-9a-f]{40}$"))
    and (.status | type == "string") and (.plan_state | type == "string") and (.option | type == "string")
    and (.change_paths | type == "array" and length <= 200)
    and all(.change_paths[]; type == "string" and test("^[A-Za-z0-9._@+-][A-Za-z0-9._/@+-]{0,299}$") and (contains("..") | not))
  )'
}

# cve_receipt_embed RECEIPT_JSON → the hidden comment marker
cve_receipt_embed() {
  printf '<!-- fullsend-cve-receipt:v1 %s -->' "$(printf '%s' "$1" | base64 | tr -d '\n')"
}

# cve_receipt_read_github OWNER/NAME ISSUE_NUMBER → latest valid receipt from a
# bot-authored comment, or nothing.
cve_receipt_read_github() {
  local bodies marker
  bodies=$(gh api --paginate "repos/$1/issues/$2/comments?per_page=100" \
    --jq '.[] | select(.user.type == "Bot") | .body') || return 1
  marker=$(grep -oE '<!-- fullsend-cve-receipt:v1 [A-Za-z0-9+/=]+ -->' <<<"${bodies}" | tail -n 1) || true
  [[ -n "${marker}" ]] || return 0
  marker="${marker#<!-- fullsend-cve-receipt:v1 }"
  printf '%s' "${marker% -->}" | base64 -d 2>/dev/null | cve_receipt_valid || true
}

# cve_jira_api_base → where Jira REST calls go: JIRA_API_URL (the API gateway
# fullsend sets for a Jira-sourced run) when set, else the site URL. The
# credentials are sent there, so anything but https is refused.
cve_jira_api_base() {
  local base="${JIRA_API_URL:-${JIRA_BASE_URL:-}}"
  while [[ "${base}" == */ ]]; do base="${base%/}"; done
  [[ "${base}" == https://* ]] || { echo "ERROR: the Jira API URL must start with https://" >&2; return 1; }
  printf '%s\n' "${base}"
}

# cve_receipt_read_jira KEY → valid receipt from the issue property, or nothing.
cve_receipt_read_jira() {
  local raw base
  base=$(cve_jira_api_base) || return 1
  raw=$(jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" -sS -m 30 \
    "${base}/rest/api/2/issue/$1/properties/${CVE_RECEIPT_PROPERTY}") || return 1
  jq -c '.value // empty' <<<"${raw}" 2>/dev/null | cve_receipt_valid || true
}

# cve_receipt_write_jira KEY RECEIPT_JSON
cve_receipt_write_jira() {
  local base
  base=$(cve_jira_api_base) || return 1
  jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" -fsS -m 30 -X PUT \
    -H 'Content-Type: application/json' --data "$2" \
    "${base}/rest/api/2/issue/$1/properties/${CVE_RECEIPT_PROPERTY}" >/dev/null
}

# cve_receipt_staging_dir → where pre-code-cve leaves the admitted receipt for
# post-code-cve.
cve_receipt_staging_dir() {
  printf '%s/fullsend-cve-code' "${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
}
# END bundled: lib/cve-receipt.lib.sh
# shellcheck source=lib/cve-git.lib.sh
# BEGIN bundled: lib/cve-git.lib.sh
# shellcheck shell=bash
# cve-git.lib.sh — DRAFT. Getting a branch into the runner's checkout.
#
# Fullsend checks out the default branch only, one commit deep, and does not
# keep the checkout's credentials. A release branch, or the commit a verdict
# was made against, is therefore usually not there. These helpers fetch what
# is missing, with the run's own read token when a plain fetch is refused.
#
# The token is passed to git through its environment, never on a command
# line, never in the remote URL, and it is not written to the repository's
# configuration.

[[ -n "${CVE_GIT_SH_LOADED:-}" ]] && return 0
CVE_GIT_SH_LOADED=1

# cve_git_fetch DIR ARGS… → `git fetch origin ARGS…`, retried once with the
# forge token if the plain fetch fails and the remote is https.
cve_git_fetch() {
  local dir="$1"; shift
  GIT_TERMINAL_PROMPT=0 git -C "${dir}" fetch -q origin "$@" 2>/dev/null && return 0
  local tok="" user="x-access-token" url host b64
  case "${FULLSEND_FORGE:-github}" in
    github) tok="${GH_TOKEN:-}" ;;
    gitlab) tok="${GITLAB_TOKEN:-}"; user="oauth2" ;;
  esac
  [[ -n "${tok}" ]] || return 1
  url=$(git -C "${dir}" remote get-url origin 2>/dev/null) || return 1
  [[ "${url}" =~ ^https://([^/@]+@)?([A-Za-z0-9.-]+(:[0-9]+)?)/ ]] || return 1
  host="${BASH_REMATCH[2]}"
  b64=$(printf '%s:%s' "${user}" "${tok}" | base64 | tr -d '\n')
  GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.https://${host}/.extraheader" \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic ${b64}" \
    git -C "${dir}" fetch -q origin "$@" 2>/dev/null
}

cve_git_is_shallow() {
  [[ "$(git -C "$1" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]
}

# cve_git_branch_commit DIR BRANCH → the branch's commit on stdout, or 1.
cve_git_branch_commit() {
  git -C "$1" rev-parse -q --verify "refs/remotes/origin/$2^{commit}" \
    || git -C "$1" rev-parse -q --verify "refs/heads/$2^{commit}"
}

# cve_git_fetch_tip DIR BRANCH → make the branch's current commit available.
# One commit is enough to assess a tree, so a shallow checkout stays shallow.
cve_git_fetch_tip() {
  local -a depth=()
  cve_git_is_shallow "$1" && depth=(--depth 1)
  cve_git_fetch "$1" "${depth[@]}" "+refs/heads/$2:refs/remotes/origin/$2"
}

# cve_git_fetch_history DIR BRANCH → make the branch's whole history
# available. Comparing an assessed commit with the branch as it is now needs
# every commit between them, which a shallow checkout does not have.
cve_git_fetch_history() {
  local -a deep=()
  cve_git_is_shallow "$1" && deep=(--unshallow)
  cve_git_fetch "$1" "${deep[@]}" "+refs/heads/$2:refs/remotes/origin/$2"
}
# END bundled: lib/cve-git.lib.sh

STAGE="$(cve_receipt_staging_dir)"
rm -rf "${STAGE}"

stop() {
  echo "::warning::cve code gate: not coding — $1"
  prescript_output skipped true
  prescript_output reason "cve code gate: $1"
  exit 0
}

# --- 1. Read the receipt from the work item's own tracker --------------------
NEXT="pre-code.sh"
if [[ "${ISSUE_URL}" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/issues/([0-9]+)$ ]]; then
  RECEIPT=$(cve_receipt_read_github "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}") \
    || { echo "::error::cve code gate: could not read the work item's comments"; exit 1; }
elif [[ "${ISSUE_URL}" =~ /browse/([A-Z][A-Z0-9]+-[0-9]+)$ ]]; then
  NEXT="pre-code-jira.sh"
  : "${JIRA_BASE_URL:?JIRA_BASE_URL must be set for a Jira work item}" "${JIRA_TOKEN:?JIRA_TOKEN must be set for a Jira work item}"
  RECEIPT=$(cve_receipt_read_jira "${BASH_REMATCH[1]}") \
    || { echo "::error::cve code gate: could not read the Jira issue property"; exit 1; }
else
  stop "the work item's tracker is not supported"
fi
[[ -n "${RECEIPT}" ]] || stop "no cve verdict is recorded on this work item; run /fs-cve first"
field() { jq -r "$1" <<<"${RECEIPT}"; }

# --- 2. Is it a plan the code agent may execute? -----------------------------
[[ "$(field .repository)" == "${REPO_FULL_NAME}" ]] \
  || stop "the verdict is for $(field .repository), not this repository"
[[ "$(field .status)" == "known_affected" ]] \
  || stop "the latest verdict is $(field .status), not known_affected"
[[ "$(field .plan_state)" == "ready" ]] \
  || stop "the remediation plan is not ready"
[[ "$(field .option)" != "rebuild" && -n "$(field .option)" ]] \
  || stop "the plan is a rebuild, which needs a build handoff and no code change"
[[ "$(jq '.change_paths | length' <<<"${RECEIPT}")" -gt 0 ]] \
  || stop "the plan names no files to change"

# --- 3. Is it still current? --------------------------------------------------
REF="$(field .ref)"; COMMIT="$(field .commit)"
# The runner's checkout is the default branch, one commit deep. Comparing the
# assessed commit with the branch as it is now needs the branch and every
# commit between the two, so fetch them when any of that is missing.
if cve_git_is_shallow "${TARGET_REPO_DIR}" \
   || ! git -C "${TARGET_REPO_DIR}" cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
   || ! cve_git_branch_commit "${TARGET_REPO_DIR}" "${REF}" >/dev/null; then
  cve_git_fetch_history "${TARGET_REPO_DIR}" "${REF}" || true
fi
HEAD_NOW=$(cve_git_branch_commit "${TARGET_REPO_DIR}" "${REF}") \
  || stop "branch ${REF} could not be fetched, or no longer exists; run /fs-cve again"
git -C "${TARGET_REPO_DIR}" cat-file -e "${COMMIT}^{commit}" 2>/dev/null \
  || stop "the assessed commit ${COMMIT:0:12} is not on branch ${REF} any more; run /fs-cve again"
if [[ "${HEAD_NOW}" != "${COMMIT}" ]]; then
  git -C "${TARGET_REPO_DIR}" merge-base --is-ancestor "${COMMIT}" "${HEAD_NOW}" \
    || stop "branch ${REF} was rewritten since the assessment; run /fs-cve again"
  mapfile -t PLAN_PATHS < <(jq -r '.change_paths[]' <<<"${RECEIPT}")
  MANIFESTS=(':(glob)**/requirements*.txt' ':(glob)**/*.lock' ':(glob)**/go.mod' ':(glob)**/go.sum'
    ':(glob)**/package.json' ':(glob)**/package-lock.json' ':(glob)**/pnpm-lock.yaml'
    ':(glob)**/Pipfile' ':(glob)**/pyproject.toml' ':(glob)**/Cargo.toml' ':(glob)**/pom.xml'
    ':(glob)**/build.gradle*' ':(glob)**/Gemfile')
  CHANGED=$(git -C "${TARGET_REPO_DIR}" diff --name-only "${COMMIT}" "${HEAD_NOW}" -- "${PLAN_PATHS[@]}" "${MANIFESTS[@]}")
  if [[ -n "${CHANGED}" ]]; then
    stop "the verdict is stale: since ${COMMIT:0:12}, branch ${REF} changed $(wc -l <<<"${CHANGED}" | tr -d ' ') file(s) the plan depends on (first: $(sed -n 1p <<<"${CHANGED}")); run /fs-cve again"
  fi
  echo "::notice::cve code gate: ${REF} moved from ${COMMIT:0:12} to ${HEAD_NOW:0:12}; nothing the plan depends on changed"
fi

# --- 4. Admit, and leave the receipt for post-code-cve ------------------------
mkdir -p "${STAGE}"
printf '%s\n' "${RECEIPT}" > "${STAGE}/receipt.json"
echo "::notice::cve code gate: admitted $(field .id) on ${REF} ($(field .option), $(jq '.change_paths | length' <<<"${RECEIPT}") path(s))"
exec bash "${SCRIPT_DIR}/${NEXT}" "$@"
