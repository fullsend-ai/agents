"""Bounded controller-owned version knowledge; no executable skill installation."""

import hashlib
import http.client
from pathlib import Path
import re
import urllib.error
import urllib.request

from text_safety import has_hidden_text

MAX_SKILLS = 4
MAX_SKILL_BYTES = 16384
MAX_TOTAL_BYTES = 32768
REMOTE_SOURCE = re.compile(
    r"https://raw\.githubusercontent\.com/"
    r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[a-f0-9]{40}/"
    r"(?:[A-Za-z0-9_.-]+/)*SKILL\.md"
)
REMOTE_PREFIX = re.compile(
    r"https://raw\.githubusercontent\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/"
)


class VersionSkillError(ValueError):
    """Fixed, non-sensitive diagnostics safe for host publication."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_references(references):
    if not isinstance(references, list) or len(references) > MAX_SKILLS:
        raise VersionSkillError("version_skills must be a list of at most four sources")
    seen = set()
    for item in references:
        if not isinstance(item, dict) or not {"source"} <= set(item) <= {
            "source",
            "sha256",
        }:
            raise VersionSkillError("version skill requires source and optional sha256")
        source = item["source"]
        if not isinstance(source, str) or len(source) > 512 or source in seen:
            raise VersionSkillError("version skill sources must be bounded and unique")
        seen.add(source)
        pin = item.get("sha256")
        if "sha256" in item and (
            not isinstance(pin, str) or not re.fullmatch(r"[a-f0-9]{64}", pin)
        ):
            raise VersionSkillError(
                "version skill sha256 must be a lowercase SHA-256 digest"
            )
        if source.startswith("https://"):
            if not REMOTE_SOURCE.fullmatch(source) or pin is None:
                raise VersionSkillError(
                    "remote version skills require a raw GitHub commit URL and sha256"
                )
            parts = source.removeprefix("https://").split("/")
        else:
            path = Path(source)
            parts = path.parts
            if (
                path.is_absolute()
                or path.as_posix() != source
                or not source.startswith("skills/")
                or path.name != "SKILL.md"
                or not re.fullmatch(r"[A-Za-z0-9_./-]+", source)
            ):
                raise VersionSkillError(
                    "local version skills must be canonical skills/.../SKILL.md paths"
                )
        if any(part in {".", ".."} for part in parts):
            raise VersionSkillError("version skill paths cannot traverse directories")


def validate_prefixes(prefixes):
    if (
        not isinstance(prefixes, list)
        or len(prefixes) > 16
        or any(
            not isinstance(p, str)
            or not REMOTE_PREFIX.fullmatch(p)
            or any(
                part in {".", ".."} for part in p.removeprefix("https://").split("/")
            )
            for p in prefixes
        )
    ):
        raise VersionSkillError(
            "version_skill_sources must list approved raw GitHub repository URL prefixes"
        )


def resolve(references, controller_root, prefixes):
    validate_references(references)
    validate_prefixes(prefixes)
    skills, total = [], 0
    root = Path(controller_root).resolve()
    for item in references:
        source = item["source"]
        try:
            if source.startswith("https://"):
                if not any(source.startswith(p) for p in prefixes):
                    raise VersionSkillError(
                        "remote version skill repository is not approved"
                    )
                # No credentials, query parameters, redirects or environment expansion.
                request = urllib.request.Request(
                    source, headers={"Accept": "text/plain"}
                )
                with urllib.request.build_opener(NoRedirect()).open(
                    request, timeout=8
                ) as response:
                    raw = response.read(MAX_SKILL_BYTES + 1)
            else:
                path = root / source
                if (
                    path.resolve().relative_to(root).as_posix() != source
                    or not path.is_file()
                ):
                    raise VersionSkillError(
                        "local version skill is missing or redirected"
                    )
                with path.open("rb") as handle:
                    raw = handle.read(MAX_SKILL_BYTES + 1)
        except VersionSkillError:
            raise
        except (
            OSError,
            ValueError,
            RuntimeError,
            urllib.error.URLError,
            http.client.HTTPException,
        ):
            raise VersionSkillError(
                "configured version skill could not be read"
            ) from None
        total += len(raw)
        if not raw or len(raw) > MAX_SKILL_BYTES or total > MAX_TOTAL_BYTES:
            raise VersionSkillError(
                "version skill content exceeds the bounded knowledge budget or is empty"
            )
        sha = hashlib.sha256(raw).hexdigest()
        if item.get("sha256", sha) != sha:
            raise VersionSkillError(
                "version skill content does not match its sha256 pin"
            )
        try:
            content = raw.decode("utf-8")
        except UnicodeError:
            raise VersionSkillError("version skills must be UTF-8 text") from None
        if "\x00" in content or not content.strip():
            raise VersionSkillError(
                "version skills must contain nonempty text without NUL bytes"
            )
        if has_hidden_text(content):
            raise VersionSkillError(
                "version skills contain hidden or directional control text"
            )
        skills.append({"source": source, "sha256": sha, "content": content})
    return skills
