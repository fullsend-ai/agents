#!/usr/bin/env bash
# GENERATED from post-code-cve.src.sh — DO NOT EDIT. Run: make script-build
# post-code-cve.sh — DRAFT. Host check behind the code agent for a work item
# labelled `cve`, before anything is pushed. Selected by an overlay in
# harness/code.yaml; hands over to the ordinary post-script when it passes.
#
# Checks the change against the receipt pre-code-cve admitted:
#   1. the pull request targets the branch that was assessed;
#   2. every changed file is one the plan named. A plan entry ending in "/"
#      covers that directory (a re-vendored tree, for example).
# A failure exits non-zero, so nothing is pushed and no pull request opens.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

RECEIPT_FILE="$(cve_receipt_staging_dir)/receipt.json"
[[ -f "${RECEIPT_FILE}" ]] \
  || { echo "::error::cve code check: no admitted receipt at ${RECEIPT_FILE}; pre-code-cve did not run"; exit 1; }
RECEIPT=$(cve_receipt_valid < "${RECEIPT_FILE}") \
  || { echo "::error::cve code check: the admitted receipt is not valid"; exit 1; }
REF=$(jq -r .ref <<<"${RECEIPT}"); COMMIT=$(jq -r .commit <<<"${RECEIPT}")

RESULT=""
if [[ -n "${FULLSEND_VALIDATED_ITERATION_DIR:-}" ]]; then
  RESULT="${FULLSEND_VALIDATED_ITERATION_DIR}/agent-result.json"
else
  for dir in iteration-*/output; do
    [[ -f "${dir}/agent-result.json" ]] && RESULT="${dir}/agent-result.json"
  done
fi

REPO="${REPO_DIR:-repo}"
FILES=""
if [[ -d "${REPO}" ]]; then
  BASE=$(git -C "${REPO}" merge-base "origin/${REF}" HEAD 2>/dev/null) || BASE="${COMMIT}"
  FILES=$(git -C "${REPO}" diff --name-only "${BASE}" HEAD 2>/dev/null) || FILES=""
fi

if [[ -n "${FILES}" ]]; then
  TARGET=""
  [[ -n "${RESULT}" && -f "${RESULT}" ]] && TARGET=$(jq -r '.target_branch // empty' "${RESULT}")
  if [[ "${TARGET}" != "${REF}" ]]; then
    echo "::error::cve code check: the change targets '${TARGET:-<unset>}' but the verdict is for branch '${REF}'; nothing was pushed"
    exit 1
  fi
  OUTSIDE=$(jq -rn --arg files "${FILES}" --argjson r "${RECEIPT}" '
    ($files | split("\n") | map(select(length > 0))) as $f
    | $f[] | . as $p
    | select(any($r.change_paths[]; . as $d | ($d == $p) or (($d | endswith("/")) and ($p | startswith($d)))) | not)')
  if [[ -n "${OUTSIDE}" ]]; then
    echo "::error::cve code check: the change touches file(s) the assessed plan did not name; nothing was pushed"
    sed 's/^/  outside the plan: /' <<<"${OUTSIDE}" | head -n 20
    echo "The plan named: $(jq -r '.change_paths | join(", ")' <<<"${RECEIPT}")"
    echo "Re-run /fs-cve if the plan needs to grow; the code agent may not widen it."
    exit 1
  fi
  echo "::notice::cve code check: $(wc -l <<<"${FILES}" | tr -d ' ') changed file(s), all inside the assessed plan, targeting ${REF}"
fi

exec bash "${SCRIPT_DIR}/post-code.sh" "$@"
