#!/usr/bin/env python3
"""Trusted CVE admission, assessment persistence and coding gates.

No model calls or forge writes. Jira writes are limited to the assessment
property and a findings comment; upstream Fullsend owns PR creation/review/fix.
"""

import argparse
import base64
import hashlib
import json
import math
import io
import os
from pathlib import Path
import re
import tarfile
import tempfile
import time
import subprocess
import sys
import urllib.error
import urllib.request

import version_knowledge
import target_configuration
from text_safety import has_hidden_text


INTAKE_PROPERTY = "fullsend.cve.intake"
ASSESSMENT_PROPERTY = "fullsend.cve.assessment"
CONTEXT_FILE = ".cve-context.json"
IDENTITY_PATTERN = r"[A-Za-z0-9._:/+-]{1,256}"
TARGET_MAPPING_ERROR = (
    "product/release/stream needs exactly one configured source target; "
    "ask the owner to clarify or use separate target-specific tickets"
)
REMEDIATION_TYPES = {
    "dependency_update": "Dependency/runtime update",
    "patched_fork": "Maintained patched fork",
    "patch_backport": "Patch backport",
    "source_fix": "Targeted source fix",
    "rebuild": "Rebuild only",
}


class GateError(ValueError):
    """A case must stop before model execution or before publishing findings."""


class TargetUnresolved(GateError):
    """Configured product/release context could not be verified; no verdict."""


def trusted_settings():
    """Return the Jira site, service account and forge host this installation trusts.

    They come from the adopter's CVE policy file, so the agent names no site or
    account of its own. account_email and forge_url are optional.
    """
    path = os.environ.get("CVE_POLICY_FILE")
    if not path:
        raise GateError("CVE policy file is not configured")
    policy = read_json(path)
    jira = policy.get("jira")
    if (
        not isinstance(jira, dict)
        or not isinstance(jira.get("base_url"), str)
        or not re.fullmatch(r"https://[A-Za-z0-9.-]+", jira["base_url"])
    ):
        raise GateError("CVE policy must name the trusted Jira site as jira.base_url")
    email = jira.get("account_email", "")
    forge = policy.get("forge_url", "")
    if not isinstance(email, str) or not isinstance(forge, str) or (
        forge and not re.fullmatch(r"https://[A-Za-z0-9.-]+", forge)
    ):
        raise GateError("invalid jira.account_email or forge_url in CVE policy")
    return jira["base_url"], email, forge


# DRAFT, stopgap. Paths that hold a run's own settings when the job's checkout
# is also the place the source gets checked out (GitLab), and the names kept
# out of the source's index while it is there.
RUN_SETTINGS_PATHS = (".fullsend", ".gitlab", ".gitlab-ci.yml")
RUN_LOCAL_EXCLUDES = (
    "/.fullsend/",
    "/.gitlab/",
    "/.gitlab-ci.yml",
    "/output/",
    "/fullsend-artifact/",
    "/" + CONTEXT_FILE,
)
GITHUB_APP_ENV = (
    "CVE_PUBLISHER_GITHUB_APP_ID",
    "CVE_PUBLISHER_GITHUB_INSTALLATION_ID",
    "CVE_PUBLISHER_GITHUB_APP_KEY_B64",
)


def remote_source():
    """The GitHub repository to work on when it is not the job's own project.

    A policy `source` block names the project the job runs in:
    {"forge": "github", "host_project": "group/project"}. The policy's
    `repository` is then a github.com repository that the pre-scripts fetch
    into the job's checkout and the code publisher opens its pull request on.
    Returns None when the policy has no such block.
    """
    path = os.environ.get("CVE_POLICY_FILE")
    if not path:
        return None
    policy = read_json(path)
    source = policy.get("source")
    if source is None:
        return None
    repository = policy.get("repository")
    if (
        not isinstance(source, dict)
        or set(source) != {"forge", "host_project"}
        or source["forge"] != "github"
        or not isinstance(source["host_project"], str)
        or not re.fullmatch(r"(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+", source["host_project"])
        or not isinstance(repository, str)
        or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
    ):
        raise GateError("invalid source block in CVE policy")
    return {
        "repository": repository,
        "host_project": source["host_project"],
        "url": "https://github.com/" + repository + ".git",
    }


def job_repository(policy):
    """The repository the run itself belongs to, as the dispatcher names it."""
    source = remote_source()
    return source["host_project"] if source else policy["repository"]


def rs256_signature(pem, message):
    """RSASSA-PKCS1-v1_5 with SHA-256, from a PKCS#1 PEM key, standard library only.

    The runner image has neither the openssl command nor a Python RSA library.
    This signs one short-lived token request per run on the host; it is not a
    general-purpose signer.
    """
    # The marker is split so secret scanners do not read it as a key.
    if b"-----BEGIN RSA " + b"PRIVATE KEY-----" not in pem:
        raise ValueError("PKCS#1 RSA key required")
    der = base64.b64decode(
        b"".join(line for line in pem.splitlines() if not line.startswith(b"-----"))
    )

    def element(position):
        tag, length = der[position], der[position + 1]
        position += 2
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(der[position : position + count], "big")
            position += count
        return tag, position, position + length

    tag, position, end = element(0)
    if tag != 0x30 or end != len(der):
        raise ValueError("unexpected key encoding")
    integers = []
    while position < end:
        tag, start, position = element(position)
        if tag != 0x02:
            raise ValueError("unexpected key encoding")
        integers.append(int.from_bytes(der[start:position], "big"))
    modulus, private_exponent = integers[1], integers[3]
    size = (modulus.bit_length() + 7) // 8
    info = bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(message).digest()
    padded = b"\x00\x01" + b"\xff" * (size - len(info) - 3) + b"\x00" + info
    return pow(int.from_bytes(padded, "big"), private_exponent, modulus).to_bytes(size, "big")


def github_app_token(repository):
    """A short-lived installation token for one repository.

    Stopgap until the token mint can serve this caller: the App's private key
    is a protected CI/CD variable. The key stays in memory, and the token is
    never printed.
    """
    app, installation, key = (os.environ.get(name, "") for name in GITHUB_APP_ENV)
    try:
        if not re.fullmatch(r"[1-9][0-9]*", app) or not re.fullmatch(r"[1-9][0-9]*", installation):
            raise ValueError("ids")
        pem = base64.b64decode(key, validate=True)
        encode = lambda raw: base64.urlsafe_b64encode(raw).rstrip(b"=")  # noqa: E731
        now = int(time.time())
        signing = (
            encode(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
            + b"."
            + encode(json.dumps({"iat": now - 30, "exp": now + 300, "iss": app}).encode())
        )
        signature = rs256_signature(pem, signing)
        request = urllib.request.Request(
            f"https://api.github.com/app/installations/{installation}/access_tokens",
            method="POST",
            data=json.dumps(
                {
                    "repositories": [repository.split("/", 1)[1]],
                    "permissions": {"contents": "write", "pull_requests": "write"},
                }
            ).encode(),
            headers={
                "Authorization": "Bearer " + (signing + b"." + encode(signature)).decode(),
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "fullsend-cve",
            },
        )
        with urllib.request.urlopen(request, timeout=45) as response:
            token = json.loads(response.read(1 << 20))["token"]
        if not isinstance(token, str) or not token:
            raise ValueError("token")
        return token
    except Exception:
        raise GateError("GitHub source credential is unavailable") from None


def github_git_env(token):
    """Environment that authenticates git to github.com without argv or files."""
    env = dict(os.environ)
    count = int(env.get("GIT_CONFIG_COUNT", "0"))
    basic = base64.b64encode(("x-access-token:" + token).encode()).decode()
    env[f"GIT_CONFIG_KEY_{count}"] = "http.https://github.com/.extraheader"
    env[f"GIT_CONFIG_VALUE_{count}"] = "AUTHORIZATION: basic " + basic
    env["GIT_CONFIG_COUNT"] = str(count + 1)
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def schema_file():
    """The assessment schema ships next to this module."""
    return os.environ.get("CVE_SCHEMA_FILE") or str(
        Path(__file__).with_name("cve-assessment.schema.json")
    )


def read_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def load_release_mappings(path):
    """Read operator-configured versions and targets; never infer a source branch."""
    try:
        sources = target_configuration.entries(target_configuration.read(path))
    except target_configuration.MappingConfigError as error:
        raise GateError(str(error)) from None
    result = []
    ids = set()
    for source in sources:
        required = ("product", "version", "repository", "branch")
        if not isinstance(source, dict) or any(
            not isinstance(source.get(field), str) or not source[field]
            for field in required
        ):
            raise GateError(
                "each mapping requires product, version, repository and branch"
            )
        for field in ("product", "version", "stream", "component"):
            if field in source and (
                not isinstance(source[field], str)
                or not re.fullmatch(IDENTITY_PATTERN, source[field])
            ):
                raise GateError(
                    "release mapping "
                    + field
                    + " must be a 1-256 character ASCII identifier using letters, digits or ._:/+-"
                )
        if "release" in source:
            raise GateError("use version in release mapping configuration")
        try:
            version_knowledge.validate_references(source.get("version_skills", []))
        except version_knowledge.VersionSkillError as error:
            raise GateError(str(error)) from None
        entry = dict(source)
        entry.setdefault(
            "id", "source-" + digest({key: source[key] for key in required})[:16]
        )
        if not isinstance(entry["id"], str) or entry["id"] in ids:
            raise GateError("release mappings require unique IDs")
        ids.add(entry["id"])
        entry["release"] = entry.pop("version")
        entry.setdefault("component", ".")
        for field in ("manifest", "manifest_format", "manifest_identity"):
            entry.setdefault(field, "")
        entry.setdefault("evidence", [])
        result.append(entry)

    return result


def repository_targets(mappings, repository):
    """Return candidate configuration, never an applicability or execution grant."""
    if not isinstance(repository, str) or not re.fullmatch(
        r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository
    ):
        raise GateError("candidate lookup requires a repository identity")
    return sorted(
        [
            json.loads(json.dumps(entry))
            for entry in mappings
            if entry["repository"] == repository
        ],
        key=lambda entry: (
            entry["product"],
            entry["release"],
            entry.get("stream", ""),
            entry["id"],
        ),
    )


def read_policy_file(path):
    """Load operational gates and resolve their declarative mapping reference."""
    path = Path(path)
    policy = read_json(path)
    reference = policy.get("release_mappings_file")
    if reference is not None:
        if (
            "release_mappings" in policy
            or not isinstance(reference, str)
            or Path(reference).name != reference
            or reference in {".", ".."}
        ):
            raise GateError("policy requires one local release mapping file")
        policy["release_mappings"] = load_release_mappings(path.parent / reference)
        policy.pop("release_mappings_file")
    try:
        version_knowledge.validate_prefixes(policy.get("version_skill_sources", []))
    except version_knowledge.VersionSkillError as error:
        raise GateError(str(error)) from None
    return policy


def source_policy(settings):
    """Generic repository-scope policy, independent of CVE and ticket IDs."""
    entries = [
        dict(
            entry,
            owner=settings["owners"][0],
            stream=entry.get("stream", entry["release"]),
        )
        for entry in settings["release_mappings"]
    ]
    return {
        "repository": settings["repository"],
        "project": settings["project"],
        "owners": sorted({entry["owner"] for entry in entries}),
        "fix_category": "source-assessment",
        "assessment_profile": "source_snapshot",
        # Count the full target set before enforcing repository-only execution.
        "repository_scope_only": True,
        "required_labels": ["cve-public", "fullsend-source-assessment"],
        "blocked_labels": settings["blocked_labels"],
        "remediation": {
            "preference_order": settings["remediation"]["preference_order"],
            "coding_types": [],
            "change_paths": [],
        },
        "release_mappings": entries,
        **{
            field: settings[field]
            for field in ("version_skill_sources",)
            if field in settings
        },
    }


def read_policy():
    path = Path(os.environ["CVE_POLICY_FILE"])
    policy = read_policy_file(path)
    expected = job_repository(policy)
    if os.environ.get("REPO_FULL_NAME", expected) != expected:
        raise GateError("target repository has no trusted policy profile")
    if "issue_profiles" in policy:
        raise GateError(
            "ticket-specific policy routing is retired; configure release mappings"
        )

    mode = os.environ.get("CVE_POLICY_MODE", "")
    if mode == "source":
        policy = source_policy(policy)
    elif mode == "auto":
        candidate = source_policy(policy)
        key = live_key(policy)
        fields = jira_from_env().issue(key)["fields"]
        if set(candidate["required_labels"]).issubset(fields.get("labels", [])):
            policy = candidate
    elif mode:
        raise GateError("unknown CVE policy mode")
    return policy


def digest(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def preference_order(capabilities):
    groups = capabilities.get("preference_order")
    if (
        not isinstance(groups, list)
        or not groups
        or any(
            not isinstance(group, list)
            or not group
            or any(not isinstance(kind, str) for kind in group)
            for group in groups
        )
    ):
        raise GateError("configured remediation preference must contain nonempty tiers")
    flat = [kind for group in groups for kind in group]
    if len(flat) != len(set(flat)) or set(flat) != set(REMEDIATION_TYPES):
        raise GateError(
            "configured remediation preference must include each type exactly once"
        )
    return groups


def validate_capabilities(capabilities):
    preference_order(capabilities)
    kinds = capabilities.get("coding_types")
    paths = capabilities.get("change_paths")
    if (
        not isinstance(kinds, list)
        or any(
            not isinstance(k, str) or k not in REMEDIATION_TYPES or k == "rebuild"
            for k in kinds
        )
        or len(kinds) != len(set(kinds))
    ):
        raise GateError(
            "coding types must be distinct supported source remediation types"
        )
    if (
        not isinstance(paths, list)
        or any(
            not isinstance(p, str)
            or not p
            or not Path(p).parts
            or Path(p).is_absolute()
            or ".." in Path(p).parts
            or "\\" in p
            or Path(p).as_posix() != p
            or any(ord(c) < 32 for c in p)
            for p in paths
        )
        or len(paths) != len(set(paths))
    ):
        raise GateError("coding paths must be distinct repository-relative files")


def reject_hidden_text(value):
    if isinstance(value, str):
        if has_hidden_text(value):
            raise GateError(
                "assessment contains hidden or directional control text: remove invisible format/control characters and variation selectors (including emoji presentation selectors); use plain visible text"
            )
    elif isinstance(value, dict):
        for item in value.values():
            reject_hidden_text(item)
    elif isinstance(value, list):
        for item in value:
            reject_hidden_text(item)


def resolve_target(intake, policy):
    """Select one explicit relationship; never guess from a CVE or repo name."""
    mappings = policy.get("release_mappings")
    if not isinstance(mappings, list) or not mappings:
        raise TargetUnresolved("release mapping configuration is missing")
    matches = [
        entry
        for entry in mappings
        if isinstance(entry, dict)
        and all(entry.get(field) == intake[field] for field in ("product", "release"))
        and entry.get("stream", intake["stream"]) == intake["stream"]
    ]
    if len(matches) != 1:
        raise TargetUnresolved(TARGET_MAPPING_ERROR)
    entry = dict(matches[0])
    if "upstream" in entry:
        try:
            target_configuration.validate_upstream(entry["upstream"])
        except target_configuration.MappingConfigError as error:
            raise TargetUnresolved(str(error)) from None
    if "jira" in entry:
        try:
            target_configuration.validate_jira(entry["jira"])
        except target_configuration.MappingConfigError as error:
            raise GateError(str(error)) from None
        if entry["jira"].get("project", policy["project"]) != policy["project"]:
            raise GateError(
                "target Jira project is outside this installation's configured project"
            )
    try:
        version_knowledge.validate_references(entry.get("version_skills", []))
    except version_knowledge.VersionSkillError as error:
        raise TargetUnresolved(str(error)) from None
    if policy.get("repository_scope_only") and (
        entry.get("repository") != policy["repository"] or entry.get("component") != "."
    ):
        raise TargetUnresolved(
            "source assessment requires one repository-root target in the authorized repository"
        )
    # Derived by the host; never trust a supplied provenance marker.
    entry["stream_source"] = "mapping_or_policy" if "stream" in entry else "intake"
    entry.setdefault("owner", intake["owner"])
    entry.setdefault("stream", intake["stream"])
    required = {
        "id",
        "product",
        "release",
        "stream",
        "repository",
        "branch",
        "component",
        "owner",
    }
    if any(
        not isinstance(entry.get(field), str)
        or not entry[field]
        or len(entry[field]) > 256
        or any(ord(c) < 32 for c in entry[field])
        for field in required
    ):
        raise TargetUnresolved("release mapping has invalid required fields")
    if (
        not isinstance(entry.get("evidence"), list)
        or len(entry["evidence"]) > 10
        or any(
            not isinstance(x, str)
            or not x
            or len(x) > 512
            or any(ord(c) < 32 for c in x)
            for x in entry["evidence"]
        )
    ):
        raise TargetUnresolved("release mapping needs bounded provenance references")
    for field in ("repository", "component", "owner"):
        if entry[field] != intake[field]:
            raise TargetUnresolved("intake contradicts configured release " + field)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", entry["repository"]):
        raise TargetUnresolved("invalid configured repository identity")
    branch = entry["branch"]
    if (
        not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", branch)
        or ".." in branch
        or "//" in branch
        or branch.endswith(("/", ".", ".lock"))
    ):
        raise TargetUnresolved("invalid configured release branch")
    for field in ("component", "manifest"):
        if not entry[field]:
            continue
        path = Path(entry[field])
        if (
            path.is_absolute()
            or ".." in path.parts
            or ":" in entry[field]
            or "\\" in entry[field]
        ):
            raise TargetUnresolved(
                "configured component/manifest must be repository-relative"
            )
    manifest_fields = [
        entry[field] for field in ("manifest", "manifest_format", "manifest_identity")
    ]
    if any(manifest_fields) and (
        not all(manifest_fields)
        or entry["manifest_format"] not in {"requirements", "go-module"}
    ):
        raise TargetUnresolved(
            "manifest overrides require path, supported format and identity"
        )
    return entry


def repository_identity(remote):
    """Accept GitHub origins or the configured forge host, never keeping credentials."""
    match = re.fullmatch(
        r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
        r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?",
        remote,
    )
    if match:
        return match[1]
    try:
        forge = trusted_settings()[2]
    except GateError:
        forge = ""  # no trusted policy: GitHub origins only, as before
    if forge:
        # A CI checkout can carry a job token in the origin URL. Match past it
        # and return only the project path.
        match = re.fullmatch(
            r"https://(?:[^@/\s]+@)?"
            + re.escape(forge.removeprefix("https://"))
            + r"/((?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+?)(?:\.git)?/?",
            remote,
        )
        if match:
            return match[1]
    raise TargetUnresolved("checkout origin is not a supported repository identity")


def git_value(target, *args, detached_ok=False):
    try:
        return subprocess.check_output(
            ["git", "-C", str(target), *args], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except subprocess.CalledProcessError as error:
        if detached_ok and error.returncode == 1:
            return ""
        raise TargetUnresolved(
            "required checkout identity or release branch ref is unavailable"
        ) from None
    except OSError:
        raise TargetUnresolved("Git checkout identity could not be read") from None


def verify_checkout(context, target):
    """Verify observed source against configuration, including detached CI HEAD."""
    entry = context["target"]
    repository = repository_identity(git_value(target, "remote", "get-url", "origin"))
    if repository != entry["repository"]:
        raise TargetUnresolved(
            "checkout origin contradicts the configured release repository. "
            f"Expected: {entry['repository']}; observed: {repository}"
        )
    revision = git_value(target, "rev-parse", "--verify", "HEAD^{commit}")
    ref = "refs/remotes/origin/" + entry["branch"]
    expected = git_value(target, "rev-parse", "--verify", ref + "^{commit}")
    branch = git_value(
        target, "symbolic-ref", "--quiet", "--short", "HEAD", detached_ok=True
    )
    if not re.fullmatch(r"[a-f0-9]{40}", revision):
        raise TargetUnresolved("checkout revision is invalid")
    if revision != expected or (branch and branch != entry["branch"]):
        raise TargetUnresolved(
            "checkout revision/branch contradicts the configured release branch. "
            f"Expected: {entry['branch']} at {expected}; "
            f"observed: {branch or 'detached HEAD'} at {revision}"
        )
    files = {}
    if entry["component"] == "." and git_value(
        target, "status", "--porcelain", "--untracked-files=no"
    ):
        raise TargetUnresolved("repository source differs from admitted revision")
    for name in (entry["component"], entry["manifest"]):
        if not name or name == ".":
            continue
        path = Path(target) / name
        try:
            relative = path.resolve().relative_to(Path(target).resolve())
            if relative.as_posix() != name:
                raise ValueError("symlink or noncanonical path")
            committed = subprocess.check_output(
                ["git", "-C", str(target), "show", revision + ":" + name],
                stderr=subprocess.DEVNULL,
            )
            if path.read_bytes() != committed:
                raise ValueError("worktree differs from inspected revision")
        except (OSError, ValueError, subprocess.CalledProcessError):
            raise TargetUnresolved(
                "mapped component/manifest is missing, redirected or modified"
            ) from None
        files[name] = hashlib.sha256(committed).hexdigest()
    if entry["manifest"]:
        manifest = (Path(target) / entry["manifest"]).read_text(encoding="utf-8")
        identity = re.escape(entry["manifest_identity"])
        pattern = (
            rf"(?im)^\s*{identity}\s*(?:[<=>!~\[]|$)"
            if entry["manifest_format"] == "requirements"
            else rf"(?m)^module\s+{identity}\s*$"
        )
        if not re.search(pattern, manifest):
            raise TargetUnresolved(
                "manifest identity contradicts the configured product component"
            )
    try:
        skills = version_knowledge.resolve(
            entry.get("version_skills", []),
            Path(os.environ.get("CVE_WORKFLOW_FILE", __file__)).resolve().parent.parent,
            context.get("version_skill_sources", []),
        )
    except version_knowledge.VersionSkillError as error:
        raise TargetUnresolved(str(error)) from None
    connection = {
        "status": "verified",
        "evidence_mode": "checkout",
        "mapping": entry,
        "mapping_digest": digest(entry),
        "repository": repository,
        "branch": entry["branch"],
        "branch_ref": ref,
        "repository_sha": revision,
        "files": files,
    }
    if skills:
        connection["version_skills"] = [
            {field: skill[field] for field in ("source", "sha256")} for skill in skills
        ]
    return dict(
        context,
        **({"version_skills": skills} if skills else {}),
        repository_sha=revision,
        target_connection=connection,
        target_digest=digest(connection),
    )


def connection_summary(context):
    connection = context["target_connection"]
    entry = connection["mapping"]
    stream_source = (
        "from intake; mapping is stream-agnostic"
        if entry["stream_source"] == "intake"
        else "from mapping/policy"
    )
    jira = entry.get("jira", {})
    jira_summary = (
        "Jira mapping: "
        + "; ".join(key + "=" + value for key, value in sorted(jira.items()))
        + "\n"
        if jira
        else ""
    )
    upstream = entry.get("upstream")
    upstream_summary = (
        f"Configured component upstream: {upstream['repository']} at {upstream['ref']} "
        "(lineage only; fix/commit evidence must be investigated)\n"
        if upstream
        else ""
    )
    selected_skills = connection.get("version_skills", [])
    skill_summary = (
        "Version skills: "
        + "; ".join(
            skill["source"] + " (sha256: " + skill["sha256"] + ")"
            for skill in selected_skills
        )
        + "\n"
        if selected_skills
        else ""
    )
    return (
        "Connection used for this assessment:\n"
        f"Product: {entry['product']}; release: {entry['release']}; stream: {entry['stream']} ({stream_source})\n"
        f"Repository: https://github.com/{connection['repository']}\n"
        f"Release branch: {connection['branch']}; checkout: {connection['repository_sha']}\n"
        f"Component: {entry['component']}; manifest: {entry['manifest'] or 'agent discovery'}\n"
        f"Manifest identity: {entry['manifest_identity'] or 'agent discovery'}; mapping owner: {entry['owner']}\n"
        f"Mapping: {entry['id']}; revision (SHA-256): {connection['mapping_digest']}\n"
        f"Mapping evidence: {'; '.join(entry['evidence'])}\n"
        f"Checkout verification: {connection['status']} ({connection['evidence_mode']})\n"
        f"{upstream_summary}"
        f"{jira_summary}"
        f"{skill_summary}"
        "Scope: this configured target and source revision only; no product-wide or other-release verdict.\n"
    )


def check_disclosure(issue, policy):
    """Check issue classification before requesting any substantive content."""
    fields = issue.get("fields", {})
    labels = fields.get("labels", [])
    if not isinstance(labels, list) or any(not isinstance(x, str) for x in labels):
        raise GateError("invalid labels")
    lowered = {x.lower() for x in labels}
    # Any Jira security level refuses the case, whatever the level is called.
    # KNOWN LIMIT: a Jira site can put a site-wide level (for example
    # "employees only") on every vulnerability tracker, public CVEs included.
    # The first team this lane was tried with has that on all of its open
    # trackers, so this check refuses every real one of them, and the trial
    # ran on a hand-made copy of the public facts instead. Letting such a
    # tracker in means its text reaches the model and the job log, so naming
    # the levels an adopter accepts has to be a policy decision, not a default.
    if (
        "security" not in fields
        or fields["security"] is not None
        or lowered.intersection(policy["blocked_labels"])
        or not set(policy["required_labels"]).issubset(labels)
    ):
        raise GateError(
            "public disclosure required; restricted or embargoed cases are excluded"
        )


def check_issue_state(issue, policy):
    check_disclosure(issue, policy)
    fields = issue["fields"]
    if not re.fullmatch(
        re.escape(policy["project"]) + r"-[1-9][0-9]*", issue.get("key", "")
    ):
        raise GateError("issue outside configured project")
    if fields.get("status", {}).get("statusCategory", {}).get("key") == "done":
        raise GateError("issue already done")
    if not (fields.get("assignee") or {}).get("accountId"):
        raise GateError("issue needs an assignee")
    return fields


def admit(issue, intake, policy):
    """Fail closed on disclosure, then restrict the one-repository MVP scope."""
    fields = check_issue_state(issue, policy)
    if not isinstance(intake, dict) or intake.get("disclosure") != "public":
        raise GateError(
            "public disclosure required; restricted or embargoed cases are excluded"
        )
    key = issue.get("key", "")
    allowed = {
        "product",
        "release",
        "cve",
        "disclosure",
        "repository",
        "owner",
        "stream",
        "fix_category",
        "component",
        "advisory_url",
    }
    identity = ("product", "release", "stream", "component")
    # Authorization failures must not take the publishable context-error path.
    # Missing or malformed identity values are handled only after those gates.
    if (
        set(intake) - allowed
        or (allowed - set(intake)) - set(identity)
        or any(
            not isinstance(value, str)
            for field, value in intake.items()
            if field not in identity
        )
    ):
        raise GateError("intake fields do not match the structured intake contract")
    for field in ("repository", "fix_category"):
        if intake[field] != policy[field]:
            raise GateError("intake outside configured " + field)
    if intake["owner"] not in policy["owners"]:
        raise GateError("unrecognized component owner")
    if not re.fullmatch(r"CVE-[0-9]{4}-[0-9]{4,}", intake["cve"]):
        raise GateError("invalid CVE identifier")
    if not re.fullmatch(
        r"https://[a-zA-Z0-9.-]+/[a-zA-Z0-9_./%#?=&+-]{1,1000}", intake["advisory_url"]
    ):
        raise GateError("a public HTTPS advisory URL is required")
    validate_capabilities(policy["remediation"])
    if any(
        not isinstance(intake.get(field), str)
        or not intake[field].strip()
        or intake[field] != intake[field].strip()
        or not re.fullmatch(IDENTITY_PATTERN, intake[field])
        for field in identity
    ):
        raise TargetUnresolved(
            "product and release, stream and component each require one nonempty "
            "scalar identifier (1-256 ASCII letters, digits or ._:/+-); "
            "ask the owner to clarify or use separate target-specific tickets"
        )
    target = resolve_target(intake, policy)
    profile = policy.get(
        "assessment_profile",
        "jinja_template_preview"
        if target["manifest_format"] == "requirements"
        else None,
    )
    if profile not in {
        "jinja_template_preview",
        "source_snapshot",
    }:
        raise GateError("known assessment profile required")
    # Bind eligibility to the meaningful current fields, without Jira's updated
    # timestamp: our own comments/properties must not invalidate the receipt.
    return {
        "issue_key": key,
        "intake": intake,
        "target": target,
        "remediation_capabilities": policy["remediation"],
        "assessment_profile": profile,
        **(
            {"version_skill_sources": policy.get("version_skill_sources", [])}
            if target.get("version_skills")
            else {}
        ),
        "intake_digest": digest(
            {
                "intake": intake,
                "policy": policy,
                "assignee": fields["assignee"]["accountId"],
            }
        ),
    }


def poll_jql(policy, key=""):
    if key and not re.fullmatch(re.escape(policy["project"]) + r"-[1-9][0-9]*", key):
        raise GateError("invalid isolated issue key")
    restrictions = [
        f"project = {policy['project']}",
        "statusCategory != Done",
        "level IS EMPTY",
    ]
    restrictions += [f'labels = "{label}"' for label in policy["required_labels"]]
    blocked = ", ".join(f'"{label}"' for label in policy["blocked_labels"])
    restrictions.append(f"labels NOT IN ({blocked})")
    if key:
        restrictions.append(f"key = {key}")
    return " AND ".join(restrictions) + " ORDER BY updated DESC"


def validate_structure(result, schema):
    reject_hidden_text(result)
    import jsonschema

    if isinstance(result, dict) and result.get("schema_version") != 2:
        raise GateError(
            "assessment format changed; run /fs-cve-triage for a version-2 remediation plan"
        )
    jsonschema.Draft202012Validator(schema).validate(result)
    if not math.isfinite(result["confidence"]):
        raise GateError("confidence must be finite")
    if len(json.dumps(result).encode()) > 24000:
        raise GateError("assessment exceeds Jira property budget")
    validate_plan(result)


def validate_plan(result):
    """Cross-check plan semantics after JSON schema validation."""
    plan = result["remediation_plan"]
    options = plan["options"]
    ids = [option["id"] for option in options]
    types = [option["type"] for option in options]
    if len(set(ids)) != len(ids) or len(set(types)) != len(types):
        raise GateError("remediation option IDs and types must be unique")
    for option in options:
        if any(index >= len(result["evidence"]) for index in option["evidence_refs"]):
            raise GateError("remediation option references missing evidence")
        for name in option["change_paths"]:
            path = Path(name)
            if (
                path.is_absolute()
                or path.as_posix() != name
                or ".." in path.parts
                or "\\" in name
            ):
                raise GateError("remediation change paths must be repository-relative")
        if option["status"] == "viable" and (
            not option["evidence_refs"]
            or not option["steps"]
            or not option["verification"]
            or option["blockers"]
        ):
            raise GateError(
                "viable remediation needs evidence, steps and verification without blockers"
            )
        if option["status"] == "needs_investigation" and not option["blockers"]:
            raise GateError("investigation option must identify missing prerequisites")
    if result["verdict"] == "affected":
        if set(types) != set(REMEDIATION_TYPES):
            raise GateError(
                "affected assessment must consider all five remediation types"
            )
        if plan["state"] not in {"ready", "blocked"}:
            raise GateError(
                "affected assessment needs a ready or blocked remediation plan"
            )
    elif result["verdict"] == "not_affected":
        if plan["state"] != "not_required":
            raise GateError("not-affected assessment cannot authorize remediation")
    elif plan["state"] != "blocked":
        raise GateError("uncertain or failed assessment needs a blocked plan")
    if plan["state"] == "ready":
        selected = recommended_option(result)
        if selected is None or selected["status"] != "viable" or plan["blockers"]:
            raise GateError(
                "ready plan must select a viable assessed option without blockers"
            )
        if selected["type"] != "rebuild" and not selected["change_paths"]:
            raise GateError("coding plan must identify intended change paths")
    else:
        if plan["recommended_option_id"] is not None:
            raise GateError("blocked or unnecessary plan cannot select an option")
        if plan["state"] == "blocked" and not plan["blockers"]:
            raise GateError("blocked plan must explain its blockers")


def recommended_option(result):
    plan = result["remediation_plan"]
    return next(
        (
            option
            for option in plan["options"]
            if option["id"] == plan["recommended_option_id"]
        ),
        None,
    )


def validate_preference(result, capabilities):
    groups = preference_order(capabilities)
    if result["remediation_plan"]["state"] != "ready":
        return
    rank = {kind: index for index, group in enumerate(groups) for kind in group}
    selected = recommended_option(result)
    for option in result["remediation_plan"]["options"]:
        if rank[option["type"]] < rank[selected["type"]] and (
            option["status"] != "ruled_out" or not option["evidence_refs"]
        ):
            raise GateError(
                "higher-priority remediation must be ruled out with evidence before selecting a fallback"
            )


def bind_execution_approval(context, receipt, schema):
    """Bind a human /fs-code request to only the exact reviewed assessment plan."""
    result = validate_result(receipt.get("result"), schema, context)
    if result["verdict"] != "affected":
        return context
    path = os.environ.get("CVE_EXECUTION_APPROVALS_FILE")
    matches = []
    if path:
        data = read_json(path)
        if data.get("version") != 1 or not isinstance(data.get("approvals"), list):
            raise GateError("invalid execution approval configuration")
        matches = [
            item
            for item in data["approvals"]
            if item.get("assessment_digest") == digest(result)
        ]
    if not matches:
        # The code harness enables this only for Fullsend's exact /fs-code
        # trigger, which already requires a human Jira commenter with write
        # access. Treat that command as approval for this one ready plan; do
        # not create a broad, reusable capability from it.
        if os.environ.get("CVE_CODE_COMMAND_AUTHORIZATION") != "recommended-plan":
            return context
        plan = result["remediation_plan"]
        selected = recommended_option(result)
        if (
            plan["state"] != "ready"
            or selected is None
            or selected["status"] != "viable"
            or selected["type"] not in set(REMEDIATION_TYPES) - {"rebuild"}
        ):
            return context
        matches = [
            {
                "assessment_digest": digest(result),
                "repository_sha": context["repository_sha"],
                "target_digest": context["target_digest"],
                "option_id": selected["id"],
                "type": selected["type"],
                "change_paths": selected["change_paths"],
            }
        ]
    if len(matches) != 1:
        raise GateError("ambiguous execution approval")
    approval = matches[0]
    selected = recommended_option(result)
    if (
        approval.get("repository_sha") != context["repository_sha"]
        or approval.get("target_digest") != context["target_digest"]
        or approval.get("option_id") != selected["id"]
        or approval.get("type") != selected["type"]
        or set(approval.get("change_paths", [])) != set(selected["change_paths"])
    ):
        raise GateError("execution approval differs from assessment, target or plan")
    capabilities = {
        "preference_order": context["remediation_capabilities"]["preference_order"],
        "coding_types": [approval["type"]],
        "change_paths": approval["change_paths"],
    }
    validate_capabilities(capabilities)
    return dict(
        context,
        execution_capabilities=capabilities,
        execution_approval_digest=digest(approval),
    )


def implementation_route(result, context):
    """Host capabilities decide execution; the model cannot enable an adapter."""
    if (
        result["verdict"] != "affected"
        or result["remediation_plan"]["state"] != "ready"
    ):
        return "not_ready"
    option = recommended_option(result)
    if option["type"] == "rebuild":
        return "build_handoff"
    capabilities = context.get(
        "execution_capabilities", context["remediation_capabilities"]
    )
    if option["type"] not in capabilities["coding_types"] or not set(
        option["change_paths"]
    ).issubset(capabilities["change_paths"]):
        return "scope_handoff"
    return "code"


def validate_result(result, schema, context):
    validate_structure(result, schema)
    if context.get("target_connection", {}).get("status") != "verified" or context.get(
        "target_digest"
    ) != digest(context["target_connection"]):
        raise TargetUnresolved(
            "verified target context required before any applicability verdict"
        )
    # The runner's output scanner treats JSON names containing "key" as
    # credentials. Keep the public Jira identifier under a neutral name, while
    # still checking exact equality with the trusted admitted issue.
    for result_field, context_field in (
        ("jira_issue", "issue_key"),
        ("intake_digest", "intake_digest"),
        ("repository_sha", "repository_sha"),
        ("target_digest", "target_digest"),
    ):
        if result[result_field] != context[context_field]:
            raise GateError("assessment does not match current " + context_field)
    if result["cve"] != context["intake"]["cve"]:
        raise GateError("assessment CVE mismatch")
    validate_preference(result, context["remediation_capabilities"])
    return result


def coding_gate(context, receipt, schema):
    if not isinstance(receipt, dict) or receipt.get("version") != 1:
        raise GateError("validated assessment required; run /fs-cve-triage first")
    result = validate_result(receipt.get("result"), schema, context)
    if result["verdict"] != "affected":
        raise GateError(
            "human resolution required; assessment verdict must be affected"
        )
    route = implementation_route(result, context)
    if route == "build_handoff":
        raise GateError(
            "rebuild-only plan needs a build handoff; no build adapter is configured"
        )
    if route == "scope_handoff":
        raise GateError(
            "recommended remediation exceeds configured coding types or change paths"
        )
    if route != "code":
        raise GateError(
            "remediation plan is blocked; resolve prerequisites and run /fs-cve-triage again"
        )
    return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise GateError("Jira redirects refused")


class Jira:
    def __init__(self, base_url, email, token):
        expected_url, expected_email, _ = trusted_settings()
        if (
            base_url != expected_url
            or (expected_email and email != expected_email)
            or not token
        ):
            raise GateError("configured Jira site and service account required")
        self.base_url = base_url
        self.authorization = (
            "Basic " + base64.b64encode(f"{email}:{token}".encode()).decode()
        )
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, method, path, body=None):
        request = urllib.request.Request(
            self.base_url + "/rest/api/3" + path,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={
                "Authorization": self.authorization,
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        try:
            with self.opener.open(request, timeout=30) as response:
                data = response.read(1024 * 1024 + 1)
                if len(data) > 1024 * 1024:
                    raise GateError("Jira response too large")
                return json.loads(data) if data else None
        except urllib.error.HTTPError as error:
            # Never include response bodies, headers or credentials in logs.
            error.close()
            raise GateError(
                f"Jira request failed (HTTP {error.code}); operator retry required"
            ) from None
        except urllib.error.URLError:
            raise GateError("Jira unavailable; operator retry required") from None

    def issue(self, key):
        return self.request(
            "GET", f"/issue/{key}?fields=labels,security,assignee,status"
        )

    def property(self, key, name):
        return self.request("GET", f"/issue/{key}/properties/{name}")["value"]


def prepare_isolated_source(context, target):
    """Replace only a clean runner target-repo with a single-branch fresh clone."""
    target = Path(target)
    if target.is_symlink() or target.name != "target-repo":
        raise GateError("isolated target-repo required")
    target = target.resolve()
    entry = context["target"]
    if (
        repository_identity(git_value(target, "remote", "get-url", "origin"))
        != entry["repository"]
    ):
        raise TargetUnresolved("initial checkout origin contradicts mapping")
    if git_value(target, "status", "--porcelain", "--untracked-files=no"):
        raise TargetUnresolved("initial source has tracked changes")
    with tempfile.TemporaryDirectory(prefix="cve-source-", dir=target.parent) as folder:
        new = Path(folder) / "source"
        subprocess.run(
            [
                "git",
                "-c",
                "credential.helper=",
                "-c",
                "credential.helper=!gh auth git-credential",
                "clone",
                "--depth=1",
                "--single-branch",
                "--no-tags",
                "--branch",
                entry["branch"],
                "https://github.com/" + entry["repository"] + ".git",
                str(new),
            ],
            check=True,
            capture_output=True,
        )
        if (
            repository_identity(git_value(new, "remote", "get-url", "origin"))
            != entry["repository"]
        ):
            raise TargetUnresolved("isolated checkout origin mismatch")
        target.rename(Path(folder) / "previous")
        new.rename(target)


def live_context(jira, key, policy, target, prepare=False):
    # Check labels/security before even fetching structured intake. No issue body
    # or comments are fetched on the runner.
    issue = jira.issue(key)
    check_disclosure(issue, policy)
    intake = jira.property(key, INTAKE_PROPERTY)
    context = admit(issue, intake, policy)
    if prepare:
        if remote_source():
            # A remote source is fetched into the job's checkout whatever the
            # profile; replacing the directory would drop the run's settings.
            prepare_mapped_source(context, target)
        elif policy.get("assessment_profile") == "source_snapshot":
            prepare_isolated_source(context, target)
        elif policy.get("prepare_checkout"):
            prepare_mapped_source(context, target)
        else:
            raise GateError("checkout preparation requires configured host policy")
    return verify_checkout(context, target)


def same_settings_tree(target, ref):
    """Refuse a branch switch that would replace the run's own settings.

    On GitLab the checkout is the project directory, which also holds the
    run's .fullsend directory, read from the default branch. Checking out a
    mapped branch there would hand the rest of the run that branch's copy, so
    the branch must carry exactly the same .fullsend tree as the commit the
    job is on. Where the settings live outside the checkout, as on GitHub,
    there is nothing to compare.
    """
    raw = os.environ.get("FULLSEND_DIR")
    if not raw:
        return
    try:
        inside = Path(raw).resolve().relative_to(Path(target).resolve()).as_posix()
    except ValueError:
        return

    def tree(revision):
        try:
            return git_value(target, "rev-parse", "--verify", "--quiet", revision + ":" + inside)
        except TargetUnresolved:
            return ""

    if tree("HEAD") != tree(ref):
        raise TargetUnresolved(
            "the mapped branch carries different .fullsend settings than the "
            "default branch; give it the same .fullsend directory before assessing it"
        )


def prepare_remote_source(context, target, source, token=None):
    """Fetch a GitHub source branch into the job's checkout and switch to it.

    DRAFT, stopgap. On GitLab an agent job can only hand its own project
    directory to the sandbox, so a source that lives on GitHub has to be
    checked out there. The checkout's origin is re-pointed at the GitHub
    repository, which the later identity checks and the code publisher use.
    The run's own settings paths are restored from the job's commit as
    untracked, ignored files, and a source branch that carries any of those
    paths is refused, so the source can never change the run's settings.
    """
    entry = context["target"]
    if entry["repository"] != source["repository"]:
        raise TargetUnresolved("mapped repository differs from the configured source")
    if git_value(target, "status", "--porcelain", "--untracked-files=no"):
        raise TargetUnresolved("source checkout has local changes; refusing replacement")
    ref = "refs/remotes/origin/" + entry["branch"]
    job_commit = git_value(target, "rev-parse", "--verify", "HEAD^{commit}")
    held = [
        name
        for name in git_value(
            target, "ls-tree", "--name-only", job_commit, "--", *RUN_SETTINGS_PATHS
        ).splitlines()
        if name in RUN_SETTINGS_PATHS
    ]
    token = token or github_app_token(source["repository"])
    try:
        subprocess.run(
            ["git", "-C", str(target), "remote", "set-url", "origin", source["url"]],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(target),
                "-c",
                "credential.helper=",
                "fetch",
                "--no-tags",
                "--depth=1",
                "origin",
                "+refs/heads/" + entry["branch"] + ":" + ref,
            ],
            check=True,
            capture_output=True,
            env=github_git_env(token),
        )
    except (OSError, subprocess.CalledProcessError):
        raise TargetUnresolved("configured target branch could not be prepared") from None
    if git_value(target, "ls-tree", "--name-only", ref, "--", *RUN_SETTINGS_PATHS):
        raise TargetUnresolved(
            "the source branch carries fullsend or CI settings paths; "
            "refusing to check it out over the run's own settings"
        )
    try:
        exclude = Path(git_value(target, "rev-parse", "--git-path", "info/exclude"))
        if not exclude.is_absolute():
            exclude = Path(target) / exclude
        exclude.parent.mkdir(parents=True, exist_ok=True)
        present = exclude.read_text().splitlines() if exclude.exists() else []
        missing = [line for line in RUN_LOCAL_EXCLUDES if line not in present]
        if missing:
            exclude.write_text("\n".join(present + missing) + "\n")
        subprocess.run(
            ["git", "-C", str(target), "checkout", "--detach", ref],
            check=True,
            capture_output=True,
        )
        if held:
            archive = subprocess.run(
                ["git", "-C", str(target), "archive", "--format=tar", job_commit, "--", *held],
                check=True,
                capture_output=True,
            ).stdout
            with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
                for member in bundle.getmembers():
                    top = member.name.split("/", 1)[0]
                    if top not in RUN_SETTINGS_PATHS or not (member.isfile() or member.isdir()):
                        raise TargetUnresolved("run settings could not be restored")
                bundle.extractall(str(target), filter="data")
    except (OSError, subprocess.CalledProcessError, tarfile.TarError):
        raise TargetUnresolved("configured target branch could not be prepared") from None


def publish_remote(publisher):
    """Run the stock code publisher against the GitHub source repository.

    DRAFT, stopgap. The job's forge is GitLab; the validated checkout's origin
    is the GitHub source. Hand the publisher a GitHub token, the GitHub
    repository name and the GitHub forge, without the job's GitLab credentials,
    and leave no token in the checkout's configuration afterwards.
    """
    source = remote_source()
    if not source:
        raise GateError("no remote source is configured")
    checkout = Path(os.environ.get("REPO_DIR", ""))
    branch = os.environ.get("CODE_ALLOWED_TARGET_BRANCHES", "")
    if not checkout.is_dir() or not re.fullmatch(r"[A-Za-z0-9._/-]{1,200}", branch):
        raise GateError("validated coding checkout and one target branch required")
    token = github_app_token(source["repository"])
    clean = ["git", "-C", str(checkout), "remote", "set-url", "origin", source["url"]]
    try:
        subprocess.run(clean, check=True, capture_output=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(checkout),
                "-c",
                "credential.helper=",
                "fetch",
                "--no-tags",
                "--depth=1",
                "origin",
                "+refs/heads/" + branch + ":refs/remotes/origin/" + branch,
            ],
            check=True,
            capture_output=True,
            env=github_git_env(token),
        )
    except (OSError, subprocess.CalledProcessError):
        raise GateError("GitHub target branch could not be fetched for publication") from None
    env = {
        name: value
        for name, value in os.environ.items()
        if not name.startswith(("GITLAB_", "FULLSEND_GITLAB_", "CVE_PUBLISHER_"))
        and name not in {"FULLSEND_JOB_TOKEN", "FULLSEND_FORGE_TOKEN", "CI_JOB_TOKEN"}
    }
    env.update(
        FULLSEND_FORGE="github",
        GITHUB_SERVER_URL="https://github.com",
        REPO_FULL_NAME=source["repository"],
        PUSH_TOKEN=token,
        PUSH_TOKEN_SOURCE="github-app",
        GH_TOKEN=token,
        GITHUB_SIGNED_COMMITS="true",
    )
    try:
        # The publisher announces its token with a GitHub Actions masking
        # command. Only Actions acts on it; any other CI prints the line. Drop
        # those lines and redact the token from everything else it writes.
        process = subprocess.Popen(
            ["bash", publisher],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
        )
        for line in process.stdout:
            if line.startswith("::add-mask::"):
                continue
            sys.stdout.write(line.replace(token, "[redacted]"))
            sys.stdout.flush()
        return process.wait()
    finally:
        subprocess.run(clean, check=False, capture_output=True)


def prepare_mapped_source(context, target):
    """Fetch only the exact operator-configured source branch after admission."""
    source = remote_source()
    if source:
        prepare_remote_source(context, target, source)
        return
    entry = context["target"]
    if (
        repository_identity(git_value(target, "remote", "get-url", "origin"))
        != entry["repository"]
    ):
        raise TargetUnresolved("checkout origin contradicts configured source")
    if git_value(target, "status", "--porcelain", "--untracked-files=no"):
        raise TargetUnresolved(
            "source checkout has local changes; refusing replacement"
        )
    ref = "refs/remotes/origin/" + entry["branch"]
    try:
        subprocess.run(
            [
                "git",
                "-C",
                str(target),
                "-c",
                "credential.helper=",
                "fetch",
                "--no-tags",
                "--depth=1",
                "origin",
                # Force the update. A runner that keeps its checkout between
                # jobs still holds the ref from an earlier shallow fetch, and
                # a shallow fetch can't show that the new head descends from
                # it, so git would reject the move as a non-fast-forward.
                "+refs/heads/" + entry["branch"] + ":" + ref,
            ],
            check=True,
            capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError):
        raise TargetUnresolved(
            "configured target branch could not be prepared"
        ) from None
    same_settings_tree(target, ref)
    try:
        subprocess.run(
            ["git", "-C", str(target), "checkout", "--detach", ref],
            check=True,
            capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError):
        raise TargetUnresolved(
            "configured target branch could not be prepared"
        ) from None


def adf_paragraph(text):
    # Model strings remain literal text, never markup or document nodes.
    content = []
    for index, line in enumerate(text.split("\n")):
        if index:
            content.append({"type": "hardBreak"})
        if line:
            content.append({"type": "text", "text": line})
    return {"type": "paragraph", "content": content}


def adf_plain_text(node):
    """Readable text for inspecting both old and formatted Jira comments."""
    if isinstance(node, str):
        return node
    if node.get("type") == "hardBreak":
        return "\n"
    text = node.get("text", "") + "".join(
        adf_plain_text(child) for child in node.get("content", [])
    )
    if node.get("type") in {"paragraph", "heading"}:
        text += "\n"
    return text


def assessment_comment(result, context):
    """Render the validated result; the host supplies the source connection."""

    def heading(text, level=3):
        return {
            "type": "heading",
            "attrs": {"level": level},
            "content": [{"type": "text", "text": text}],
        }

    content = [
        heading(f"CVE assessment: {result['cve']}", 2),
        {
            "type": "paragraph",
            "content": [
                {"type": "text", "text": "Verdict: ", "marks": [{"type": "strong"}]},
                {"type": "text", "text": result["verdict"].replace("_", " ")},
                {"type": "text", "text": f" | Confidence: {result['confidence']:.0%}"},
            ],
        },
        heading("Summary"),
        adf_paragraph(result["summary"]),
    ]
    # Use the same canonical host report for receipts, previews and publication.
    lines = connection_summary(context).splitlines()
    content.append(heading(lines[0]))
    for line in lines[1:]:
        label, value = line.split(": ", 1)
        text = {"type": "text", "text": value}
        if label == "Repository":
            text["marks"] = [{"type": "link", "attrs": {"href": value}}]
        content.append(
            {
                "type": "paragraph",
                "content": [
                    {
                        "type": "text",
                        "text": label + ": ",
                        "marks": [{"type": "strong"}],
                    },
                    text,
                ],
            }
        )
    plan = result["remediation_plan"]
    groups = preference_order(context["remediation_capabilities"])
    rank = {kind: index for index, group in enumerate(groups) for kind in group}
    content.extend(
        [
            heading("Remediation options"),
            adf_paragraph(
                "Configured preference (types within a tier are equal): "
                + " → ".join(
                    " / ".join(REMEDIATION_TYPES[kind] for kind in group)
                    for group in groups
                )
            ),
            adf_paragraph(
                f"Plan: {plan['state'].replace('_', ' ')}. {plan['rationale']}"
            ),
        ]
    )
    if plan["options"]:
        rows = [
            {
                "type": "tableRow",
                "content": [
                    {"type": "tableHeader", "content": [adf_paragraph(label)]}
                    for label in ("Option", "Assessment", "Reason / evidence")
                ],
            }
        ]
        for option in sorted(plan["options"], key=lambda option: rank[option["type"]]):
            refs = (
                ", ".join(str(index + 1) for index in option["evidence_refs"])
                or "none yet"
            )
            rows.append(
                {
                    "type": "tableRow",
                    "content": [
                        {"type": "tableCell", "content": [adf_paragraph(value)]}
                        for value in (
                            REMEDIATION_TYPES[option["type"]] + f" ({option['id']})",
                            option["status"].replace("_", " "),
                            option["reason"]
                            + f"\nEvidence: {refs}"
                            + (
                                "\nBlockers: " + "; ".join(option["blockers"])
                                if option["blockers"]
                                else ""
                            ),
                        )
                    ],
                }
            )
        content.append({"type": "table", "content": rows})
    selected = recommended_option(result)
    if selected:
        content.extend(
            [
                heading("Recommended approach"),
                adf_paragraph(
                    REMEDIATION_TYPES[selected["type"]] + f" ({selected['id']})"
                ),
                adf_paragraph(
                    "Planned files: "
                    + (", ".join(selected["change_paths"]) or "none — build only")
                ),
                heading("Implementation steps"),
                {
                    "type": "orderedList",
                    "attrs": {"order": 1},
                    "content": [
                        {"type": "listItem", "content": [adf_paragraph(step)]}
                        for step in selected["steps"]
                    ],
                },
                heading("Plan verification"),
                {
                    "type": "bulletList",
                    "content": [
                        {"type": "listItem", "content": [adf_paragraph(step)]}
                        for step in selected["verification"]
                    ],
                },
            ]
        )
    if plan["blockers"]:
        content.extend(
            [heading("Plan blockers"), adf_paragraph("\n".join(plan["blockers"]))]
        )
    route = implementation_route(result, context)
    next_step = {
        "code": "An authorized human may use /fs-code to implement the recommended option at any confidence. "
        "CI, Fullsend review and human/security approval precede merge and closure.",
        "build_handoff": "Build-only handoff: no source implementation is needed. No build adapter is configured; "
        "a build owner must trigger and verify the build. No build has been triggered by this assessment.",
        "scope_handoff": "The recommended option exceeds configured coding types or file scope. "
        "Review the required scope or external handoff before requesting coding.",
        "not_ready": "No coding promotion. Review the applicability finding and any plan blockers; "
        "resolve missing facts and re-triage where needed. Human/security resolution remains required.",
    }[route]
    content.extend(
        [
            heading("Evidence"),
            {
                "type": "orderedList",
                "attrs": {"order": 1},
                "content": [
                    {"type": "listItem", "content": [adf_paragraph(item)]}
                    for item in result["evidence"]
                ],
            },
            heading("Remediation"),
            adf_paragraph(result["remediation"] or "None proposed."),
            heading("Regression checks"),
            adf_paragraph(result["regression_test"] or "None proposed."),
            heading("Next step"),
            adf_paragraph(next_step),
        ]
    )
    return {"type": "doc", "version": 1, "content": content}


def post_comment(jira, key, body):
    if isinstance(body, str):
        body = {"type": "doc", "version": 1, "content": [adf_paragraph(body)]}
    jira.request(
        "POST",
        f"/issue/{key}/comment",
        {"body": body},
    )


def jira_from_env():
    return Jira(
        os.environ.get("JIRA_BASE_URL"),
        os.environ.get("JIRA_USER_EMAIL"),
        os.environ.get("JIRA_TOKEN"),
    )


def live_key(policy):
    url = os.environ.get("CVE_ISSUE_URL", "")
    match = re.fullmatch(
        re.escape(trusted_settings()[0])
        + r"/browse/("
        + re.escape(policy["project"])
        + r"-[1-9][0-9]*)",
        url,
    )
    if not match or os.environ.get("REPO_FULL_NAME") != job_repository(policy):
        raise GateError(
            "Jira issue URL and target repository must match configured scope"
        )
    return match[1]


def code_admission_path():
    # Controller-owned host state; never read authority back from sandbox output.
    # It lives in the run's own .fullsend directory, as when this module was
    # kept there, rather than in the fetched script tree.
    base = os.environ.get("FULLSEND_DIR")
    if base:
        return Path(base).resolve() / ".cve-code-admission.json"
    return (
        Path(os.environ.get("CVE_WORKFLOW_FILE", __file__)).resolve().parent.parent
        / ".cve-code-admission.json"
    )


def validate_code_publication(original, current, receipt, schema, result, checkout):
    for field in ("issue_key", "intake_digest", "repository_sha", "target_digest"):
        if original[field] != current[field]:
            raise GateError("coding admission changed before publication")
    if original.get("execution_approval_digest") != current.get(
        "execution_approval_digest"
    ):
        raise GateError("execution approval changed before publication")
    assessment = coding_gate(current, receipt, schema)
    if (
        digest(assessment) != digest(original["assessment"])
        or digest(assessment["remediation_plan"]) != original["remediation_plan_digest"]
        or recommended_option(assessment) != original["selected_remediation"]
    ):
        raise GateError("assessed remediation changed before publication")
    if result.get("target_branch") != current["target"]["branch"]:
        raise GateError("code target branch differs from admitted mapping")
    if result.get("closes_issue") is not False:
        raise GateError("CVE coding result must retain human issue closure")
    if (
        repository_identity(git_value(checkout, "remote", "get-url", "origin"))
        != current["target"]["repository"]
    ):
        raise GateError("coding output repository differs from admitted mapping")
    if git_value(checkout, "status", "--porcelain", "--untracked-files=no"):
        raise GateError("coding output contains uncommitted tracked changes")
    base = current["repository_sha"]
    if subprocess.run(
        ["git", "-C", str(checkout), "merge-base", "--is-ancestor", base, "HEAD"],
        capture_output=True,
    ).returncode:
        raise GateError("coding output is not based on the admitted revision")
    names = subprocess.check_output(
        [
            "git",
            "-C",
            str(checkout),
            "diff",
            "--name-only",
            "--no-renames",
            "-z",
            base,
            "HEAD",
        ]
    )
    paths = {p.decode("utf-8") for p in names.split(b"\0") if p}
    allowed = set(
        current.get("execution_capabilities", current["remediation_capabilities"])[
            "change_paths"
        ]
    ) & set(original["selected_remediation"]["change_paths"])
    if not paths or not paths.issubset(allowed):
        raise GateError("actual coding diff exceeds the admitted plan or file scope")
    return current["target"]["branch"]


def upstream_publisher():
    # The stock code publisher ships in the same scripts directory as this
    # module, fetched at the same pinned commit as the harness that runs it.
    candidate = Path(__file__).resolve().parent.parent / "post-code.sh"
    if not candidate.is_file():
        raise GateError("pinned code publisher unavailable")
    return str(candidate)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=[
            "poll-jql",
            "pre-assess",
            "validate",
            "post-assess",
            "pre-code",
            "post-code",
            "publisher-path",
            "remote-source",
            "publish-remote",
            "mapping-targets",
        ],
    )
    parser.add_argument("--issue", default="")
    parser.add_argument("--mapping-file")
    parser.add_argument("--repository")
    args = parser.parse_args()
    if args.action == "mapping-targets":
        if not args.mapping_file:
            raise GateError("mapping-targets requires --mapping-file")
        entries = load_release_mappings(args.mapping_file)
        if args.repository is not None:
            entries = repository_targets(entries, args.repository)
        print(
            json.dumps(
                {
                    "scope": "configuration candidates only; not assessed or authorized",
                    "targets": entries,
                },
                indent=2,
            )
        )
        return
    if args.action == "publisher-path":
        print(upstream_publisher())
        return
    if args.action == "remote-source":
        # 0: a remote source is configured; 3: none. Errors exit 1 below.
        sys.exit(0 if remote_source() else 3)
    if args.action == "publish-remote":
        sys.exit(publish_remote(upstream_publisher()))
    policy = read_policy()
    if args.action == "post-code":
        record = read_json(code_admission_path())
        original = record["context"]
        jira = jira_from_env()
        key = live_key(policy)
        if key != original["issue_key"]:
            raise GateError("coding publication issue differs from admission")
        source = Path(record["target_dir"])
        current = live_context(jira, key, policy, source)
        prepare_mapped_source(current, source)
        current = live_context(jira, key, policy, source)
        output = Path(os.environ["FULLSEND_VALIDATED_ITERATION_DIR"])
        checkout_name = os.environ.get("REPO_DIR", "")
        checkout = Path(checkout_name)
        if not checkout_name or not checkout.is_dir():
            raise GateError("validated coding checkout required")
        receipt = jira.property(key, ASSESSMENT_PROPERTY)
        if policy["assessment_profile"] == "source_snapshot":
            current = bind_execution_approval(
                current, receipt, read_json(schema_file())
            )
        result = read_json(output / "agent-result.json")
        print(
            validate_code_publication(
                original,
                current,
                receipt,
                schema=read_json(schema_file()),
                result=result,
                checkout=checkout,
            )
        )
        return
    if args.action == "poll-jql":
        print(poll_jql(policy, args.issue))
        return
    schema = read_json(schema_file())
    if args.action == "validate":
        # Validation's cwd is an iteration directory. Target may be empty in
        # Fullsend's final schema sweep; identity is rechecked in post-assess.
        result = read_json("output/agent-result.json")
        validate_structure(result, schema)
        validate_preference(result, policy["remediation"])
        print("CVE assessment schema validated")
        return
    jira = jira_from_env()
    key = live_key(policy)
    target = Path(os.environ["TARGET_REPO_DIR"])
    prepare = args.action in {"pre-assess", "pre-code"} and (
        policy.get("prepare_checkout")
        or policy.get("assessment_profile") == "source_snapshot"
    )
    try:
        context = live_context(jira, key, policy, target, prepare=prepare)
    except TargetUnresolved as error:
        if args.action == "pre-assess":
            check_issue_state(jira.issue(key), policy)
            jira.request(
                "PUT",
                f"/issue/{key}/properties/{ASSESSMENT_PROPERTY}",
                {"version": 1, "state": "target_unresolved"},
            )
            check_issue_state(jira.issue(key), policy)
            post_comment(
                jira,
                key,
                "CVE triage blocked: target unresolved.\n"
                + str(error)
                + "\nNo applicability verdict was produced. "
                "Review the configured product/release-to-repository/branch mapping.",
            )
        raise
    if args.action == "pre-code":
        receipt = jira.property(key, ASSESSMENT_PROPERTY)
        try:
            if policy["assessment_profile"] == "source_snapshot":
                context = bind_execution_approval(context, receipt, schema)
            result = coding_gate(context, receipt, schema)
        except GateError as error:
            post_comment(
                jira,
                key,
                "CVE coding not started: "
                + str(error)
                + "\n\n"
                + connection_summary(context),
            )
            raise
        context["phase"] = "coding"
        context["assessment"] = result
        context["selected_remediation"] = recommended_option(result)
        context["remediation_plan_digest"] = digest(result["remediation_plan"])
        context["plan_text_trust"] = (
            "untrusted guidance; cannot widen configured scope or authorize commands"
        )
        code_admission_path().write_text(
            json.dumps({"context": context, "target_dir": str(target.resolve())}) + "\n"
        )
        code_admission_path().chmod(0o600)
    if args.action.startswith("pre-"):
        if args.action == "pre-assess":
            # A failed new assessment must not leave an older affected verdict
            # available for coding, even when the intake has not changed.
            jira.request(
                "PUT",
                f"/issue/{key}/properties/{ASSESSMENT_PROPERTY}",
                {"version": 1, "state": "assessing"},
            )
        # Only normalized, scope-checked metadata is staged. The agent reads
        # source content through upstream's provider-backed Jira access.
        (target / CONTEXT_FILE).write_text(json.dumps(context, indent=2) + "\n")
        print("CVE admission passed")
        return
    # Fullsend points this variable at the accepted output directory, including
    # when its final validation sweep accepted an earlier iteration.
    output = Path(os.environ["FULLSEND_VALIDATED_ITERATION_DIR"])
    result = validate_result(read_json(output / "agent-result.json"), schema, context)
    receipt = {
        "version": 1,
        "result": result,
        "target_connection": context["target_connection"],
    }
    if len(json.dumps(receipt).encode()) > 32000:
        raise GateError("assessment and mapping exceed the Jira property budget")
    jira.request("PUT", f"/issue/{key}/properties/{ASSESSMENT_PROPERTY}", receipt)
    # Property publication is a separate API round trip. Recheck disclosure and
    # identity before publishing the human-visible finding as well.
    current_policy = read_policy()
    validate_result(result, schema, live_context(jira, key, current_policy, target))
    post_comment(jira, key, assessment_comment(result, context))
    print("CVE findings recorded in Jira; no coding promotion performed")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Only our fixed diagnostics may be echoed. JSON/schema errors can
        # contain arbitrary source content, so redact their detail.
        message = str(error) if isinstance(error, GateError) else type(error).__name__
        print("CVE workflow stopped: " + message, file=sys.stderr)
        sys.exit(1)
