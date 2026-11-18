#!/usr/bin/env python3
"""Open CVE work items from a repository's Dependabot alerts. DRAFT.

Host-side steps, with no model in any of them:

  collect      read the open alerts of the policy's GitHub repository, check
               each one against every maintained version in the release
               mapping, and write the candidates to a file
  investigate  optional: ask an evidence tool about each candidate and record
               its answer in the file
  publish      create one Jira work item per candidate, with the labels and
               the fullsend.cve.intake record the cve agent's gates require

The file between the steps is where an evidence tool sits. investigate runs a
command the operator chose, once per candidate. publish checks every entry
against the policy again, so that file can take work away but cannot add a
target the policy does not map, and it keeps only the expected fields of what
a tool answered.

A work item opened here starts nothing by itself: the Jira poller drops events
from automation accounts. A person asks for the assessment, and the cve agent
gives the verdict for that branch.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cve_workflow as workflow  # noqa: E402
from cve_workflow import GateError  # noqa: E402

API = "https://api.github.com"
CANDIDATES_VERSION = 1
MAX_ALERT_PAGES = 20
MAX_MANIFEST_BYTES = 1024 * 1024
CVE_PATTERN = r"CVE-[0-9]{4}-[0-9]{4,}"
GHSA_PATTERN = r"GHSA-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}"
LABEL_PATTERN = r"[A-Za-z0-9._:+-]{1,128}"
EVIDENCE_REQUEST_VERSION = 1
EVIDENCE_OUTCOMES = ("in_vulnerable_range", "outside_vulnerable_range", "not_found", "undetermined")
EVIDENCE_COVERAGE = ("complete", "partial", "unknown")
EVIDENCE_TIMEOUT_SECONDS = 180
SENTENCE_PATTERN = r"[A-Za-z0-9 .,;:()'/_<>=+-]{1,200}"
DEFAULT_SETTINGS = {
    "issue_type": "Task",
    "labels": [],
    "assignee_account_id": "",
    "max_new_work_items": 5,
}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise GateError("GitHub redirect refused")


def alert_settings(policy):
    """The optional `alerts` block of the CVE policy, with its defaults."""
    block = policy.get("alerts", {})
    if not isinstance(block, dict) or set(block) - set(DEFAULT_SETTINGS):
        raise GateError("invalid alerts block in CVE policy")
    settings = {**DEFAULT_SETTINGS, **block}
    limit = settings["max_new_work_items"]
    if (
        not isinstance(settings["issue_type"], str)
        or not re.fullmatch(r"[A-Za-z][A-Za-z0-9 _-]{0,63}", settings["issue_type"])
        or not isinstance(settings["labels"], list)
        or any(
            not isinstance(label, str) or not re.fullmatch(LABEL_PATTERN, label)
            for label in settings["labels"]
        )
        or not isinstance(settings["assignee_account_id"], str)
        or not re.fullmatch(r"[A-Za-z0-9:_-]{0,128}", settings["assignee_account_id"])
        or isinstance(limit, bool)
        or not isinstance(limit, int)
        or not 1 <= limit <= 50
    ):
        raise GateError("invalid alerts block in CVE policy")
    return settings


class GitHub:
    """Read-only GitHub API calls for one repository. The token is never printed."""

    def __init__(self, repository, token):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or not token:
            raise GateError("GitHub repository and credential required")
        self.repository = repository
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect)

    def get(self, url):
        if not url.startswith(API + "/"):
            raise GateError("GitHub request outside the API host refused")
        request = urllib.request.Request(
            url,
            headers={
                "Authorization": "Bearer " + self.token,
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "fullsend-cve",
            },
        )
        try:
            with self.opener.open(request, timeout=45) as response:
                data = response.read(8 * 1024 * 1024 + 1)
                if len(data) > 8 * 1024 * 1024:
                    raise GateError("GitHub response too large")
                return json.loads(data), response.headers.get("Link", "")
        except urllib.error.HTTPError as error:
            # Never include response bodies, headers or credentials in logs.
            error.close()
            raise GateError(f"GitHub request failed (HTTP {error.code})") from None
        except urllib.error.URLError:
            raise GateError("GitHub unavailable") from None

    def alerts(self):
        url = f"{API}/repos/{self.repository}/dependabot/alerts?state=open&per_page=100"
        result = []
        for _ in range(MAX_ALERT_PAGES):
            page, link = self.get(url)
            if not isinstance(page, list):
                raise GateError("unexpected Dependabot alert listing")
            result.extend(page)
            following = re.search(r'<([^<>]+)>;\s*rel="next"', link)
            if not following:
                return result
            url = following[1]
        raise GateError("too many Dependabot alert pages")

    def branch_commit(self, branch):
        data, _ = self.get(
            f"{API}/repos/{self.repository}/branches/{urllib.parse.quote(branch, safe='')}"
        )
        sha = data.get("commit", {}).get("sha", "") if isinstance(data, dict) else ""
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise GateError("mapped branch has no readable head commit")
        return sha

    def file_at(self, path, sha):
        data, _ = self.get(
            f"{API}/repos/{self.repository}/contents/{urllib.parse.quote(path)}?ref={sha}"
        )
        if (
            not isinstance(data, dict)
            or data.get("type") != "file"
            or data.get("encoding") != "base64"
            or not isinstance(data.get("content"), str)
            or not data["content"]
        ):
            return None
        raw = base64.b64decode(data["content"])
        if len(raw) > MAX_MANIFEST_BYTES:
            raise GateError("manifest exceeds 1 MiB")
        return raw.decode("utf-8")

    def public_advisory(self, ghsa):
        """The advisory as the public advisory database serves it."""
        data, _ = self.get(f"{API}/advisories/{ghsa}")
        return data if isinstance(data, dict) else {}


def version_key(text):
    """Order a semantic version, with or without Go's leading v and +incompatible."""
    match = re.fullmatch(
        r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
        r"(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?",
        text if isinstance(text, str) else "",
    )
    if not match:
        return None
    if match[4] is None:
        prerelease = (1,)
    else:
        prerelease = (0,) + tuple(
            (0, int(part), "") if part.isdigit() else (1, 0, part)
            for part in match[4].split(".")
        )
    return (int(match[1]), int(match[2]), int(match[3]), prerelease)


def in_range(version, vulnerable_range):
    """True or False when the range can be evaluated, None when it cannot."""
    current = version_key(version)
    if current is None or not isinstance(vulnerable_range, str):
        return None
    clauses = [clause.strip() for clause in vulnerable_range.split(",")]
    if not clauses or any(not clause for clause in clauses):
        return None
    for clause in clauses:
        match = re.fullmatch(r"(<=|>=|<|>|=)\s*(\S+)", clause)
        bound = version_key(match[2]) if match else None
        if bound is None:
            return None
        if not {
            "<": current < bound,
            "<=": current <= bound,
            ">": current > bound,
            ">=": current >= bound,
            "=": current == bound,
        }[match[1]]:
            return False
    return True


def go_modules(text):
    """The require and replace directives of a go.mod file."""
    requires, replaces = {}, {}
    block = None
    for raw in text.splitlines():
        line = raw.split("//", 1)[0].strip()
        if not line:
            continue
        if block is not None:
            if line == ")":
                block = None
                continue
            directive, rest = block, line
        else:
            directive, _, rest = line.partition(" ")
            rest = rest.strip()
            if rest == "(":
                block = directive
                continue
        fields = [field.strip('"') for field in rest.split()]
        if directive == "require" and len(fields) == 2:
            requires[fields[0]] = {
                "version": fields[1],
                "indirect": bool(re.search(r"//\s*indirect\b", raw)),
            }
        elif directive == "replace" and "=>" in fields:
            arrow = fields.index("=>")
            old, new = fields[:arrow], fields[arrow + 1 :]
            if old and new:
                replaces.setdefault(old[0], []).append(
                    {
                        "only_version": old[1] if len(old) > 1 else None,
                        "path": new[0],
                        "version": new[1] if len(new) > 1 else None,
                    }
                )
    return requires, replaces


def observe_go(text, package):
    """What a go.mod file requires for the module that provides a package."""
    requires, replaces = go_modules(text)
    module = package
    while module not in requires:
        if "/" not in module:
            return None
        module = module.rsplit("/", 1)[0]
    entry = requires[module]
    observed = {
        "module": module,
        "version": entry["version"],
        "indirect": entry["indirect"],
        "replaced": False,
    }
    for replacement in replaces.get(module, []):
        if replacement["only_version"] in (None, entry["version"]):
            if replacement["path"] == module and replacement["version"]:
                observed["version"] = replacement["version"]
            else:
                # Another module or a local directory stands in: the version
                # in use cannot be read from this file.
                observed["replaced"] = True
    return observed


# Dependabot ecosystem name -> (manifest formats in the release mapping, reader).
COLLECTORS = {"go": ({"go-module"}, observe_go)}


def text_field(value, pattern, limit=256):
    return (
        value
        if isinstance(value, str) and len(value) <= limit and re.fullmatch(pattern, value)
        else ""
    )


def normalize_alert(raw):
    """Keep only the public facts of one Dependabot alert, each one checked."""
    raw = raw if isinstance(raw, dict) else {}
    dependency = raw.get("dependency") or {}
    package = dependency.get("package") or {}
    advisory = raw.get("security_advisory") or {}
    vulnerability = raw.get("security_vulnerability") or {}
    patched = vulnerability.get("first_patched_version") or {}
    number = raw.get("number")
    return {
        "number": number if isinstance(number, int) and not isinstance(number, bool) else 0,
        "ecosystem": text_field(package.get("ecosystem"), r"[a-z0-9_-]{1,32}"),
        "package": text_field(package.get("name"), workflow.IDENTITY_PATTERN),
        "manifest": text_field(dependency.get("manifest_path"), r"[A-Za-z0-9._/+-]{1,512}", 512),
        "scope": text_field(dependency.get("scope"), r"[a-z]{1,32}"),
        "cve": text_field(advisory.get("cve_id"), CVE_PATTERN),
        "ghsa": text_field(advisory.get("ghsa_id"), GHSA_PATTERN),
        "severity": text_field(advisory.get("severity"), r"[a-z]{1,16}"),
        "withdrawn": advisory.get("withdrawn_at") is not None,
        "vulnerable_range": text_field(
            vulnerability.get("vulnerable_version_range"), r"[0-9A-Za-z.<>=, +-]{1,256}"
        ),
        "first_patched": text_field(patched.get("identifier"), r"[0-9A-Za-z.+-]{1,128}"),
    }


def candidate_key(candidate):
    """One work item per vulnerability and maintained version, whatever the package."""
    return hashlib.sha256(
        "|".join(
            candidate[field]
            for field in ("repository", "product", "release", "stream", "component", "cve")
        ).encode()
    ).hexdigest()[:16]


def intake_for(candidate, policy):
    """The fullsend.cve.intake record, built from the policy and public facts."""
    return {
        "cve": candidate["cve"],
        "disclosure": "public",
        "advisory_url": "https://github.com/advisories/" + candidate["ghsa"],
        "repository": policy["repository"],
        "owner": candidate["owner"],
        "fix_category": policy["fix_category"],
        "product": candidate["product"],
        "release": candidate["release"],
        "stream": candidate["stream"],
        "component": candidate["component"],
    }


def collect(policy, github, only=None):
    """Check every open alert against every maintained version it can concern.

    only, when given, is the set of alert numbers to look at; every other
    alert is left alone and counted, so a run can be kept to one alert.
    """
    repository = policy["repository"]
    targets = workflow.repository_targets(policy.get("release_mappings", []), repository)
    if not targets:
        raise GateError("release mapping has no target for the policy's repository")
    alerts = [normalize_alert(raw) for raw in github.alerts()]
    alerts_read = len(alerts)
    if only is not None:
        alerts = [alert for alert in alerts if alert["number"] in only]
    commits, manifests, advisories = {}, {}, {}
    candidates, skipped = [], []

    def skip(alert, reason, target=None):
        entry = {"alert": alert["number"], "cve": alert["cve"], "package": alert["package"], "reason": reason}
        if target:
            entry["release"] = target["release"]
        skipped.append(entry)

    for alert in sorted(alerts, key=lambda item: item["number"]):
        if not alert["number"] or not alert["package"] or not alert["manifest"] or not alert["ghsa"]:
            skip(alert, "alert fields are missing or malformed")
            continue
        if alert["withdrawn"]:
            skip(alert, "advisory withdrawn")
            continue
        if not alert["cve"]:
            skip(alert, "advisory has no CVE identifier")
            continue
        formats, reader = COLLECTORS.get(alert["ecosystem"], (set(), None))
        if reader is None:
            skip(alert, "no evidence reader for ecosystem " + (alert["ecosystem"] or "unknown"))
            continue
        mapped = [
            target
            for target in targets
            if target["manifest"] == alert["manifest"] and target["manifest_format"] in formats
        ]
        if not mapped:
            skip(alert, "manifest " + alert["manifest"] + " is not in the release mapping")
            continue
        for target in mapped:
            branch = target["branch"]
            if branch not in commits:
                commits[branch] = github.branch_commit(branch)
            commit = commits[branch]
            if (commit, target["manifest"]) not in manifests:
                manifests[(commit, target["manifest"])] = github.file_at(target["manifest"], commit)
            text = manifests[(commit, target["manifest"])]
            if text is None:
                skip(alert, "manifest not found on the mapped branch", target)
                continue
            observed = reader(text, alert["package"])
            if observed is None:
                skip(alert, "package not required on the mapped branch", target)
                continue
            vulnerable = None if observed["replaced"] else in_range(observed["version"], alert["vulnerable_range"])
            if vulnerable is False:
                skip(alert, "required version " + observed["version"] + " is outside the vulnerable range", target)
                continue
            # The advisory database is public; a finding it does not serve, or
            # serves under another CVE, is not shown to be public.
            if alert["ghsa"] not in advisories:
                try:
                    advisories[alert["ghsa"]] = github.public_advisory(alert["ghsa"])
                except GateError:
                    advisories[alert["ghsa"]] = {}
            advisory = advisories[alert["ghsa"]]
            if (
                advisory.get("ghsa_id") != alert["ghsa"]
                or advisory.get("cve_id") != alert["cve"]
                or advisory.get("withdrawn_at") is not None
            ):
                skip(alert, "public advisory could not be confirmed", target)
                continue
            candidate = {
                "alert": alert["number"],
                "cve": alert["cve"],
                "ghsa": alert["ghsa"],
                "package": alert["package"],
                "ecosystem": alert["ecosystem"],
                "severity": alert["severity"],
                "scope": alert["scope"],
                "vulnerable_range": alert["vulnerable_range"],
                "first_patched": alert["first_patched"],
                "repository": repository,
                "product": target["product"],
                "release": target["release"],
                "stream": target.get("stream", target["release"]),
                "component": target["component"],
                "owner": target.get("owner", policy["owners"][0]),
                "branch": branch,
                "commit": commit,
                "manifest": target["manifest"],
                "observed": observed,
                # "undetermined" still opens a work item: a version that
                # cannot be compared is never taken as not affected.
                "outcome": "in_vulnerable_range" if vulnerable else "undetermined",
            }
            candidate["key"] = candidate_key(candidate)
            candidates.append(candidate)
    return {
        "schema_version": CANDIDATES_VERSION,
        "repository": repository,
        "alerts_read": alerts_read,
        "alerts_selected": len(alerts),
        "candidates": candidates,
        "skipped": skipped,
    }


def checked_candidate(entry, policy):
    """Rebuild one candidate from the file under the policy; None if it does not fit."""
    fields = ("cve", "ghsa", "package", "product", "release", "stream", "component", "owner", "repository")
    if not isinstance(entry, dict) or any(not isinstance(entry.get(field), str) for field in fields):
        return None
    if (
        entry["repository"] != policy["repository"]
        or entry["owner"] not in policy["owners"]
        or not re.fullmatch(CVE_PATTERN, entry["cve"])
        or not re.fullmatch(GHSA_PATTERN, entry["ghsa"])
        or any(
            not re.fullmatch(workflow.IDENTITY_PATTERN, entry[field])
            for field in ("package", "product", "release", "stream", "component")
        )
    ):
        return None
    candidate = {field: entry[field] for field in fields}
    intake = intake_for(candidate, policy)
    try:
        target = workflow.resolve_target(intake, policy)
    except GateError:
        return None
    if target["component"] != candidate["component"]:
        return None
    for field, pattern in (
        ("branch", r"[A-Za-z0-9._/+-]{1,256}"),
        ("commit", r"[0-9a-f]{40}"),
        ("manifest", r"[A-Za-z0-9._/+-]{1,512}"),
        ("vulnerable_range", r"[0-9A-Za-z.<>=, +-]{0,256}"),
        ("first_patched", r"[0-9A-Za-z.+-]{0,128}"),
        ("severity", r"[a-z]{0,16}"),
        ("outcome", r"in_vulnerable_range|undetermined"),
    ):
        value = entry.get(field, "")
        candidate[field] = value if isinstance(value, str) and re.fullmatch(pattern, value) else ""
    observed = entry.get("observed") if isinstance(entry.get("observed"), dict) else {}
    candidate["observed_version"] = text_field(observed.get("version"), r"[0-9A-Za-z.+-]{1,128}")
    candidate["observed_module"] = text_field(observed.get("module"), workflow.IDENTITY_PATTERN)
    candidate["ecosystem"] = text_field(entry.get("ecosystem"), r"[a-z]{1,32}")
    number = entry.get("alert")
    candidate["alert"] = number if isinstance(number, int) and not isinstance(number, bool) and number > 0 else 0
    candidate["evidence"] = checked_evidence(entry.get("evidence"))
    if candidate["branch"] != target["branch"]:
        return None
    candidate["key"] = candidate_key(candidate)
    candidate["intake"] = intake
    return candidate


def checked_evidence(value):
    """The expected, bounded fields of an evidence tool's answer; None if it is not one."""
    if not isinstance(value, dict) or value.get("outcome") not in EVIDENCE_OUTCOMES:
        return None
    observed = value.get("observed") if isinstance(value.get("observed"), dict) else {}
    gaps = value.get("gaps") if isinstance(value.get("gaps"), list) else []
    return {
        "tool": text_field(value.get("tool"), r"[A-Za-z0-9 ._()+-]{1,64}"),
        "outcome": value["outcome"],
        "coverage": value["coverage"] if value.get("coverage") in EVIDENCE_COVERAGE else "unknown",
        "gaps": [gap for gap in gaps if text_field(gap, SENTENCE_PATTERN)][:8],
        "observed": {
            "module": text_field(observed.get("module"), workflow.IDENTITY_PATTERN),
            "version": text_field(observed.get("version"), r"[0-9A-Za-z.+-]{1,128}"),
            "direct": observed.get("direct") if isinstance(observed.get("direct"), bool) else None,
        },
        "evidence_sha256": text_field(value.get("evidence_sha256"), r"[0-9a-f]{64}"),
    }


def cleared_by_evidence(candidate):
    """Complete evidence that the version in use is outside the vulnerable range.

    Nothing else clears a candidate: a tool that did not find the package, or
    whose evidence has gaps, has not shown that the branch is unaffected.
    """
    evidence = candidate["evidence"]
    return bool(evidence) and evidence["outcome"] == "outside_vulnerable_range" and evidence["coverage"] == "complete"


def investigate(policy, document, tool, workdir, run=subprocess.run):
    """Ask the evidence tool about each candidate and record its answer in the document.

    The tool is run as `TOOL REQUEST RESULT`: it reads the request file and
    writes its answer to the result path. A candidate the tool fails on, or
    answers in another shape, carries no evidence and is published as it would
    be without the tool.
    """
    candidates_document(policy, document)
    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    report = {"asked": 0, "answered": 0, "failed": 0}
    for index, entry in enumerate(document["candidates"]):
        candidate = checked_candidate(entry, policy)
        if candidate is None:
            continue
        entry.pop("evidence", None)
        request_path, result_path = workdir / f"request-{index}.json", workdir / f"result-{index}.json"
        request_path.write_text(
            json.dumps(
                {
                    "schema_version": EVIDENCE_REQUEST_VERSION,
                    "repository": candidate["repository"],
                    "branch": candidate["branch"],
                    "commit": candidate["commit"],
                    "manifest": candidate["manifest"],
                    "ecosystem": candidate["ecosystem"],
                    "package": candidate["package"],
                    "module": candidate["observed_module"] or candidate["package"],
                    "cve": candidate["cve"],
                    "ghsa": candidate["ghsa"],
                    "alert_number": candidate["alert"],
                    "vulnerable_range": candidate["vulnerable_range"],
                    "first_patched_version": candidate["first_patched"] or None,
                }
            )
            + "\n"
        )
        result_path.unlink(missing_ok=True)
        report["asked"] += 1
        evidence = None
        try:
            completed = run(
                [*tool, str(request_path), str(result_path)],
                stdin=subprocess.DEVNULL,
                timeout=EVIDENCE_TIMEOUT_SECONDS,
                check=False,
            )
            if completed.returncode == 0 and result_path.is_file() and result_path.stat().st_size <= 65536:
                evidence = checked_evidence(json.loads(result_path.read_text()))
        except (OSError, ValueError, subprocess.SubprocessError):
            evidence = None
        if evidence is None:
            report["failed"] += 1
            continue
        entry["evidence"] = evidence
        report["answered"] += 1
    return report


def work_item_text(group):
    """Summary and description, from public facts and the host's own reading only.

    group holds the candidates that share one vulnerability and one version:
    an advisory can name several packages.
    """
    first = group[0]
    packages = []
    for candidate in group:
        if candidate["package"] not in packages:
            packages.append(candidate["package"])
    named = packages[0] + (f" and {len(packages) - 1} more" if len(packages) > 1 else "")
    summary = f"{first['cve']}: {named} in {first['product']} {first['release']}"
    lines = [
        "Opened by fullsend from a Dependabot alert. Nothing has been assessed yet.",
        "Advisory: " + first["intake"]["advisory_url"],
        f"Target: {first['product']} {first['release']}, branch {first['branch']}",
    ]
    for candidate in group:
        lines.append(
            "Package: "
            + candidate["package"]
            + (" (" + candidate["severity"] + " severity)" if candidate["severity"] else "")
            + ". Vulnerable versions: "
            + (candidate["vulnerable_range"] or "not stated")
            + ". First patched version: "
            + (candidate["first_patched"] or "not stated")
            + "."
        )
        if candidate["observed_version"] and candidate["commit"]:
            lines.append(
                f"Read by the host: {candidate['manifest']} at {candidate['commit'][:12]} requires "
                f"{candidate['observed_module'] or candidate['package']} {candidate['observed_version']}."
            )
        if candidate["outcome"] == "undetermined":
            lines.append("The version in use could not be compared with the vulnerable range.")
        evidence = candidate["evidence"]
        if evidence:
            observed = evidence["observed"]
            found = {
                "in_vulnerable_range": "the version in use is in the vulnerable range",
                "outside_vulnerable_range": "the version in use is outside the vulnerable range",
                "not_found": "the package was not found",
                "undetermined": "the version in use could not be determined",
            }[evidence["outcome"]]
            line = f"Evidence tool ({evidence['tool'] or 'unnamed'}): {found}"
            if observed["module"] and observed["version"]:
                line += f"; {observed['module']} {observed['version']}"
                if observed["direct"] is not None:
                    line += " is a direct requirement" if observed["direct"] else " is an indirect requirement"
            line += f". Evidence coverage: {evidence['coverage']}."
            if evidence["gaps"]:
                line += " Not shown by the evidence: " + "; ".join(evidence["gaps"]) + "."
            if evidence["evidence_sha256"]:
                line += " Evidence record: sha256 " + evidence["evidence_sha256"][:16] + "."
            lines.append(line)
    lines.append("To assess this branch, comment /fs-cve-triage.")
    return summary[:255], "\n".join(lines)


def existing_work_item(jira, policy, label):
    found = jira.request(
        "POST",
        "/search/jql",
        {"jql": f'project = "{policy["project"]}" AND labels = "{label}"', "maxResults": 1, "fields": ["summary"]},
    )
    issues = found.get("issues", []) if isinstance(found, dict) else []
    return (issues[0].get("key") or "existing") if issues else ""


def candidates_document(policy, document):
    if (
        not isinstance(document, dict)
        or document.get("schema_version") != CANDIDATES_VERSION
        or document.get("repository") != policy["repository"]
        or not isinstance(document.get("candidates"), list)
    ):
        raise GateError("candidates file does not match this policy")


def publish(policy, document, jira, dry_run=False):
    """Create a work item for each candidate that fits the policy and has none yet."""
    settings = alert_settings(policy)
    candidates_document(policy, document)
    report = {"created": [], "existing": [], "refused": 0, "cleared": 0, "over_limit": 0}
    groups = {}
    for entry in document["candidates"]:
        candidate = checked_candidate(entry, policy)
        if candidate is None:
            report["refused"] += 1
            continue
        if cleared_by_evidence(candidate):
            report["cleared"] += 1
            continue
        groups.setdefault(candidate["key"], []).append(candidate)
    for identity, group in groups.items():
        candidate = group[0]
        label = "fullsend-cve-alert-" + identity
        summary, description = work_item_text(group)
        if len(report["created"]) >= settings["max_new_work_items"]:
            # Not looked up: some of these may already have a work item.
            report["over_limit"] += 1
            continue
        key = existing_work_item(jira, policy, label)
        if key:
            report["existing"].append({"key": key, "summary": summary})
            continue
        if dry_run:
            report["created"].append({"key": "(dry run)", "summary": summary})
            continue
        fields = {
            "project": {"key": policy["project"]},
            "issuetype": {"name": settings["issue_type"]},
            "summary": summary,
            "description": {
                "type": "doc",
                "version": 1,
                "content": [workflow.adf_paragraph(description)],
            },
            "labels": sorted({*policy["required_labels"], *settings["labels"], label}),
        }
        if settings["assignee_account_id"]:
            fields["assignee"] = {"accountId": settings["assignee_account_id"]}
        # The intake record is set in the same request, so a work item never
        # exists without it.
        created = jira.request(
            "POST",
            "/issue",
            {
                "fields": fields,
                "properties": [{"key": workflow.INTAKE_PROPERTY, "value": candidate["intake"]}],
            },
        )
        report["created"].append({"key": (created or {}).get("key", ""), "summary": summary})
    return report


def github_from_env(policy):
    """A token that can read the repository's alerts and contents."""
    token = os.environ.get("CVE_ALERTS_GITHUB_TOKEN", "")
    if not token:
        token = workflow.github_app_token(
            policy["repository"], {"vulnerability_alerts": "read", "contents": "read"}
        )
    return GitHub(policy["repository"], token)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["collect", "investigate", "publish"])
    parser.add_argument("--candidates", required=True, help="the candidates file to write or read")
    parser.add_argument(
        "--alert",
        type=int,
        action="append",
        help="collect: look only at this alert number; may be given more than once",
    )
    parser.add_argument("--tool", help="investigate: the evidence tool's command line")
    parser.add_argument("--workdir", help="investigate: where request and result files are written")
    parser.add_argument("--dry-run", action="store_true", help="publish: create nothing")
    args = parser.parse_args()
    path = os.environ.get("CVE_POLICY_FILE")
    if not path:
        raise GateError("CVE policy file is not configured")
    policy = workflow.read_policy_file(path)
    alert_settings(policy)
    if args.action == "collect":
        if args.alert is not None and any(number < 1 for number in args.alert):
            raise GateError("--alert takes a positive alert number")
        only = None if args.alert is None else set(args.alert)
        document = collect(policy, github_from_env(policy), only=only)
        Path(args.candidates).write_text(json.dumps(document, indent=2) + "\n")
        selected = "" if only is None else f"{document['alerts_selected']} selected; "
        print(f"{document['alerts_read']} open alerts read; {selected}{len(document['candidates'])} candidates")
        for candidate in document["candidates"]:
            print(
                f"  candidate: alert {candidate['alert']} {candidate['cve']} {candidate['package']} "
                f"-> {candidate['product']} {candidate['release']} ({candidate['outcome']})"
            )
        reasons = {}
        for entry in document["skipped"]:
            reasons[entry["reason"]] = reasons.get(entry["reason"], 0) + 1
        for reason, count in sorted(reasons.items()):
            print(f"  skipped {count}: {reason}")
        return
    document = workflow.read_json(args.candidates)
    if args.action == "investigate":
        tool = shlex.split(args.tool or "")
        if not tool or not args.workdir:
            raise GateError("investigate needs --tool and --workdir")
        report = investigate(policy, document, tool, args.workdir)
        Path(args.candidates).write_text(json.dumps(document, indent=2) + "\n")
        print(f"evidence tool asked about {report['asked']} candidates; {report['answered']} answered, {report['failed']} failed")
        for entry in document["candidates"]:
            evidence = entry.get("evidence") if isinstance(entry, dict) else None
            if evidence:
                print(
                    f"  alert {entry.get('alert')} {entry.get('cve')} -> {entry.get('product')} {entry.get('release')}: "
                    f"{evidence['outcome']} (coverage {evidence['coverage']})"
                )
        return
    report = publish(policy, document, workflow.jira_from_env(), dry_run=args.dry_run)
    for entry in report["created"]:
        print(f"created {entry['key']}: {entry['summary']}")
    for entry in report["existing"]:
        print(f"already open {entry['key']}: {entry['summary']}")
    if report["refused"]:
        print(f"refused {report['refused']} entries that do not fit the policy")
    if report["cleared"]:
        print(f"left out {report['cleared']} candidates the evidence tool showed to be outside the vulnerable range")
    if report["over_limit"]:
        print(f"left {report['over_limit']} work items for a later run (max_new_work_items)")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Only our fixed diagnostics may be echoed.
        message = str(error) if isinstance(error, GateError) else type(error).__name__
        print("CVE alert intake stopped: " + message, file=sys.stderr)
        sys.exit(1)
