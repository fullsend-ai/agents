#!/usr/bin/env bash
# Tests for eval/review/eval.yaml's finding_expectations judge: categories
# must come from the evaluated run's write-up only — the current section of
# the review agent's sticky comment — never from formal reviews, other
# comments, or the sticky's previous-run history. Fully offline: the real
# judge block is extracted with yq and run against synthetic states.
#
# Usage:
#   bash eval/scripts/finding-expectations-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_YAML="${SCRIPT_DIR}/../review/eval.yaml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fail hard rather than skip, so a missing dependency can never yield a
# green run in which the judge was not exercised.
if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required to extract judge blocks from ${EVAL_YAML}" >&2
  exit 1
fi

CHECK_FILE="$TMP/finding_expectations.py"
yq -r '.judges[] | select(.name == "finding_expectations") | .check' "$EVAL_YAML" > "$CHECK_FILE"
if [[ ! -s "$CHECK_FILE" ]]; then
  echo "ERROR: could not extract judge 'finding_expectations' from ${EVAL_YAML}" >&2
  exit 1
fi

python3 - "$CHECK_FILE" <<'PY'
import json
import sys
import textwrap

ns = {}
exec("def check(outputs):\n" + textwrap.indent(open(sys.argv[1]).read(), "    "), ns)

MARKER = "<!-- fullsend:review-agent -->"
PROJECTION = "<!-- fullsend:review-findings-v2:eyJ2ZXJzaW9uIjoyfQ== -->"


def sticky(current, *history, crlf=False):
    """Sticky body in the shape fullsend post-review writes (sticky.go)."""
    body = MARKER + "\n" + PROJECTION + "\n\n" + current
    for i, old in enumerate(history):
        summary = "Previous run" if i == 0 else f"Previous run ({i + 1})"
        body += (f"\n\n<details>\n<summary>{summary}</summary>\n\n"
                 "<!-- sticky:history-start -->\n" + old +
                 "\n<!-- sticky:history-end -->\n\n</details>")
    if crlf:
        body = body.replace("\n", "\r\n")
    return {"author": "eval-bot", "body": body, "created_at": "2026-01-01T00:00:00Z"}


def comment(body):
    return {"author": "eval-bot", "body": body, "created_at": "2026-01-01T00:00:00Z"}


def review(body, state="COMMENTED"):
    return {"author": "eval-bot", "state": state, "body": body}


CLEAN = "## Review\n\nNo findings."
LOGIC = "## Findings\n\n- **[logic-error]** `a.py:1` — wrong branch."
OLD_LOGIC = "## Findings\n\n- **[logic-error]** `a.py:1` — old finding."
LINK = "See the review comment above for full details."

cases = [
    # Issue #1824 regressions.
    ("historical review cannot satisfy required",
     [sticky(CLEAN)], [review(OLD_LOGIC), review(LINK)],
     {"required": ["logic-error"]}, False, "missing=['logic-error']"),
    ("historical review cannot satisfy required_any",
     [sticky(CLEAN)], [review(OLD_LOGIC)],
     {"required_any": ["logic-error", "edge-case"]}, False, "missing_any="),
    ("PR-author comment cannot satisfy required",
     [comment("Discussion of [logic-error]."), sticky(CLEAN)], [],
     {"required": ["logic-error"]}, False, "missing=['logic-error']"),
    ("historical review cannot trigger forbidden",
     [sticky(CLEAN)], [review(OLD_LOGIC), review(LINK)],
     {"forbidden": ["logic-error"]}, True, "Finding expectations met"),
    ("unrelated comment cannot trigger forbidden",
     [comment("Is this a [logic-error]?"), sticky(CLEAN)], [],
     {"forbidden": ["logic-error"]}, True, "Finding expectations met"),
    ("sticky previous-run history cannot trigger forbidden",
     [sticky(CLEAN, OLD_LOGIC)], [review(LINK)],
     {"forbidden": ["logic-error"]}, True, "Finding expectations met"),
    ("older sticky history cannot trigger forbidden",
     [sticky(CLEAN, CLEAN, OLD_LOGIC)], [],
     {"forbidden": ["logic-error"]}, True, "Finding expectations met"),
    ("sticky previous-run history cannot satisfy required",
     [sticky(CLEAN, OLD_LOGIC)], [],
     {"required": ["logic-error"]}, False, "missing=['logic-error']"),
    # Genuine current-run findings still count.
    ("current finding satisfies required",
     [sticky(LOGIC)], [review(LINK, "CHANGES_REQUESTED")],
     {"required": ["logic-error"]}, True, "Finding expectations met"),
    ("current finding satisfies required_any",
     [sticky(LOGIC)], [],
     {"required_any": ["edge-case", "logic-error"]}, True, "Finding expectations met"),
    ("current finding triggers forbidden",
     [sticky(LOGIC)], [],
     {"forbidden": ["logic-error"]}, False, "forbidden_present=['logic-error']"),
    ("category match is case-insensitive",
     [sticky(LOGIC)], [],
     {"required": ["Logic-Error"]}, True, "Finding expectations met"),
    # A sticky edited in place: the current section is read, history is not.
    ("edited sticky: current finding satisfies required",
     [sticky(LOGIC, CLEAN)], [],
     {"required": ["logic-error"]}, True, "Finding expectations met"),
    ("edited sticky: current finding triggers forbidden",
     [sticky(LOGIC, OLD_LOGIC)], [],
     {"forbidden": ["logic-error"]}, False, "forbidden_present=['logic-error']"),
    ("edited sticky with CRLF line endings",
     [sticky(LOGIC, CLEAN, crlf=True)], [],
     {"required": ["logic-error"]}, True, "Finding expectations met"),
    ("no expectations with a clean sticky",
     [sticky(CLEAN)], [], {}, True, "No finding expectations specified"),
    ("empty expectation lists stay vacuous",
     [], [], {"required": [], "forbidden": []}, True, "No finding expectations specified"),
    # Missing or ambiguous attribution never passes.
    ("no sticky: forbidden-only does not pass",
     [], [review(CLEAN)],
     {"forbidden": ["logic-error"]}, False, "found 0"),
    ("no sticky: author comment with finding does not pass",
     [comment("[logic-error] noted")], [review(LOGIC)],
     {"required": ["logic-error"]}, False, "found 0"),
    ("marker not on the first line is not the sticky",
     [comment("Quoting:\n" + MARKER + "\n" + LOGIC)], [],
     {"required": ["logic-error"]}, False, "found 0"),
    ("two stickies are ambiguous",
     [sticky(CLEAN), sticky(LOGIC)], [],
     {"forbidden": ["logic-error"]}, False, "found 2"),
    ("failed capture is not a clean review",
     None, None, {"forbidden": ["logic-error"]}, False, "found 0"),
]

failures = 0
for name, comments, reviews, findings, want, substr in cases:
    if comments is None:
        state = {"pr_fetch_failed": True, "comments": [], "reviews": []}
    else:
        state = {"comments": comments, "reviews": reviews}
    outputs = {"files": {"output/fixture-state.json": json.dumps(state)},
               "annotations": {"findings": findings}}
    ok, msg = ns["check"](outputs)
    if ok is want and substr in msg:
        print(f"PASS: {name}")
    else:
        failures += 1
        print(f"FAIL: {name}: expected {want} containing {substr!r}, got {ok} {msg!r}")

ok, msg = ns["check"]({"files": {}, "annotations": {}})
if ok is False and "not found" in msg:
    print("PASS: missing fixture-state.json fails")
else:
    failures += 1
    print(f"FAIL: missing fixture-state.json: got {ok} {msg!r}")

print(f"\n=== {len(cases) + 1} tests, {failures} failures ===")
sys.exit(1 if failures else 0)
PY
