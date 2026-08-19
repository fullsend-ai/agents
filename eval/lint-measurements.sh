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
# Checks (mirrored LoadRegistry rules + agents-repo style extras):
#   - Filename stem equals the top-level `agent:` field
#   - `agent:` matches an existing agents/<name>.md
#     (necessary but not sufficient for stock fetch: fullsend only pulls
#     agents in defaultAgentsRepoKnownAgents — triage/code/fix/review/
#     retro/prioritize today; see measurements README)
#   - Each measurement has id, scorer, and a positive unquoted integer version
#     (LoadRegistry: Version is int — quoted "1" fails yaml.v3)
#   - optional name: allowed; rejects pipe/newline in id/scorer/name
#   - ids unique per file; no duplicate top-level agent:/measurements:
#   - scorer in known-scorer allow-list (fullsend ScorerFitness)
#   - id matches em-001-style lowercase (agents-repo style, not LoadRegistry)
#   - YAML comment stripping matches YAML (# only after whitespace / col 0);
#     residual # inside agent/id/scorer/name values is rejected
#   - Shipped block-style shape only; other shapes fail closed
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
# Matches fullsend MeasurementSpec yaml tags shipped today (id/scorer/version/name).
FIELD_KEYS = frozenset({"id", "scorer", "version", "name"})
TOP_LEVEL_KEYS = frozenset({"agent", "measurements"})
FIELD_INLINE = re.compile(r"^(id|scorer|version|name):\s*(.*)$")
FIELD_INDENTED = re.compile(r"^\s+(id|scorer|version|name):\s*(.*)$")
UNKNOWN_INDENTED = re.compile(r"^\s+([A-Za-z0-9_]+):\s*(.*)$")


class UnsupportedShape(Exception):
    pass


def strip_yaml_comment(raw):
    """Strip a YAML comment: '#' only at column 0 or after whitespace."""
    return re.split(r"(?:^|\s)#", raw, maxsplit=1)[0].rstrip()


def parse_scalar(key, raw_token):
    """Parse a scalar the way LoadRegistry / yaml.v3 expects for this schema."""
    token = raw_token.strip()
    if key == "version":
        # MeasurementSpec.Version is int; yaml.v3 rejects !!str ("1" / '1').
        if (len(token) >= 2 and token[0] == token[-1] and token[0] in "\"'"):
            raise UnsupportedShape(
                "version must be an unquoted integer (LoadRegistry int field), got %r" % token
            )
        if not re.match(r"^[1-9][0-9]*$", token):
            raise UnsupportedShape("version must be a positive integer, got %r" % token)
        return token
    if len(token) >= 2 and token[0] == token[-1] and token[0] in "\"'":
        token = token[1:-1]
    if "#" in token:
        raise UnsupportedShape(
            "%s value must not contain '#' (got %r); YAML treats it as part of the scalar"
            % (key, token)
        )
    return token


def require_top_level(stripped):
    key = stripped.split(":", 1)[0]
    if key not in TOP_LEVEL_KEYS:
        raise UnsupportedShape("unsupported top-level field %r" % key)
    return key


def parse_manifest(text):
    """Parse the shipped block-style schema. Raise UnsupportedShape otherwise."""
    agent = None
    items = []
    current = None
    in_measurements = False
    measurements_key = False
    list_indent = None
    seen_top = set()

    def close_current():
        nonlocal current
        if current is not None:
            items.append(current)
            current = None

    def note_top(key):
        if key in seen_top:
            raise UnsupportedShape("duplicate top-level key %r (yaml.v3 rejects this)" % key)
        seen_top.add(key)

    def set_agent(stripped):
        nonlocal agent
        note_top("agent")
        agent = parse_scalar("agent", stripped.split(":", 1)[1])

    def start_measurements():
        nonlocal in_measurements, measurements_key, list_indent
        note_top("measurements")
        in_measurements = True
        measurements_key = True
        list_indent = None

    for raw in text.splitlines():
        stripped = strip_yaml_comment(raw)
        if not stripped or stripped == "---":
            continue
        if re.search(r"measurements:\s*[\[{]", stripped):
            raise UnsupportedShape("flow-style measurements are not supported")
        indent = len(raw) - len(raw.lstrip(" "))

        if re.match(r"^agent:\s*\S", stripped):
            if in_measurements:
                close_current()
                in_measurements = False
            set_agent(stripped)
            continue

        if re.match(r"^measurements:\s*$", stripped):
            if in_measurements:
                close_current()
            start_measurements()
            continue

        if in_measurements and re.match(r"^-\s+", stripped.lstrip()):
            dash_indent = indent
            if list_indent is None:
                list_indent = dash_indent
            if dash_indent > (list_indent or 0) and current is not None:
                raise UnsupportedShape("nested list under a measurement is not supported")
            close_current()
            current = {}
            rest = re.sub(r"^-\s+", "", stripped.lstrip())
            m = FIELD_INLINE.match(rest)
            if rest and not m:
                raise UnsupportedShape("unsupported field on measurement list item")
            if m:
                current[m.group(1)] = parse_scalar(m.group(1), m.group(2))
            continue

        if in_measurements and current is not None:
            fm = FIELD_INDENTED.match(stripped)
            um = UNKNOWN_INDENTED.match(stripped)
            if fm:
                current[fm.group(1)] = parse_scalar(fm.group(1), fm.group(2))
                continue
            if um and um.group(1) not in FIELD_KEYS:
                raise UnsupportedShape("unsupported field %r" % um.group(1))
            if re.match(r"^\S", stripped):
                close_current()
                in_measurements = False
                key = require_top_level(stripped)
                if key == "agent":
                    set_agent(stripped)
                elif key == "measurements":
                    start_measurements()
                continue
            raise UnsupportedShape("unrecognized line in measurements list")

        if in_measurements and current is None:
            if re.match(r"^\S", stripped):
                in_measurements = False
                key = require_top_level(stripped)
                if key == "agent":
                    set_agent(stripped)
                elif key == "measurements":
                    start_measurements()
                continue
            raise UnsupportedShape("indented content outside a measurement item")

        if re.match(r"^\S", stripped):
            require_top_level(stripped)
            continue
        raise UnsupportedShape("indented content outside measurements list")

    close_current()
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
            display = it.get("name", "")
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
            elif "|" in scorer or "\n" in scorer:
                print("  ERROR: %s: scorer %r contains characters fullsend LoadRegistry rejects" % (name, scorer))
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
            if display and ("|" in display or "\n" in display):
                print("  ERROR: %s: name %r contains characters fullsend LoadRegistry rejects" % (name, display))
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
