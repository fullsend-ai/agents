#!/usr/bin/env bash
# pre-cve.sh — DRAFT. Disclosure guard, normalization and evidence staging
# for the cve agent. Runs on the host before the sandbox exists.
#
# Fails CLOSED: anything that cannot be shown to be public is skipped with a
# visible reason (pre-script output protocol), and nothing reaches the model.
#
# Disclosure rules (proposed in the CVE approach ADR draft):
#   R1  Jira issue has a security level not listed for an
#       internal repository (CVE_JIRA_SECURITY_LEVELS)           → skip
#   R2  Work item has an embargo/confidential/private label     → skip
#   R3  The vulnerability id is not published in OSV            → skip
#   R4  The ticket's own text (title, description, comments) is staged only
#       where it cannot become more visible than it already is: when the
#       target repository is private or internal, or when the tracker is
#       itself public. A non-public tracker with a public repository gets
#       no ticket text, and so does any case where visibility cannot be
#       determined. CVE_TICKET_TEXT=on|off overrides; `on` for a public
#       repository is unsafe and says so in the run.
#
# Two things are kept apart. cve-finding.json holds only validated fields
# (lib/cve-normalize.lib.sh) and is the authority for the id, the package and
# the target. cve-ticket.json holds the ticket's text as untrusted context.
#
# Branches (lib/cve-fanout.lib.sh). With CVE_BRANCHES unset the run assesses
# the branch that is checked out, as before. With CVE_BRANCHES set:
#   - a work item that names a branch in that list is assessed on that
#     branch: this script checks it out before the sandbox exists;
#   - a GitHub work item that names no branch is a parent: this script
#     creates one child issue per branch and skips the run;
#   - a branch in CVE_BRANCHES_FOLLOW is never assessed on its own.
# The branch is a request from the work item; the list is the adopter's, and
# the commit is resolved here.
#
# Evaluation: CVE_VENDOR_VEX=off withholds the vendor VEX file. For a closed
# historical ticket that file states the answer, so a retrospective accuracy
# run must not stage it.
#
# Writes, under ${RUNNER_TEMP}/fullsend-cve-stage (the harness host_files
# entries name the same two paths, as harness/scribe.yaml does):
#   cve-finding.json   schemas/cve-finding.schema.json
#   cve-evidence.json  {"osv": [records…], "vendor_vex": [{"source", "document"}…], "withheld": [names…]}
#   cve-ticket.json    {"staged": true, title, description, comments[…]} or
#                      {"staged": false, "reason": "…"}
#
# Required env: ISSUE_URL, FULLSEND_TRACKER (or FULLSEND_FORGE),
#   TARGET_REPO_DIR, REPO_FULL_NAME, RUNNER_TEMP; GH_TOKEN (github) or
#   JIRA_BASE_URL + JIRA_TOKEN [+ JIRA_USER_EMAIL] (jira).
# Optional env: CVE_TICKET_TEXT (auto | on | off), CVE_JIRA_SECURITY_LEVELS, CVE_BRANCHES,
#   CVE_BRANCHES_FOLLOW, CVE_VEX_SOURCES (lib/cve-vex.lib.sh), CVE_VENDOR_VEX,
#   POST_CVE_DRY_RUN (a parent then prints the children instead of creating them).

set -euo pipefail

: "${ISSUE_URL:?ISSUE_URL must be set}"
: "${TARGET_REPO_DIR:?TARGET_REPO_DIR must be set}"
: "${REPO_FULL_NAME:?REPO_FULL_NAME must be set}"
: "${RUNNER_TEMP:?RUNNER_TEMP must be set (CI sets it; for a local run put RUNNER_TEMP=/tmp in the env file)}"
FULLSEND_TRACKER="${FULLSEND_TRACKER:-${FULLSEND_FORGE:-}}"
: "${FULLSEND_TRACKER:?FULLSEND_TRACKER must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prescript-output.lib.sh
source "${SCRIPT_DIR}/lib/prescript-output.lib.sh"
# shellcheck source=lib/jira-auth.lib.sh
source "${SCRIPT_DIR}/lib/jira-auth.lib.sh"
# shellcheck source=lib/cve-normalize.lib.sh
source "${SCRIPT_DIR}/lib/cve-normalize.lib.sh"
# shellcheck source=lib/cve-fanout.lib.sh
source "${SCRIPT_DIR}/lib/cve-fanout.lib.sh"
# shellcheck source=lib/cve-git.lib.sh
source "${SCRIPT_DIR}/lib/cve-git.lib.sh"
# shellcheck source=lib/cve-vex.lib.sh
source "${SCRIPT_DIR}/lib/cve-vex.lib.sh"

# The harness default is the literal "none" (an empty harness value is not a
# usable default); treat it, and unset, as "no list".
CVE_BRANCHES="${CVE_BRANCHES:-}"; [[ "${CVE_BRANCHES}" == "none" ]] && CVE_BRANCHES=""
CVE_BRANCHES_FOLLOW="${CVE_BRANCHES_FOLLOW:-}"; [[ "${CVE_BRANCHES_FOLLOW}" == "none" ]] && CVE_BRANCHES_FOLLOW=""
CVE_JIRA_SECURITY_LEVELS="${CVE_JIRA_SECURITY_LEVELS:-}"; [[ "${CVE_JIRA_SECURITY_LEVELS}" == "none" ]] && CVE_JIRA_SECURITY_LEVELS=""
# cve_level_allowed NAME "A, B" → 0 when NAME is exactly one of the listed
# level names. Names may contain spaces; the list is comma-separated.
cve_level_allowed() {
  local want="$1" raw="$2" l
  local -a parts
  [[ -n "${raw}" ]] || return 1
  IFS=',' read -r -a parts <<<"${raw}"
  for l in "${parts[@]}"; do
    l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
    [[ -n "${l}" && "${l}" == "${want}" ]] && return 0
  done
  return 1
}
# Fail on a malformed list now, not after a child issue has been created.
cve_branch_list "${CVE_BRANCHES}" >/dev/null
cve_branch_list "${CVE_BRANCHES_FOLLOW}" >/dev/null
VEX_SOURCES=$(cve_vex_sources "${CVE_VEX_SOURCES:-none}") \
  || { echo "::error::cve: CVE_VEX_SOURCES is not valid; see the line above"; exit 1; }

STAGE="${RUNNER_TEMP}/fullsend-cve-stage"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

skip() {
  echo "::warning::cve: skipped — $1"
  prescript_output skipped true
  prescript_output reason "$1"
  rm -rf "${STAGE}"
  exit 0
}

rm -rf "${STAGE}"
mkdir -p "${STAGE}"
ISSUE_JSON="${WORK}/issue.json"
CHECKS=()

# --- 0. How visible is the repository being assessed? ------------------------
# Needed by R1 (a restricted tracker is read only for a private or internal
# repository) and by R4 (whether the ticket's text may be staged).
repo_visibility() {  # repo_visibility OWNER/NAME → public | private | internal | unknown
  local v
  v=$(gh api "repos/$1" --jq '.visibility' 2>/dev/null) || v=""
  case "${v}" in public|private|internal) echo "${v}" ;; *) echo "unknown" ;; esac
}
gitlab_visibility() {  # gitlab_visibility GROUP/PROJECT → public | private | internal | unknown
  # GitLab states the visibility of the project the pipeline runs in. Any
  # other project is unknown, which withholds the ticket text.
  if [[ -n "${CI_PROJECT_PATH:-}" && "${CI_PROJECT_PATH}" == "$1" ]]; then
    case "${CI_PROJECT_VISIBILITY:-}" in public|private|internal) echo "${CI_PROJECT_VISIBILITY}"; return 0 ;; esac
  fi
  echo "unknown"
}
TARGET_VIS="unknown"
case "${FULLSEND_FORGE:-github}" in
  github) TARGET_VIS=$(repo_visibility "${REPO_FULL_NAME}") ;;
  gitlab) TARGET_VIS=$(gitlab_visibility "${REPO_FULL_NAME}") ;;
esac

# --- 1. Fetch the work item with host credentials (never staged) ------------
case "${FULLSEND_TRACKER}" in
  github)
    if [[ ! "${ISSUE_URL}" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/issues/([0-9]+)$ ]]; then
      echo "::error::cve: ISSUE_URL is not a GitHub issue URL"; exit 1
    fi
    GH_REPO_SLUG="${BASH_REMATCH[1]}"
    GH_ISSUE_NUMBER="${BASH_REMATCH[2]}"
    gh api "repos/${GH_REPO_SLUG}/issues/${GH_ISSUE_NUMBER}" > "${ISSUE_JSON}"
    LABELS=$(jq -r '[.labels[].name] | join(" ")' "${ISSUE_JSON}")
    ;;
  jira)
    : "${JIRA_BASE_URL:?}" "${JIRA_TOKEN:?}"
    KEY="${FULLSEND_WORK_ITEM_KEY:-$(basename "${ISSUE_URL}")}"
    if [[ ! "${KEY}" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]; then
      echo "::error::cve: cannot derive a Jira key from the work item"; exit 1
    fi
    # REST calls go to the API gateway fullsend sets for a Jira-sourced run
    # (a service account's token is rejected at the site URL), else the site.
    JIRA_REST="${JIRA_API_URL:-${JIRA_BASE_URL}}"; JIRA_REST="${JIRA_REST%/}"
    [[ "${JIRA_REST}" == https://* ]] || { echo "::error::cve: the Jira API URL must start with https://"; exit 1; }
    jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" -fsS -m 30 \
      "${JIRA_REST}/rest/api/2/issue/${KEY}?fields=summary,labels,security&properties=cve-intake" \
      > "${ISSUE_JSON}"
    # R1. The description is deliberately not requested at all. A security
    # level stops the run unless the adopter has listed that exact level in
    # CVE_JIRA_SECURITY_LEVELS and the repository is private or internal:
    # an employee-only tracker may be read for an employee-only repository,
    # and an embargo level is never on that list.
    SEC_LEVEL=$(jq -r 'if .fields.security then (.fields.security.name // "unnamed") else "" end' "${ISSUE_JSON}")
    if [[ -z "${SEC_LEVEL}" ]]; then
      CHECKS+=("jira-security-level-empty")
    elif ! cve_level_allowed "${SEC_LEVEL}" "${CVE_JIRA_SECURITY_LEVELS}"; then
      skip "Jira issue ${KEY} has a security level that is not in CVE_JIRA_SECURITY_LEVELS (possibly embargoed)"
    elif [[ "${TARGET_VIS}" != "private" && "${TARGET_VIS}" != "internal" ]]; then
      skip "Jira issue ${KEY} has a restricted security level and this repository is ${TARGET_VIS}; a restricted tracker is read only for a private or internal repository"
    else
      CHECKS+=("jira-security-level-allowed")
    fi
    LABELS=$(jq -r '(.fields.labels // []) | join(" ")' "${ISSUE_JSON}")
    ;;
  *) skip "tracker ${FULLSEND_TRACKER} is not supported by the cve agent yet" ;;
esac

# --- 2. R2: embargo-ish labels ------------------------------------------------
# A bash match, not a pipe into `grep -q`: under `pipefail` a writer killed
# by SIGPIPE would turn a match into a miss, and this check must not miss.
if [[ "${LABELS,,}" =~ (embargo|confidential|private) ]]; then
  skip "work item carries an embargo/confidential label"
fi
CHECKS+=("no-embargo-label")

# --- 2b. R4: may the ticket's own text be staged? ----------------------------
case "${FULLSEND_TRACKER}" in
  github) if [[ "${GH_REPO_SLUG}" == "${REPO_FULL_NAME}" ]]; then TRACKER_VIS="${TARGET_VIS}"; else TRACKER_VIS=$(repo_visibility "${GH_REPO_SLUG}"); fi ;;
  *) TRACKER_VIS="private" ;;   # a Jira tracker is never assumed to be public
esac
STAGE_TEXT=""; TEXT_WHY=""
case "${CVE_TICKET_TEXT:-auto}" in
  off) TEXT_WHY="CVE_TICKET_TEXT is off" ;;
  on)
    STAGE_TEXT="yes"
    if [[ "${TARGET_VIS}" != "private" && "${TARGET_VIS}" != "internal" && "${TRACKER_VIS}" != "public" ]]; then
      echo "::warning::cve: UNSAFE — CVE_TICKET_TEXT=on, the repository is ${TARGET_VIS} and the tracker is not public. Ticket text can surface in comments, pull requests and run logs that are, or later become, public."
    fi ;;
  auto)
    if [[ "${TARGET_VIS}" == "private" || "${TARGET_VIS}" == "internal" || "${TRACKER_VIS}" == "public" ]]; then
      STAGE_TEXT="yes"
    elif [[ "${TARGET_VIS}" == "public" ]]; then
      TEXT_WHY="the repository is public and the tracker is not"
    else
      TEXT_WHY="the repository's visibility could not be determined"
    fi ;;
  *) echo "::error::cve: CVE_TICKET_TEXT must be auto, on or off"; exit 1 ;;
esac

if [[ -n "${STAGE_TEXT}" ]]; then
  case "${FULLSEND_TRACKER}" in
    github)
      gh api "repos/${GH_REPO_SLUG}/issues/${GH_ISSUE_NUMBER}/comments?per_page=100" > "${WORK}/comments.json"
      jq -n --slurpfile i "${ISSUE_JSON}" --slurpfile c "${WORK}/comments.json" \
        '{source: "github-issue", title: ($i[0].title // ""), description: ($i[0].body // ""),
          comments: [$c[0][] | {created: (.created_at // ""), body: (.body // "")}]}' > "${WORK}/ticket-raw.json"
      ;;
    jira)
      jira_auth_curl "${JIRA_TOKEN}" "${JIRA_USER_EMAIL:-}" -fsS -m 30 \
        "${JIRA_REST}/rest/api/2/issue/${KEY}?fields=summary,description,comment" > "${WORK}/issue-text.json"
      jq 'def text: if type == "string" then . elif . == null then "" else tojson end;
          {source: "jira", title: (.fields.summary | text), description: (.fields.description | text),
           comments: [(.fields.comment.comments // [])[] | {created: (.created // ""), body: (.body | text)}]}' \
        "${WORK}/issue-text.json" > "${WORK}/ticket-raw.json"
      ;;
  esac
  # Drop this agent's own verdicts, keep the newest 20 comments, cap sizes.
  jq '(.comments | map(select(.body | contains("fullsend-cve") | not))) as $c
      | {schema_version: "0", staged: true, untrusted: true, source: .source,
         title: .title[0:500], description: .description[0:20000],
         comments: [$c[-20:][] | {created: .created[0:40], body: .body[0:4000]}],
         truncated: ((.description | length) > 20000 or ($c | length) > 20 or ([$c[].body | length > 4000] | any))}' \
    "${WORK}/ticket-raw.json" > "${WORK}/cve-ticket.json"
else
  jq -n --arg why "${TEXT_WHY}" '{schema_version: "0", staged: false, reason: $why}' > "${WORK}/cve-ticket.json"
fi

# --- 3. Which branch? ---------------------------------------------------------
set +e
WANT_REF=$(cve_requested_ref --source "${FULLSEND_TRACKER}" --issue-json "${ISSUE_JSON}")
rc=$?
set -e
[[ ${rc} -eq 3 ]] && skip "${WANT_REF}"
[[ ${rc} -ne 0 ]] && { echo "::error::cve: reading the work item failed (${rc})"; exit 1; }

FANOUT=""
REF=$(git -C "${TARGET_REPO_DIR}" rev-parse --abbrev-ref HEAD)
if [[ "${REF}" == "HEAD" ]]; then
  # A CI checkout is often detached. The verdict has to name a branch, or the
  # code agent's gate cannot compare it with that branch later. Use the
  # branch CI says it checked out when it points at this commit, else any
  # branch that does.
  REF=""
  mapfile -t _at < <(git -C "${TARGET_REPO_DIR}" for-each-ref --points-at HEAD \
    --format='%(refname:strip=3)' refs/remotes/origin; git -C "${TARGET_REPO_DIR}" for-each-ref \
    --points-at HEAD --format='%(refname:strip=2)' refs/heads)
  for _want in "${CI_COMMIT_REF_NAME:-}" "${GITHUB_REF_NAME:-}"; do
    for _b in "${_at[@]}"; do
      [[ -z "${REF}" && -n "${_want}" && "${_b}" == "${_want}" ]] && REF="${_b}"
    done
  done
  if [[ -z "${REF}" ]]; then
    for _b in "${_at[@]}"; do
      [[ -n "${_b}" && "${_b}" != "HEAD" ]] && { REF="${_b}"; break; }
    done
  fi
  [[ -n "${REF}" ]] \
    || skip "the checkout is not on a branch, so a verdict could not say which branch it is about"
fi
if [[ -n "${WANT_REF}" ]]; then
  [[ -n "${CVE_BRANCHES}" ]] \
    || skip "work item asks for branch ${WANT_REF} but CVE_BRANCHES is not set for this repository (single-branch mode)"
  cve_branch_in "${WANT_REF}" "${CVE_BRANCHES}" \
    || skip "branch ${WANT_REF} is not in this repository's CVE_BRANCHES list"
  cve_branch_in "${WANT_REF}" "${CVE_BRANCHES_FOLLOW}" \
    && skip "branch ${WANT_REF} follows another branch (CVE_BRANCHES_FOLLOW); it gets no assessment or change of its own"
  # The runner's checkout holds the default branch only. Fetch the branch
  # asked for, with the run's read token if the remote wants one.
  if ! BRANCH_COMMIT=$(cve_git_branch_commit "${TARGET_REPO_DIR}" "${WANT_REF}"); then
    cve_git_fetch_tip "${TARGET_REPO_DIR}" "${WANT_REF}" || true
    BRANCH_COMMIT=$(cve_git_branch_commit "${TARGET_REPO_DIR}" "${WANT_REF}") \
      || { echo "::error::cve: branch ${WANT_REF} is in CVE_BRANCHES but could not be fetched into the checkout"; exit 1; }
  fi
  # The sandbox is created after this script, from this working tree. The
  # working tree also holds the run's own .fullsend directory, and a release
  # branch may lack its config.yaml, so post-cve puts the checkout back
  # before it calls the fullsend CLI.
  git -C "${TARGET_REPO_DIR}" rev-parse HEAD > "${STAGE}/restore-commit"
  git -C "${TARGET_REPO_DIR}" checkout -q --detach "${BRANCH_COMMIT}"
  REF="${WANT_REF}"
elif [[ -n "${CVE_BRANCHES}" ]]; then
  [[ "${FULLSEND_TRACKER}" == "github" ]] \
    || skip "CVE_BRANCHES is set but this tracker names no release branch (cve-intake.release_branch); refusing to guess which stream it is"
  FANOUT="yes"
fi

# --- 4. Normalize (R4: validated fields only) --------------------------------
COMMIT=$(git -C "${TARGET_REPO_DIR}" rev-parse HEAD)
set +e
REASON=$(cve_normalize_finding \
  --source "${FULLSEND_TRACKER}" --issue-json "${ISSUE_JSON}" \
  --repo "${REPO_FULL_NAME}" --ref "${REF}" --commit "${COMMIT}" \
  --public-checks "$(IFS=,; echo "${CHECKS[*]}")" \
  --out "${WORK}/cve-finding.json")
rc=$?
set -e
[[ ${rc} -eq 3 ]] && skip "${REASON}"
[[ ${rc} -ne 0 ]] && { echo "::error::cve: normalizing the work item failed (${rc})"; exit 1; }
VULN_ID="${REASON}"   # validated against the CVE/GHSA pattern by the normalizer

# --- 5. R3: must be published; fetch advisories on the host -----------------
# Egress to advisory hosts happens here, not in the sandbox (fullsend#9112).
osv_get() {  # osv_get ID OUTFILE → prints the HTTP status
  curl -sS -m 30 -o "$2" -w '%{http_code}' "https://api.osv.dev/v1/vulns/$1" || echo 000
}
code=$(osv_get "${VULN_ID}" "${WORK}/osv-0.json")
case "${code}" in
  200) ;;
  404) skip "${VULN_ID} is not published in OSV; refusing (embargoed or not yet public)" ;;
  *) echo "::error::cve: OSV lookup for ${VULN_ID} failed (HTTP ${code}); cannot confirm it is public"; exit 1 ;;
esac
# --- 6. A parent fans out instead of running -----------------------------------
# After R1–R3 on purpose: no child issue is ever created for an id that is
# not public. The model does not run for a parent.
if [[ -n "${FANOUT}" ]]; then
  cve_fanout "${GH_REPO_SLUG}" "${GH_ISSUE_NUMBER}" "${WORK}/cve-finding.json" "${VULN_ID}" "${POST_CVE_DRY_RUN:-}" \
    || { echo "::error::cve: fan-out of ${VULN_ID} failed part-way; re-run after checking the parent's sub-issues"; exit 1; }
  skip "${CVE_FANOUT_SUMMARY}"
fi

n=0
for alias in $(jq -r '.aliases[]? // empty' "${WORK}/osv-0.json" | head -5); do
  [[ "${alias}" =~ ^[A-Z][A-Za-z0-9]+-[A-Za-z0-9-]+$ ]] || continue
  n=$((n + 1))
  [[ "$(osv_get "${alias}" "${WORK}/osv-${n}.json")" == "200" ]] || rm -f "${WORK}/osv-${n}.json"
done
jq -s '.' "${WORK}"/osv-*.json > "${WORK}/osv-all.json"

# Vendor VEX: one CSAF VEX document per source the adopter listed. A source
# with no document for this id is staged as such, so the model sees the gap.
echo '[]' > "${WORK}/vex-all.json"
WITHHELD='[]'
if [[ "${CVE_VENDOR_VEX:-on}" == "off" ]]; then
  WITHHELD='["vendor_vex"]'
  echo "::notice::cve: vendor VEX withheld (CVE_VENDOR_VEX=off, evaluation mode)"
elif [[ -n "${VEX_SOURCES}" ]]; then
  while IFS=$'\t' read -r vex_name vex_tmpl; do
    [[ -n "${vex_name}" ]] || continue
    rm -f "${WORK}/vex-doc.json"
    if vex_url=$(cve_vex_url "${vex_tmpl}" "${VULN_ID}") \
        && curl -fsS -m 60 --max-filesize 52428800 -o "${WORK}/vex-doc.json" "${vex_url}" \
        && jq -e 'type == "object" and (.vulnerabilities | type == "array")' "${WORK}/vex-doc.json" >/dev/null 2>&1; then
      jq -n --arg s "${vex_name}" --slurpfile d "${WORK}/vex-doc.json" '{source: $s, document: $d[0]}' > "${WORK}/vex-entry.json"
    else
      echo "cve: no CSAF VEX document from source '${vex_name}' for ${VULN_ID}"
      jq -n --arg s "${vex_name}" '{source: $s, document: null}' > "${WORK}/vex-entry.json"
    fi
    jq --slurpfile e "${WORK}/vex-entry.json" '. + $e' "${WORK}/vex-all.json" > "${WORK}/vex-all.tmp" \
      && mv "${WORK}/vex-all.tmp" "${WORK}/vex-all.json"
  done <<<"${VEX_SOURCES}"
fi

# --- 7. Stage -------------------------------------------------------------------
jq -n --slurpfile osv "${WORK}/osv-all.json" --slurpfile vex "${WORK}/vex-all.json" --argjson withheld "${WITHHELD}" \
  '{osv: $osv[0], vendor_vex: $vex[0], withheld: $withheld}' > "${STAGE}/cve-evidence.json"
jq '.disclosure.checked_by += ["osv-published"]' "${WORK}/cve-finding.json" > "${STAGE}/cve-finding.json"
cp "${WORK}/cve-ticket.json" "${STAGE}/cve-ticket.json"

echo "::notice::cve: staged ${VULN_ID} for ${REPO_FULL_NAME} ${REF}@${COMMIT:0:12} ($(jq '.osv | length' "${STAGE}/cve-evidence.json") OSV record(s); vendor VEX: $(jq -r 'if (.withheld | index("vendor_vex")) then "withheld" elif (.vendor_vex | length) == 0 then "no source configured" else ([.vendor_vex[] | .source + (if .document then " yes" else " no" end)] | join(", ")) end' "${STAGE}/cve-evidence.json"); ticket text: $(jq -r 'if .staged then "staged" else "not staged — " + .reason end' "${STAGE}/cve-ticket.json"))"
