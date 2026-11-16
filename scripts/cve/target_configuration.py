"""Parse grouped target directories into one shared source-target list."""

import json
from pathlib import Path
import re
from text_safety import has_hidden_text


class MappingConfigError(ValueError):
    """Bounded configuration diagnostics; never echo arbitrary file contents."""


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise MappingConfigError(
                "mapping configuration requires unique string keys; quote YAML versions"
            )
        result[key] = value
    return result


def read(path):
    try:
        with Path(path).open("rb") as handle:
            raw = handle.read(1048577)
        if len(raw) > 1048576:
            raise MappingConfigError("mapping configuration exceeds 1 MiB")
        text = raw.decode("utf-8")
        if Path(path).suffix.lower() not in {".yaml", ".yml"}:
            return json.loads(text, object_pairs_hook=unique_pairs)
        try:
            import yaml
        except ImportError:
            raise MappingConfigError(
                "YAML mappings require PyYAML; install requirements-dev.txt"
            ) from None

        class UniqueSafeLoader(yaml.SafeLoader):
            pass

        def mapping(loader, node):
            return unique_pairs(
                (loader.construct_object(k), loader.construct_object(v))
                for k, v in node.value
            )

        UniqueSafeLoader.add_constructor(
            yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping
        )
        try:
            return yaml.load(text, Loader=UniqueSafeLoader)
        except yaml.YAMLError:
            raise MappingConfigError("invalid YAML mapping configuration") from None
    except MappingConfigError:
        raise
    except (OSError, UnicodeError, ValueError, TypeError):
        raise MappingConfigError(
            "mapping configuration could not be read or parsed"
        ) from None


def validate_jira(value):
    if not isinstance(value, dict) or set(value) - {"project", "affected_version"}:
        raise MappingConfigError(
            "jira mapping supports project and affected_version only"
        )
    for key, text in value.items():
        if (
            not isinstance(text, str)
            or not text
            or len(text) > 256
            or has_hidden_text(text)
            or any(c in "\n\r\t" for c in text)
        ):
            raise MappingConfigError(
                "jira mapping values must be bounded nonempty text"
            )
        if key == "project" and not re.fullmatch(r"[A-Z][A-Z0-9_]{1,31}", text):
            raise MappingConfigError("jira project must be a project key")


def validate_upstream(value):
    """Optional component lineage; dependency identities and recipes are discovered."""
    if not isinstance(value, dict) or set(value) != {"repository", "ref"}:
        raise MappingConfigError("upstream requires repository and ref only")
    repository, ref = value["repository"], value["ref"]
    if (
        not isinstance(repository, str)
        or len(repository) > 256
        or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
        or any(part in {".", ".."} for part in repository.split("/"))
    ):
        raise MappingConfigError(
            "upstream repository must be a GitHub owner/repository identity"
        )
    if (
        not isinstance(ref, str)
        or len(ref) > 256
        or not re.fullmatch(
            r"(?:refs/(?:heads|tags)/[A-Za-z0-9][A-Za-z0-9._/+-]*|[a-f0-9]{40})", ref
        )
        or ".." in ref
        or "//" in ref
        or "@{" in ref
        or any(
            part.startswith(".") or part.endswith((".", ".lock"))
            for part in ref.split("/")
        )
        or ref.endswith("/")
    ):
        raise MappingConfigError(
            "upstream ref must be an explicit branch/tag ref or full commit"
        )


def entries(data):
    if not isinstance(data, dict) or type(data.get("version")) is not int:
        raise MappingConfigError(
            "mapping configuration requires an integer format version"
        )
    if data["version"] != 2:
        raise MappingConfigError(
            "mapping format version must be 2 (grouped products.<product>.versions); see docs/multi-version-mapping.md"
        )
    if (
        set(data) != {"version", "products"}
        or not isinstance(data["products"], dict)
        or not data["products"]
    ):
        raise MappingConfigError(
            "grouped version 2 requires a nonempty products object only"
        )
    result = []
    allowed = {
        "id",
        "repository",
        "branch",
        "stream",
        "component",
        "manifest",
        "manifest_format",
        "manifest_identity",
        "owner",
        "evidence",
        "version_skills",
        "upstream",
        "jira",
    }
    for product, defaults in data["products"].items():
        if (
            not isinstance(defaults, dict)
            or set(defaults) - {"repository", "jira", "versions"}
            or not isinstance(defaults.get("versions"), dict)
            or not defaults["versions"]
        ):
            raise MappingConfigError(
                "each product requires versions and optional repository/jira defaults"
            )
        jira = defaults.get("jira", {})
        validate_jira(jira)
        if set(jira) - {"project"}:
            raise MappingConfigError(
                "product jira defaults may contain project only; affected_version is per version"
            )
        for version, specific in defaults["versions"].items():
            if not isinstance(product, str) or not isinstance(version, str):
                raise MappingConfigError(
                    "product and version names must be strings; quote YAML versions"
                )
            if not isinstance(specific, dict) or set(specific) - allowed:
                raise MappingConfigError("version target has unsupported fields")
            if "upstream" in specific:
                validate_upstream(specific["upstream"])
            entry = {"product": product, "version": version}
            if "repository" in defaults:
                entry["repository"] = defaults["repository"]
            entry.update(specific)
            version_jira = specific.get("jira", {})
            validate_jira(version_jira)
            if "jira" in defaults or "jira" in specific:
                entry["jira"] = {**jira, **version_jira}
            result.append(entry)
    return result
