#!/usr/bin/env bash
# GENERATED from pre-cve.src.sh — DO NOT EDIT. Run: make script-build
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
# shellcheck source=lib/cve-normalize.lib.sh
# BEGIN bundled: lib/cve-normalize.lib.sh
# shellcheck shell=bash
# cve-normalize.lib.sh — DRAFT. Turn one tracker work item into
# cve-finding.json (schemas/cve-finding.schema.json).
#
# The normalizer is Python, carried here in a heredoc so that bundle-sh.sh
# inlines it into pre-cve.sh. A harness composed from a URL `base:` fetches
# its scripts one file at a time, so a separate .py next to the script would
# not travel with it.
#
# Usage: cve_normalize_finding --source github|jira --issue-json F --repo O/N
#          --ref BRANCH --commit SHA --public-checks a,b --out F
# Exit: 0 ok (stdout = vulnerability id); 3 refused (stdout = reason).
#
#        cve_requested_ref --source github|jira --issue-json F
# Exit: 0 (stdout = the branch the work item asks for, or empty); 3 refused.

[[ -n "${CVE_NORMALIZE_SH_LOADED:-}" ]] && return 0
CVE_NORMALIZE_SH_LOADED=1

cve_requested_ref() {
  cve_normalize_finding --print-requested-ref "$@"
}

cve_normalize_finding() {
  python3 -I - "$@" <<'CVE_NORMALIZE_PY'
"""normalize-finding — turn one tracker work item into cve-finding.json (DRAFT).

Runs on the HOST inside pre-cve, never in the sandbox. Input is the work item
pre-cve already fetched (GitHub issue JSON from `gh api`, or Jira issue JSON
from the REST API with `properties` expanded). Output conforms to
schemas/cve-finding.schema.json.

The rule that shapes this file: NO FREE TEXT from the tracker reaches the
model. Fullsend's pre-script guidance is that unfiltered source content must
never be staged where the agent reads it. So this script copies only fields
it can validate against a tight pattern (ids, an ecosystem enum, package
names, version ranges, a repository-relative path) and drops everything
else — titles, descriptions, comments and any unknown key. That is also what
keeps private Jira text out of a run against a public repository.

Accepted shapes, in priority order:
  1. A fenced block in a GitHub issue body:
         ```cve-finding
         {"vulnerability": {"id": "CVE-…"}, "package": {...}}
         ```
     Written by the Dependabot bridge workflow, or by a person filing by hand.
  2. Jira issue property `cve-intake`: cve, repository, component, product,
     release_branch. This is this agent's own shape. The
     cve-workflow-experiment uses a different property, `fullsend.cve.intake`,
     which names a product, release and stream and is resolved to a branch
     through a reviewed mapping file; this agent does not read it yet.
  3. Fallback: exactly one CVE/GHSA id in the title/body (GitHub) or in the
     labels/summary (Jira). Only the id is taken.
     A Jira label that starts with the prefix in CVE_COMPONENT_LABEL_PREFIX
     (for example "component:") names the component; with no prefix set, no
     component is taken from labels.

Exit codes: 0 ok (prints the vulnerability id); 3 = refused (prints the
reason) — pre-cve turns that into a skipped run with a visible reason.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ID = r"(?:CVE-\d{4}-\d{4,}|GHSA(?:-[23456789cfghjmpqrvwx]{4}){3})"
ID_RE = re.compile(rf"\b{ID}\b")
ID_FULL = re.compile(rf"^{ID}$")
BLOCK_RE = re.compile(r"```cve-finding\s*\n(.*?)\n```", re.S)

ECOSYSTEMS = {"npm", "pypi", "go", "maven", "cargo", "rubygems", "nuget", "rpm", "oci", "other"}
SEVERITIES = {"critical", "important", "moderate", "low", "unknown"}
# Every pattern below must match schemas/cve-finding.schema.json.
PATTERNS = {
    "alias": re.compile(r"^[A-Z][A-Za-z0-9]{1,15}-[A-Za-z0-9-]{1,60}$"),
    "name": re.compile(r"^[@A-Za-z0-9][A-Za-z0-9._/@+-]{0,199}$"),
    "purl": re.compile(r"^pkg:[A-Za-z0-9._~%/@?=&+:-]{1,300}$"),
    "range": re.compile(r"^[A-Za-z0-9 .,<>=~^*|!+_-]{1,200}$"),
    "path": re.compile(r"^(?!/)(?!.*\.\.)[A-Za-z0-9._/@+-]{1,300}$"),
    "label": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/ -]{0,119}$"),
    "repo": re.compile(r"^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$"),
    "branch": re.compile(r"^(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$"),
}


def refuse(reason: str) -> None:
    print(reason)
    sys.exit(3)


def ok(kind: str, value) -> bool:
    return isinstance(value, str) and bool(PATTERNS[kind].match(value))


def clean_vulnerability(raw) -> dict:
    raw = raw if isinstance(raw, dict) else {}
    vid = raw.get("id")
    if not isinstance(vid, str) or not ID_FULL.match(vid):
        refuse("vulnerability.id is missing or is not a CVE/GHSA id")
    out = {"id": vid}
    aliases = [a for a in raw.get("aliases") or [] if ok("alias", a) and a != vid]
    if aliases:
        out["aliases"] = sorted(set(aliases))[:20]
    if raw.get("severity") in SEVERITIES:
        out["severity"] = raw["severity"]
    return out


def clean_package(raw) -> dict:
    raw = raw if isinstance(raw, dict) else {}
    out = {}
    if raw.get("ecosystem") in ECOSYSTEMS:
        out["ecosystem"] = raw["ecosystem"]
    for key, kind in (("name", "name"), ("purl", "purl"), ("vulnerable_range", "range"),
                      ("first_patched", "range"), ("manifest_path", "path")):
        if ok(kind, raw.get(key)):
            out[key] = raw[key]
    return out


def requested_ref(raw) -> str:
    """The branch a work item asks to be assessed on, or "".

    This is a request, not the target: pre-cve accepts it only when the
    adopter's branch list contains it, and resolves the commit itself.
    """
    if raw in (None, ""):
        return ""
    if not ok("branch", raw):
        refuse("the work item names a branch that is not a valid branch name")
    return raw


def single_id(text: str, where: str) -> str:
    ids = sorted(set(ID_RE.findall(text)))
    if len(ids) != 1:
        refuse(f"expected exactly one CVE/GHSA id in {where}, found {len(ids)}: {ids[:5]}")
    return ids[0]


def normalize_github(issue: dict) -> dict:
    body = issue.get("body") or ""
    m = BLOCK_RE.search(body)
    if m:
        try:
            block = json.loads(m.group(1))
        except ValueError as exc:
            refuse(f"cve-finding block is not valid JSON: {exc}")
        if not isinstance(block, dict):
            refuse("cve-finding block is not a JSON object")
        data = {"vulnerability": clean_vulnerability(block.get("vulnerability")),
                "package": clean_package(block.get("package"))}
        from_alert = isinstance(block.get("source"), dict) and block["source"].get("kind") == "dependabot-alert"
        kind = "dependabot-alert" if from_alert else "github-issue"
        want = block.get("target")
        data["want_ref"] = requested_ref(want.get("ref") if isinstance(want, dict) else None)
    else:
        data = {"vulnerability": {"id": single_id(f"{issue.get('title', '')}\n{body}", "the issue title/body")},
                "package": {}}
        kind = "github-issue"
    data["source"] = {"kind": kind, "ref": str(issue.get("html_url") or "")[:300]}
    data["target"] = {}
    return data


def normalize_jira(issue: dict, repo: str, ref: str) -> dict:
    fields = issue.get("fields") or {}
    labels = [l for l in fields.get("labels") or [] if isinstance(l, str)]
    intake = (issue.get("properties") or {}).get("cve-intake")
    target = {}
    if isinstance(intake, dict) and intake.get("cve"):
        data = {"vulnerability": clean_vulnerability({"id": intake.get("cve")}),
                "package": clean_package(intake.get("package"))}
        want_repo = intake.get("repository")
        if want_repo and repo and want_repo != repo:
            refuse(f"finding targets {str(want_repo)[:120]!r} but this run checked out {repo!r}")
        want_ref = requested_ref(intake.get("release_branch"))
        for key in ("product", "component"):
            if ok("label", intake.get(key)):
                target[key] = intake[key]
    else:
        vid = single_id(" ".join(labels) + " " + str(fields.get("summary") or ""), "the Jira labels/summary")
        data = {"vulnerability": {"id": vid}, "package": {}}
        # Which label names the component is the tracker owner's convention,
        # so the adopter supplies the prefix; nothing is assumed.
        prefix = os.environ.get("CVE_COMPONENT_LABEL_PREFIX", "")
        if prefix in ("", "none") or not re.match(r"^[A-Za-z0-9_.:-]{1,32}$", prefix):
            prefix = ""
        comp = next((l[len(prefix):] for l in labels if prefix and l.startswith(prefix)), None)
        if ok("label", comp):
            target["component"] = comp
    key = str(issue.get("key") or "")
    data["source"] = {"kind": "jira", "ref": key if re.match(r"^[A-Z][A-Z0-9]{1,20}-\d{1,9}$", key) else ""}
    data["target"] = target
    data["want_ref"] = want_ref if isinstance(intake, dict) and intake.get("cve") else ""
    return data


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--source", choices=["github", "jira"], required=True)
    ap.add_argument("--issue-json", required=True)
    ap.add_argument("--repo", default="", help="owner/name of the repository this run checked out")
    ap.add_argument("--ref", default="", help="branch this run checked out")
    ap.add_argument("--commit", default="", help="40-hex commit this run checked out")
    ap.add_argument("--public-checks", default="", help="comma-separated disclosure checks pre-cve already passed")
    ap.add_argument("--out", default="")
    ap.add_argument("--print-requested-ref", action="store_true",
                    help="print the branch the work item asks for (or nothing) and stop")
    a = ap.parse_args()

    if a.print_requested_ref:
        with open(a.issue_json, encoding="utf-8") as fh:
            issue = json.load(fh)
        data = normalize_jira(issue, a.repo, a.ref) if a.source == "jira" else normalize_github(issue)
        print(data.get("want_ref") or "")
        return 0
    if not a.out:
        refuse("--out is required")
    if not ok("branch", a.ref):
        refuse("--ref is not a valid branch name")
    if not ok("repo", a.repo):
        refuse(f"--repo {a.repo!r} is not owner/name")
    if not re.match(r"^[0-9a-f]{40}$", a.commit):
        refuse("--commit is not a 40-hex commit id")
    with open(a.issue_json, encoding="utf-8") as fh:
        issue = json.load(fh)
    data = normalize_jira(issue, a.repo, a.ref) if a.source == "jira" else normalize_github(issue)

    # The target is always what this run checked out. A work item may ask
    # for a branch, and pre-cve checks that branch out when the adopter's
    # branch list allows it; if the two still differ here, refuse. Assessing
    # one branch and reporting it as a verdict for another is a wrong answer.
    want_ref = data.pop("want_ref", "")
    if want_ref and want_ref != a.ref:
        refuse(f"finding is for branch {want_ref!r} but this run checked out {a.ref!r}")
    data["target"].update({"repository": a.repo, "ref": a.ref, "commit": a.commit})
    if not data["package"]:
        del data["package"]
    checks = [c for c in a.public_checks.split(",") if re.match(r"^[a-z0-9-]{1,40}$", c)]
    if not checks:
        refuse("no public-disclosure check recorded; refusing to stage")
    data["schema_version"] = "0"
    data["disclosure"] = {"public": True, "checked_by": checks}

    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
    print(data["vulnerability"]["id"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
CVE_NORMALIZE_PY
}
# END bundled: lib/cve-normalize.lib.sh
# shellcheck source=lib/cve-fanout.lib.sh
# BEGIN bundled: lib/cve-fanout.lib.sh
# shellcheck shell=bash
# cve-fanout.lib.sh — DRAFT. One vulnerability, several maintained branches.
#
# Fan-out: a parent work item becomes one child issue per maintained branch.
# Each child is an ordinary single-target cve run, then an ordinary code-agent
# run, so nothing here adds a workflow engine. Fan-in: a sticky table on the
# parent, rebuilt from the children's labels every time one of them finishes.
# No state is stored anywhere but the issues: each run reads them and
# finishes what is missing.
#
# Everything here is deterministic host code. The model never chooses the
# branches and never sees the parent or its siblings.
#
# Adopter configuration (runner env, exact branch names, comma-separated):
#   CVE_BRANCHES         maintained branches. Empty = single-branch mode.
#   CVE_BRANCHES_FOLLOW  branches that are still synced from another branch
#                        and must not receive a change of their own. They get
#                        no child issue; the table lists them as following.
#
# GitHub only. A Jira tracker is already one-per-stream; it names its branch
# in the `cve-intake` property and is never fanned out here.

[[ -n "${CVE_FANOUT_SH_LOADED:-}" ]] && return 0
CVE_FANOUT_SH_LOADED=1

CVE_BRANCH_RE='^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$'

# cve_branch_list "a, b,c" → one branch per line. An invalid name is an error:
# a typo in configuration must not silently drop a release branch.
cve_branch_list() {
  local raw="$1" b
  local -a parts
  IFS=',' read -r -a parts <<<"${raw}"
  for b in "${parts[@]}"; do
    b="${b#"${b%%[![:space:]]*}"}"
    b="${b%"${b##*[![:space:]]}"}"
    [[ -z "${b}" ]] && continue
    if [[ ! "${b}" =~ ${CVE_BRANCH_RE} || "${b}" == *..* ]]; then
      echo "::error::cve: invalid branch name in the configured branch list" >&2
      return 1
    fi
    printf '%s\n' "${b}"
  done
}

# cve_branch_in NAME "a,b" → 0 when NAME is in the list.
cve_branch_in() {
  [[ -n "${2:-}" ]] || return 1
  # No pipe into `grep -q`: it exits on the first match, the writer then dies
  # of SIGPIPE, and under `pipefail` a match is reported as a miss.
  local list b
  list=$(cve_branch_list "$2") || return 1
  while IFS= read -r b; do
    [[ "${b}" == "$1" ]] && return 0
  done <<<"${list}"
  return 1
}

# cve_fanout REPO PARENT_NUMBER FINDING_JSON VULN_ID [DRY]
# Brings the parent's branch issues to the wanted state: one issue per branch
# in CVE_BRANCHES that is not in CVE_BRANCHES_FOLLOW, linked under the parent
# and carrying the `cve` label. The label is added last, in its own call, so
# it arrives as a label event. Sets CVE_FANOUT_SUMMARY.
#
# It keeps no record of its own. Every run reads what exists and finishes
# whatever is missing, so a run that died part-way is completed by the next:
#   - linked child, matched by its host-written title      → nothing to create
#   - created but never linked (found by the `cve-branch`
#     label that is set in the create call itself)         → link it
#   - linked or adopted but never given the `cve` label     → add the label
# Both lookups are list calls, never search, whose results lag. An unlinked
# issue is adopted, and a missing label repaired, only when a bot wrote the
# issue: a person cannot plant a branch issue for the agent to pick up.
cve_fanout() {
  local repo="$1" parent="$2" finding="$3" id="$4" dry="${5:-}"
  local linked orphans b title hit block body child cid cnum
  local created=0 followed=0 present=0 repaired=0
  local pick='{id, number, state, bot: ((.user.type // "") == "Bot"), labelled: any((.labels // [])[]; .name | test("^cve(:|$)"))}'

  linked=$(gh api "repos/${repo}/issues/${parent}/sub_issues?per_page=100") || return 1
  orphans=$(gh api "repos/${repo}/issues?labels=cve-branch&state=all&per_page=100") || return 1

  while IFS= read -r b; do
    [[ -z "${b}" ]] && continue
    if cve_branch_in "${b}" "${CVE_BRANCHES_FOLLOW:-}"; then
      followed=$((followed + 1))
      continue
    fi
    title="${id}: ${b}"

    hit=$(jq -c --arg t "${title}" "[.[] | select(.title == \$t)] | first // empty | ${pick}" <<<"${linked}")
    if [[ -n "${hit}" ]]; then
      present=$((present + 1))
      if [[ "$(jq -r '.bot and (.labelled | not) and .state == "open"' <<<"${hit}")" == "true" ]]; then
        cnum=$(jq -r '.number' <<<"${hit}")
        if [[ -n "${dry}" ]]; then
          echo "cve (dry run): would label unfinished branch issue #${cnum} '${title}'"
        else
          gh api "repos/${repo}/issues/${cnum}/labels" -f "labels[]=cve" --silent || return 1
        fi
        repaired=$((repaired + 1))
      fi
      continue
    fi

    hit=$(jq -c --arg t "${title}" \
      "[.[] | select(.title == \$t and (.pull_request | not) and (.user.type // \"\") == \"Bot\")] | first // empty | ${pick}" <<<"${orphans}")
    if [[ -n "${hit}" ]]; then
      cid=$(jq -r '.id' <<<"${hit}"); cnum=$(jq -r '.number' <<<"${hit}")
      if [[ -n "${dry}" ]]; then
        echo "cve (dry run): would link unfinished branch issue #${cnum} '${title}' under #${parent}"
      else
        gh api "repos/${repo}/issues/${parent}/sub_issues" -F "sub_issue_id=${cid}" --silent || return 1
        gh api "repos/${repo}/issues/${cnum}/labels" -f "labels[]=cve" --silent || return 1
      fi
      repaired=$((repaired + 1))
      continue
    fi

    # Built from the validated finding only: no parent title, body or comment.
    block=$(jq -c --arg ref "${b}" \
      '{vulnerability: .vulnerability, package: (.package // {}), source: {kind: .source.kind}, target: {ref: $ref}}' \
      "${finding}")
    body=$(printf 'Branch issue for %s on `%s`. Tracked by #%s.\n\n```cve-finding\n%s\n```\n' \
      "${id}" "${b}" "${parent}" "${block}")
    if [[ -n "${dry}" ]]; then
      echo "cve (dry run): would create branch issue '${title}' under #${parent}"
      created=$((created + 1))
      continue
    fi
    child=$(gh api "repos/${repo}/issues" -f "title=${title}" -f "body=${body}" -f "labels[]=cve-branch") || return 1
    cid=$(jq -r '.id' <<<"${child}")
    cnum=$(jq -r '.number' <<<"${child}")
    [[ "${cid}" =~ ^[0-9]+$ && "${cnum}" =~ ^[0-9]+$ ]] || { echo "::error::cve: issue create returned no id" >&2; return 1; }
    gh api "repos/${repo}/issues/${parent}/sub_issues" -F "sub_issue_id=${cid}" --silent || return 1
    gh api "repos/${repo}/issues/${cnum}/labels" -f "labels[]=cve" --silent || return 1
    created=$((created + 1))
  done < <(cve_branch_list "${CVE_BRANCHES:-}")

  if [[ ${created} -eq 0 && ${repaired} -eq 0 ]]; then
    CVE_FANOUT_SUMMARY="${id} is already fanned out (${present} branch issue(s)); nothing to do on the parent"
  elif [[ ${created} -eq 0 ]]; then
    CVE_FANOUT_SUMMARY="${id} fan-out completed: ${repaired} unfinished branch issue(s) repaired"
  else
    CVE_FANOUT_SUMMARY="${id} fanned out to ${created} branch issue(s)"
    [[ ${present} -gt 0 ]] && CVE_FANOUT_SUMMARY+=" (${present} already existed)"
    [[ ${repaired} -gt 0 ]] && CVE_FANOUT_SUMMARY+=" (${repaired} unfinished repaired)"
  fi
  [[ ${followed} -gt 0 ]] && CVE_FANOUT_SUMMARY+="; ${followed} branch(es) follow another branch and get no issue"
  return 0
}

# cve_rollup_body REPO PARENT_NUMBER VULN_ID → markdown table on stdout.
# Returns 1 when the parent has no branch issues for this id.
# A child's branch is read back from its host-written title and re-checked
# against the branch pattern; any other title is ignored.
cve_rollup_body() {
  local repo="$1" parent="$2" id="$3" subs rows b
  subs=$(gh api "repos/${repo}/issues/${parent}/sub_issues?per_page=100") || return 1
  rows=$(jq -r --arg id "${id}" '
    .[]
    | select((.title // "") | test("^" + $id + ": [A-Za-z0-9][A-Za-z0-9._/-]{0,99}$"))
    | (.title | sub("^[^ ]+ "; "")) as $branch
    | ([(.labels // [])[].name | select(startswith("cve:")) | sub("^cve:"; "")] | first // "pending") as $verdict
    | "| `\($branch)` | #\(.number) | \($verdict) | \(.state) |"' <<<"${subs}") || return 1
  [[ -n "${rows}" ]] || return 1
  printf '### %s across maintained branches\n\n' "${id}"
  printf '| Branch | Issue | Verdict | Issue state |\n|---|---|---|---|\n%s\n' "${rows}"
  while IFS= read -r b; do
    [[ -z "${b}" ]] && continue
    printf '| `%s` | n/a | follows another branch | no separate change |\n' "${b}"
  done < <(cve_branch_list "${CVE_BRANCHES_FOLLOW:-}")
  printf '\n<sub>Rebuilt from the branch issues each time one is assessed. A fix on one branch says nothing about another.</sub>\n'
}

# cve_parent_of REPO ISSUE_NUMBER → parent issue number, or nothing.
cve_parent_of() {
  local n
  n=$(gh api "repos/$1/issues/$2/parent" --jq '.number' 2>/dev/null) || return 0
  [[ "${n}" =~ ^[0-9]+$ ]] && printf '%s' "${n}"
  return 0
}
# END bundled: lib/cve-fanout.lib.sh
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
# shellcheck source=lib/cve-vex.lib.sh
# BEGIN bundled: lib/cve-vex.lib.sh
# cve-vex.lib.sh — DRAFT. Vendor VEX sources for the cve agent.
#
# A vendor VEX source is anyone who publishes one CSAF VEX document per CVE
# at a predictable URL. The agent knows the CSAF format and no vendor: the
# adopter lists its sources in the harness, as
#
#   CVE_VEX_SOURCES: "name=https://host/path/{year}/{id}.json other=https://…/{ID}.json"
#
# Entries are separated by spaces, commas or newlines. "none" (the default)
# means no vendor VEX is fetched. In a URL:
#   {id}    the CVE id in lower case   (cve-2025-27516)
#   {ID}    the CVE id as written      (CVE-2025-27516)
#   {year}  the year in the id         (2025)
# The name labels the source in the evidence the model reads.
#
# The list is harness configuration, so it is trusted the way a script path
# is. It is still checked: https only, no query string or credentials, and
# no placeholder but the three above, because the fetch runs on the host.

CVE_VEX_MAX_SOURCES=5

# cve_vex_sources SPEC → one "name<TAB>template" line per source.
# Exits 1 with a message on stderr when SPEC is malformed.
cve_vex_sources() {
  local spec="${1:-none}" entry name url rest seen=" " n=0
  local -a entries
  spec="$(tr ',\n\t' '   ' <<<"${spec}")"
  read -r -a entries <<<"${spec}"
  if [[ ${#entries[@]} -eq 0 || ( ${#entries[@]} -eq 1 && "${entries[0]}" == "none" ) ]]; then
    return 0
  fi
  for entry in "${entries[@]}"; do
    name="${entry%%=*}"; url="${entry#*=}"
    if [[ "${entry}" != *=* || ! "${name}" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
      echo "CVE_VEX_SOURCES: '${entry}' is not name=url (a name is lower-case letters, digits and hyphens)" >&2; return 1
    fi
    if [[ ! "${url}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/%{}-]*$ ]]; then
      echo "CVE_VEX_SOURCES: the URL for '${name}' must be https, with no query string, fragment or credentials" >&2; return 1
    fi
    if [[ "${url}" != *"{id}"* && "${url}" != *"{ID}"* ]]; then
      echo "CVE_VEX_SOURCES: the URL for '${name}' has no {id} or {ID} placeholder" >&2; return 1
    fi
    rest="${url//\{id\}/}"; rest="${rest//\{ID\}/}"; rest="${rest//\{year\}/}"
    if [[ "${rest}" == *[{}]* ]]; then
      echo "CVE_VEX_SOURCES: the URL for '${name}' has a placeholder other than {id}, {ID} and {year}" >&2; return 1
    fi
    if [[ "${seen}" == *" ${name} "* ]]; then
      echo "CVE_VEX_SOURCES: the name '${name}' is used twice" >&2; return 1
    fi
    seen+="${name} "; n=$((n + 1))
    if (( n > CVE_VEX_MAX_SOURCES )); then
      echo "CVE_VEX_SOURCES: more than ${CVE_VEX_MAX_SOURCES} sources" >&2; return 1
    fi
    printf '%s\t%s\n' "${name}" "${url}"
  done
}

# cve_vex_url TEMPLATE CVE-ID → the document URL, or exit 1 when the id is
# not a CVE id (vendor VEX is filed by CVE).
cve_vex_url() {
  local url="$1" id="$2" lc
  [[ "${id}" =~ ^CVE-([0-9]{4})-[0-9]{4,}$ ]] || return 1
  lc="$(tr '[:upper:]' '[:lower:]' <<<"${id}")"
  url="${url//\{year\}/${BASH_REMATCH[1]}}"
  url="${url//\{id\}/${lc}}"
  url="${url//\{ID\}/${id}}"
  printf '%s\n' "${url}"
}
# END bundled: lib/cve-vex.lib.sh

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
