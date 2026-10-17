#!/usr/bin/env python3
"""Require release coverage for every evaluated agent.

Usage:
    python3 eval/lint-release-cases.py

Checks:
    Every eval/*/eval.yaml has at least one case whose annotations.yaml
    contains a top-level boolean release: true.

Requires Python 3 and PyYAML.
REPO_ROOT overrides the repository path for fixture tests.

Exit codes:
    0 — all discovered agents have release coverage
    1 — missing coverage or an annotation read/parse error
"""

import os
from pathlib import Path
import re
import sys

import yaml


class AnnotationLoader(yaml.SafeLoader):
    """Accept lowercase booleans, matching the release runner’s selection."""


AnnotationLoader.yaml_implicit_resolvers = {
    key: [(tag, pattern) for tag, pattern in resolvers
          if tag != "tag:yaml.org,2002:bool"]
    for key, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}
AnnotationLoader.add_implicit_resolver(
    "tag:yaml.org,2002:bool", re.compile(r"^(?:true|false)$"),
    list("tf"),
)

# Explicit boolean tags bypass implicit resolvers; preserve the runner's spelling check.
AnnotationLoader.add_constructor(
    "tag:yaml.org,2002:bool", lambda loader, node: loader.construct_scalar(node) == "true",
)


def main() -> int:
    repo_root = Path(os.environ.get("REPO_ROOT", Path(__file__).resolve().parent.parent))
    errors = 0
    manifests = sorted((repo_root / "eval").glob("*/eval.yaml"))
    if not manifests:
        print("ERROR: no eval/*/eval.yaml manifests found", file=sys.stderr)
        return 1
    for manifest in manifests:
        release_cases = 0
        for annotations in sorted(manifest.parent.glob("cases/*/annotations.yaml")):
            if annotations.parent.name.startswith("."):
                continue
            try:
                data = yaml.load(annotations.read_text(), Loader=AnnotationLoader)
            except (OSError, UnicodeError, yaml.YAMLError) as error:
                print(f"ERROR: {annotations.relative_to(repo_root)}: {error}", file=sys.stderr)
                errors += 1
                continue
            if isinstance(data, dict) and data.get("release") is True:
                release_cases += 1
        if not release_cases:
            print(
                f"ERROR: {manifest.relative_to(repo_root)}: no release-tier case; "
                "set boolean release: true in at least one cases/*/annotations.yaml",
                file=sys.stderr,
            )
            errors += 1
        else:
            print(f"{manifest.parent.name}: OK ({release_cases} release-tier case(s))")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
