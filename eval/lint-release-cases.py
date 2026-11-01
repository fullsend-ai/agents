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
import sys

import yaml


class AnnotationLoader(yaml.SafeLoader):
    """Preserve aliases as distinct nodes instead of resolving release markers."""

    def compose_node(self, parent, index):
        alias = self.peek_event() if self.check_event(yaml.AliasEvent) else None
        node = super().compose_node(parent, index)
        if alias:
            return yaml.ScalarNode("!alias", "", alias.start_mark, alias.end_mark)
        return node


def has_release_marker(node) -> bool:
    if not isinstance(node, yaml.MappingNode):
        return False
    # Do not infer release coverage through YAML merge keys.
    if any(key.tag == "tag:yaml.org,2002:merge" for key, _ in node.value):
        return False
    markers = [value for key, value in node.value
               if key.tag == "tag:yaml.org,2002:str" and key.value == "release"]
    if len(markers) != 1:
        return False
    value = markers[0]
    return (isinstance(value, yaml.ScalarNode)
            and value.tag == "tag:yaml.org,2002:bool"
            and value.value == "true")


def main() -> int:
    repo_root = Path(os.environ.get("REPO_ROOT", Path(__file__).resolve().parent.parent))
    errors = 0
    manifests = [
        manifest for manifest in sorted((repo_root / "eval").glob("*/eval.yaml"))
        if not manifest.parent.name.startswith(".")
    ]
    if not manifests:
        print("ERROR: no eval/*/eval.yaml manifests found", file=sys.stderr)
        return 1
    for manifest in manifests:
        release_cases = 0
        for annotations in sorted(manifest.parent.glob("cases/*/annotations.yaml")):
            if annotations.parent.name.startswith("."):
                continue
            try:
                data = yaml.compose(annotations.read_text(encoding="utf-8"), Loader=AnnotationLoader)
            except (OSError, UnicodeError, yaml.YAMLError) as error:
                print(f"ERROR: {annotations.relative_to(repo_root)}: {error}", file=sys.stderr)
                errors += 1
                continue
            if has_release_marker(data):
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
