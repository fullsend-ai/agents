#!/usr/bin/env bash
# Lint eval/measurements/*.yaml — catch typos that would silently no-op
# at runtime (unknown scorer / agent name that never matches a trace).
#
# bash 3.2 compatible (macOS /usr/bin/bash). Validation runs in python3;
# this wrapper does not use mapfile or declare -A.
#
# Usage:
#   ./eval/lint-measurements.sh
#
# Checks:
#   - Filename stem equals the top-level `agent:` field
#   - `agent:` matches an existing agents/<name>.md
#   - Each measurement has id, scorer, and a positive integer version
#   - ids are unique per file
#   - scorer is in the known-scorer allow-list (fullsend evalmeasure registry)
#   - id matches em-001-style lowercase — agents-repo stock-manifest style,
#     stricter than fullsend LoadRegistry (which only requires a non-empty id
#     without pipe/newline)
#   - YAML must be the shipped block-style three-field shape; other shapes
#     fail closed as "unsupported YAML shape"
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MEASUREMENTS_DIR="${MEASUREMENTS_DIR:-$REPO_ROOT/eval/measurements}"
AGENTS_DIR="${AGENTS_DIR:-$REPO_ROOT/agents}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required" >&2
  exit 1
fi

# Command substitution (not process substitution) so python's exit code is visible.
python3 - "$MEASUREMENTS_DIR" "$AGENTS_DIR" <<'PY'
import os
import re
import sys

MEASUREMENTS_DIR, AGENTS_DIR = sys.argv[1], sys.argv[2]
KNOWN_SCORERS = frozenset({"trace_fitness"})
ID_STYLE = re.compile(r"^[a-z][a-z0-9]*-[0-9]+$")
FIELD_KEYS = frozenset({"id", "scorer", "version"})


class UnsupportedShape(Exception):
    pass


def parse_manifest(text):
    """Parse the shipped block-style schema. Raise UnsupportedShape otherwise."""
    agent = None
    items = []
    current = None
    in_measurements = False
    measurements_key = False
    list_indent = None

    for raw in text.splitlines():
        stripped = raw.split("#", 1)[0].rstrip()
        if not stripped or stripped == "---":
            continue
        if re.search(r"measurements:\s*[\[{]", stripped):
            raise UnsupportedShape("flow-style measurements are not supported")
        indent = len(raw) - len(raw.lstrip(" "))
        if re.match(r"^agent:\s*\S", stripped):
            agent = stripped.split(":", 1)[1].strip().strip("'\"")
            continue
        if re.match(r"^measurements:\s*$", stripped):
            in_measurements = True
            measurements_key = True
            continue
        if in_measurements and re.match(r"^-\s+", stripped.lstrip()):
            dash_indent = indent
            if list_indent is None:
                list_indent = dash_indent
            if dash_indent > (list_indent or 0) and current is not None:
                raise UnsupportedShape("nested list under a measurement is not supported")
            if current is not None:
                items.append(current)
            current = {}
            rest = re.sub(r"^-\s+", "", stripped.lstrip())
            m = re.match(r"(id|scorer|version):\s*(.*)$", rest)
            if rest and not m:
                raise UnsupportedShape("unsupported field on measurement list item")
            if m:
                current[m.group(1)] = m.group(2).strip().strip("'\"")
            continue
        if in_measurements and current is not None:
            fm = re.match(r"^\s+(id|scorer|version):\s*(.*)$", stripped)
            um = re.match(r"^\s+([A-Za-z0-9_]+):\s*(.*)$", stripped)
            if fm:
                current[fm.group(1)] = fm.group(2).strip().strip("'\"")
                continue
            if um and um.group(1) not in FIELD_KEYS:
                raise UnsupportedShape("unsupported field %r" % um.group(1))
            if re.match(r"^\S", stripped):
                in_measurements = False
                items.append(current)
                current = None
                continue
            raise UnsupportedShape("unrecognized line in measurements list")
        if re.match(r"^\S", stripped) and stripped.split(":", 1)[0] not in ("agent", "measurements"):
            raise UnsupportedShape("unsupported top-level field %r" % stripped.split(":", 1)[0])

    if current is not None:
        items.append(current)
    if measurements_key and not items:
        raise UnsupportedShape("measurements present but no block-style items parsed")
    return agent, items


def main():
    print("Checking measurement manifests...")
    print("================================================")
    errors = 0
    file_count = 0

    try:
        names = sorted(n for n in os.listdir(MEASUREMENTS_DIR) if n.endswith(".yaml"))
    except OSError:
        names = []

    for name in names:
        file_count += 1
        path = os.path.join(MEASUREMENTS_DIR, name)
        stem = name[:-5]
        try:
            text = open(path, encoding="utf-8").read()
            agent, items = parse_manifest(text)
        except UnsupportedShape as e:
            print("  ERROR: %s: unsupported YAML shape (%s)" % (name, e))
            errors += 1
            continue
        except Exception as e:
            print("  ERROR: %s: parser failed: %s" % (name, e))
            errors += 1
            continue

        file_errors = 0
        if not agent:
            print("  ERROR: %s: missing 'agent:' field" % name)
            errors += 1
            continue
        if agent != stem:
            print("  ERROR: %s: agent %r does not match filename stem %r (jobs fetch ${AGENT}.yaml)" % (name, agent, stem))
            errors += 1
            file_errors += 1
        if not os.path.isfile(os.path.join(AGENTS_DIR, agent + ".md")):
            print("  ERROR: %s: agent %r has no agents/%s.md" % (name, agent, agent))
            errors += 1
            file_errors += 1
        if not items:
            print("  ERROR: %s: measurements list is empty" % name)
            errors += 1
            continue

        seen = set()
        for idx, it in enumerate(items, 1):
            mid = it.get("id", "")
            scorer = it.get("scorer", "")
            version = it.get("version", "")
            if not mid:
                print("  ERROR: %s: measurement #%d missing id" % (name, idx))
                errors += 1
                file_errors += 1
                continue
            if "|" in mid or "\n" in mid:
                print("  ERROR: %s: id %r contains characters fullsend LoadRegistry rejects" % (name, mid))
                errors += 1
                file_errors += 1
            if not ID_STYLE.match(mid):
                print("  ERROR: %s: id %r must be lowercase like em-001 (agents-repo stock-manifest style)" % (name, mid))
                errors += 1
                file_errors += 1
            if mid in seen:
                print("  ERROR: %s: duplicate id %r" % (name, mid))
                errors += 1
                file_errors += 1
            seen.add(mid)
            if not scorer:
                print("  ERROR: %s: measurement %r missing scorer" % (name, mid))
                errors += 1
                file_errors += 1
            elif scorer not in KNOWN_SCORERS:
                print("  ERROR: %s: unknown scorer %r (allowed: %s)" % (name, scorer, ", ".join(sorted(KNOWN_SCORERS))))
                errors += 1
                file_errors += 1
            if not re.match(r"^[1-9][0-9]*$", version or ""):
                print("  ERROR: %s: measurement %r version must be a positive integer, got %r" % (name, mid, version))
                errors += 1
                file_errors += 1

        if file_errors == 0:
            print("  %s: OK (agent=%s, %d measurement(s))" % (name, agent, len(items)))

    if file_count == 0:
        print("  ERROR: no eval/measurements/*.yaml files found — expected at least one")
        errors += 1

    print("")
    if errors:
        print("ERROR: %d measurement lint failures" % errors, file=sys.stderr)
        return 1
    print("OK: all measurement manifests pass lint checks")
    return 0


sys.exit(main())
PY
