#!/usr/bin/env python3
"""Check that fix-agent actions cover every structured review finding.

Parses ``- **[category]**`` bullets from the raw review body (not the
agent's restated summary) and requires each occurrence to appear as
``[category]`` in some ``actions[].finding`` value. Extra actions
(rebase, squash, CI) are allowed in addition to per-finding actions.
Each action's finding text credits at most one tag — its first ``[tag]``
token — so one action cannot cover multiple findings by mentioning
several bracketed tags in prose.

``<details>`` blocks (prior-iteration recap) and HTML comments are
stripped before parsing so stale tags cannot inflate the required set.

Exit codes:
    0 — coverage OK, or nothing to check (no structured findings)
    1 — uncovered findings, or unreadable input
"""

from __future__ import annotations

import json
import re
import sys
from collections import Counter

FINDING_BULLET = re.compile(
    r"^[ \t]*-[ \t]+\*\*\[([^\]]+)\]\*\*",
    re.MULTILINE,
)

DETAILS_BLOCK = re.compile(
    r"<details\b[^>]*>.*?</details>",
    re.DOTALL | re.IGNORECASE,
)

HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)


def strip_ignored(text: str) -> str:
    """Remove prior-iteration recap and HTML comments from review text."""
    prev = None
    while prev != text:
        prev = text
        text = DETAILS_BLOCK.sub("", text)
    return HTML_COMMENT.sub("", text)


def parse_finding_tags(review_body: str) -> list[str]:
    """Return the category tags of structured finding bullets, lowercased."""
    cleaned = strip_ignored(review_body)
    tags = []
    for match in FINDING_BULLET.finditer(cleaned):
        tag = match.group(1).strip().lower()
        if tag:
            tags.append(tag)
    return tags


FINDING_TAG_TOKEN = re.compile(r"\[([^\]]+)\]")


def tags_in_finding(finding: str, tags: set[str]) -> list[str]:
    """Return the tag covered by an action finding label, if any.

    Only the *first* ``[tag]`` token in the finding text counts. A finding
    string that mentions multiple bracketed tags in prose (e.g. "the only
    real issue is [protected-path]; [stale-docs] is not a real defect")
    must not be allowed to satisfy more than one required finding from a
    single action — each finding still needs its own action.
    """
    match = FINDING_TAG_TOKEN.search(finding or "")
    if not match:
        return []
    tag = match.group(1).strip().lower()
    return [tag] if tag in tags else []


def coverage(review_body: str, actions: list) -> tuple[Counter, Counter]:
    """Return (needed, covered) tag multisets."""
    needed_list = parse_finding_tags(review_body)
    needed: Counter = Counter(needed_list)
    unique = set(needed)
    covered: Counter = Counter()
    for action in actions:
        if not isinstance(action, dict):
            continue
        finding = action.get("finding") or ""
        if not isinstance(finding, str):
            continue
        for tag in tags_in_finding(finding, unique):
            covered[tag] += 1
    return needed, covered


def uncovered(needed: Counter, covered: Counter) -> list[tuple[str, int]]:
    """Return (tag, missing_count) for tags short of the needed multiplicity."""
    missing = []
    for tag, count in needed.items():
        got = covered[tag]
        if got < count:
            missing.append((tag, count - got))
    return missing


def check_coverage(review_body: str, actions: list) -> tuple[bool, str]:
    """Return (ok, message). ok is True on pass or skip."""
    needed, covered = coverage(review_body, actions)
    if not needed:
        return True, "PASS: no structured findings in review body — skipping finding coverage"
    missing = uncovered(needed, covered)
    total = sum(needed.values())
    if not missing:
        return True, f"PASS: all {total} review findings covered by actions"
    parts = [f"[{tag}] x{n}" for tag, n in missing]
    lines = [
        "FAIL: review findings not covered by actions: " + ", ".join(parts),
        f"  parsed {total} finding(s) from review body",
    ]
    covered_parts = [f"[{tag}] x{n}" for tag, n in covered.items() if n]
    if covered_parts:
        lines.append("  covered: " + ", ".join(covered_parts))
    else:
        lines.append("  covered: none")
    return False, "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if len(argv) != 2:
        print(
            "Usage: review-finding-coverage.py <result.json> <review-body.txt>",
            file=sys.stderr,
        )
        return 1

    result_path, body_path = argv

    try:
        with open(body_path, encoding="utf-8") as handle:
            body = handle.read()
    except OSError as exc:
        print(f"FAIL: cannot read review body {body_path}: {exc}")
        return 1

    if not body.strip():
        print("PASS: review body empty — skipping finding coverage")
        return 0

    try:
        with open(result_path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: cannot read result {result_path}: {exc}")
        return 1

    actions = data.get("actions") or []
    if not isinstance(actions, list):
        actions = []

    ok, message = check_coverage(body, actions)
    print(message)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
