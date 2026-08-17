#!/usr/bin/env bash
# Lint eval/measurements/*.yaml — catch typos that would silently no-op
# at runtime (unknown scorer / agent name that never matches a trace).
#
# Usage:
#   ./eval/lint-measurements.sh
#
# Checks:
#   - Filename stem equals the top-level `agent:` field
#   - `agent:` matches an existing agents/<name>.md
#   - Each measurement has id, scorer, and a positive integer version
#   - ids are unique per file and match em-001-style lowercase
#   - scorer is in the known-scorer allow-list (fullsend evalmeasure registry)
set -euo pipefail
shopt -s nullglob

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MEASUREMENTS_DIR="${MEASUREMENTS_DIR:-$REPO_ROOT/eval/measurements}"
AGENTS_DIR="${AGENTS_DIR:-$REPO_ROOT/agents}"

# Keep in sync with fullsend internal/evalmeasure ScorerFitness.
KNOWN_SCORERS="trace_fitness"

errors=0
file_count=0

echo "Checking measurement manifests..."
echo "================================================"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required" >&2
  exit 1
fi

parse_manifest() {
  python3 - "$1" <<'PY'
import re, sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
agent = None
items = []
current = None
in_measurements = False

for raw in text.splitlines():
    line = raw.split("#", 1)[0].rstrip()
    if not line.strip() or line.strip() == "---":
        continue
    if re.match(r"^agent:\s*\S", line):
        agent = line.split(":", 1)[1].strip().strip("'\"")
        continue
    if re.match(r"^measurements:\s*$", line):
        in_measurements = True
        continue
    if in_measurements and re.match(r"^\s*-\s+", line):
        if current is not None:
            items.append(current)
        current = {}
        rest = re.sub(r"^\s*-\s+", "", line)
        m = re.match(r"(id|scorer|version):\s*(.*)$", rest)
        if m:
            current[m.group(1)] = m.group(2).strip().strip("'\"")
        continue
    if in_measurements and current is not None:
        m = re.match(r"^\s+(id|scorer|version):\s*(.*)$", line)
        if m:
            current[m.group(1)] = m.group(2).strip().strip("'\"")
            continue
        if re.match(r"^\S", line):
            in_measurements = False
            items.append(current)
            current = None

if current is not None:
    items.append(current)

print(agent or "")
print(len(items))
for it in items:
    print(it.get("id", ""))
    print(it.get("scorer", ""))
    print(it.get("version", ""))
PY
}

for yaml_file in "$MEASUREMENTS_DIR"/*.yaml; do
  file_count=$((file_count + 1))
  name="$(basename "$yaml_file")"
  stem="${name%.yaml}"

  mapfile -t parsed < <(parse_manifest "$yaml_file")
  agent="${parsed[0]:-}"
  count="${parsed[1]:-0}"

  file_errors=0

  if [[ -z "$agent" ]]; then
    echo "  ERROR: $name: missing 'agent:' field"
    errors=$((errors + 1))
    continue
  fi

  if [[ "$agent" != "$stem" ]]; then
    echo "  ERROR: $name: agent '$agent' does not match filename stem '$stem' (jobs fetch \${AGENT}.yaml)"
    errors=$((errors + 1))
    file_errors=$((file_errors + 1))
  fi

  if [[ ! -f "$AGENTS_DIR/${agent}.md" ]]; then
    echo "  ERROR: $name: agent '$agent' has no agents/${agent}.md"
    errors=$((errors + 1))
    file_errors=$((file_errors + 1))
  fi

  if [[ "$count" -lt 1 ]]; then
    echo "  ERROR: $name: measurements list is empty"
    errors=$((errors + 1))
    continue
  fi

  declare -A seen_ids=()
  idx=0
  while [[ $idx -lt $count ]]; do
    base=$((2 + idx * 3))
    mid="${parsed[$base]:-}"
    scorer="${parsed[$((base + 1))]:-}"
    version="${parsed[$((base + 2))]:-}"
    idx=$((idx + 1))

    if [[ -z "$mid" ]]; then
      echo "  ERROR: $name: measurement #$idx missing id"
      errors=$((errors + 1))
      file_errors=$((file_errors + 1))
      continue
    fi
    if [[ ! "$mid" =~ ^[a-z][a-z0-9]*-[0-9]+$ ]]; then
      echo "  ERROR: $name: id '$mid' must be lowercase like em-001"
      errors=$((errors + 1))
      file_errors=$((file_errors + 1))
    fi
    if [[ -n "${seen_ids[$mid]+x}" ]]; then
      echo "  ERROR: $name: duplicate id '$mid'"
      errors=$((errors + 1))
      file_errors=$((file_errors + 1))
    fi
    seen_ids["$mid"]=1

    if [[ -z "$scorer" ]]; then
      echo "  ERROR: $name: measurement '$mid' missing scorer"
      errors=$((errors + 1))
      file_errors=$((file_errors + 1))
    elif [[ " $KNOWN_SCORERS " != *" $scorer "* ]]; then
      echo "  ERROR: $name: unknown scorer '$scorer' (allowed: $KNOWN_SCORERS)"
      errors=$((errors + 1))
      file_errors=$((file_errors + 1))
    fi

    if [[ ! "$version" =~ ^[1-9][0-9]*$ ]]; then
      echo "  ERROR: $name: measurement '$mid' version must be a positive integer, got '$version'"
      errors=$((errors + 1))
      file_errors=$((file_errors + 1))
    fi
  done
  unset seen_ids

  if [[ $file_errors -eq 0 ]]; then
    echo "  $name: OK (agent=$agent, $count measurement(s))"
  fi
done

if [[ $file_count -eq 0 ]]; then
  echo "  ERROR: no eval/measurements/*.yaml files found — expected at least one"
  errors=$((errors + 1))
fi

echo ""
if [[ $errors -gt 0 ]]; then
  echo "ERROR: $errors measurement lint failure(s)" >&2
  exit 1
fi
echo "OK: all measurement manifests pass lint checks"
