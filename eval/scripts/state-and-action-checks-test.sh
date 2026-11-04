#!/usr/bin/env bash
# Tests for the expected_state judge in every agent's eval.yaml and the
# expected_review_action judge in eval/review/eval.yaml. The action must come
# from the evaluated run's write-up only: the current section of the review
# agent's sticky comment. Fully offline: the real judge blocks are extracted
# with yq and run against synthetic states.
#
# Usage:
#   bash eval/scripts/state-and-action-checks-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_DIR="${SCRIPT_DIR}/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fail hard rather than skip, so a missing dependency can never yield a
# green run in which the judge was not exercised.
if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required to extract judge blocks from eval.yaml" >&2
  exit 1
fi

# extract <agent> <judge>: writes the judge's check to $TMP/<agent>-<judge>.py.
extract() {
  local file="$TMP/$1-$2.py"
  yq -r ".judges[] | select(.name == \"$2\") | .check" "${EVAL_DIR}/$1/eval.yaml" > "$file"
  if [[ ! -s "$file" ]]; then
    echo "ERROR: could not extract judge '$2' from eval/$1/eval.yaml" >&2
    exit 1
  fi
}

for agent in triage review code fix retro; do
  extract "$agent" expected_state
done
extract review expected_review_action

python3 - "$TMP" <<'PY'
import base64
import json
import os
import sys
import textwrap

tmp = sys.argv[1]


def load(agent, judge):
    ns = {}
    with open(os.path.join(tmp, f"{agent}-{judge}.py"), encoding="utf-8") as f:
        exec("def check(outputs):\n" + textwrap.indent(f.read(), "    "), ns)
    return ns["check"]


failures = 0
total = 0


def expect(name, check, outputs, want, substr):
    global failures, total
    total += 1
    ok, msg = check(outputs)
    if ok is want and substr in msg:
        print(f"PASS: {name}")
    else:
        failures += 1
        print(f"FAIL: {name}: expected {want} containing {substr!r}, got {ok} {msg!r}")


def outputs_for(state, annotations):
    return {"files": {"output/fixture-state.json": json.dumps(state)}, "annotations": annotations}


# --- expected_state, for every agent ---------------------------------------

STATE_CASES = [
    ("lowercase annotation matches gh's uppercase state",
     {"state": "OPEN"}, {"state": "open"}, True, "State is OPEN"),
    ("closed matches", {"state": "CLOSED"}, {"state": "closed"}, True, "State is CLOSED"),
    ("open expected but closed", {"state": "CLOSED"}, {"state": "open"}, False, "Expected state open, got CLOSED"),
    ("closed expected but open", {"state": "OPEN"}, {"state": "closed"}, False, "Expected state closed, got OPEN"),
    ("failed capture leaves a null state",
     {"pr_fetch_failed": True, "state": None}, {"state": "open"}, False, "State not captured"),
    ("state missing from the capture", {}, {"state": "open"}, False, "State not captured"),
    ("no annotation passes", {"state": "CLOSED"}, {}, True, "No expected state specified"),
]

for agent in ["triage", "review", "code", "fix", "retro"]:
    check = load(agent, "expected_state")
    for name, state, annotations, want, substr in STATE_CASES:
        expect(f"{agent}: {name}", check, outputs_for(state, annotations), want, substr)
    expect(f"{agent}: missing fixture-state.json fails", check,
           {"files": {}, "annotations": {"state": "open"}}, False, "not found")

# --- expected_review_action ------------------------------------------------

check = load("review", "expected_review_action")
MARKER = "<!-- fullsend:review-agent -->"


def projection(payload):
    if not isinstance(payload, str):
        payload = json.dumps(payload)
    encoded = base64.b64encode(payload.encode()).decode()
    return f"<!-- fullsend:review-findings-v2:{encoded} -->"


def action_marker(action):
    return projection({"version": 2, "action": action, "findings": []})


def sticky(current, *history, crlf=False):
    """Sticky body in the shape fullsend post-review writes (sticky.go)."""
    body = MARKER + "\n" + current + "\n\n## Review"
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


def review(state):
    return {"author": "eval-bot", "state": state, "body": "See the review comment."}


APPROVE = action_marker("approve")
COMMENT = action_marker("comment")
REQUEST = action_marker("request-changes")

ACTION_CASES = [
    ("action in the list passes", [sticky(COMMENT)], ["comment"], True, "Review action comment is allowed"),
    ("action among several passes", [sticky(REQUEST)], ["comment", "request-changes"], True, "is allowed"),
    ("action not in the list fails", [sticky(REQUEST)], ["approve", "comment"], False, "is not one of"),
    ("match is case-insensitive", [sticky(COMMENT)], ["Comment"], True, "is allowed"),
    ("no review_action passes without a sticky", [], None, True, "No expected review action specified"),
    ("empty review_action passes", [], [], True, "No expected review action specified"),
    # Only the current section counts.
    ("older section cannot satisfy the list", [sticky(COMMENT, APPROVE)], ["approve"], False, "is not one of"),
    ("older section cannot fail the list", [sticky(APPROVE, COMMENT)], ["approve"], True, "is allowed"),
    ("oldest section is ignored too", [sticky(APPROVE, COMMENT, REQUEST)], ["approve"], True, "is allowed"),
    ("edited sticky with CRLF line endings", [sticky(APPROVE, COMMENT, crlf=True)], ["approve"], True, "is allowed"),
    ("history only, no current marker", [sticky("", APPROVE)], ["approve"], False, "found 0"),
    # Missing or ambiguous attribution never passes.
    ("no sticky fails", [], ["comment"], False, "found 0"),
    ("marker not on the first line is not the sticky",
     [comment("Quoting:\n" + MARKER + "\n" + COMMENT)], ["comment"], False, "found 0"),
    ("two stickies are ambiguous", [sticky(COMMENT), sticky(COMMENT)], ["comment"], False, "found 2"),
    ("two markers in the current section are ambiguous",
     [sticky(COMMENT + "\n" + APPROVE)], ["comment"], False, "found 2"),
    # Malformed markers never pass.
    ("no marker in the sticky", [sticky("No marker here.")], ["comment"], False, "found 0"),
    ("marker with invalid characters is not a marker",
     [sticky("<!-- fullsend:review-findings-v2:not*base64 -->")], ["comment"], False, "found 0"),
    ("marker with bad base64 padding",
     [sticky("<!-- fullsend:review-findings-v2:abcde -->")], ["comment"], False, "Could not decode"),
    ("marker that is not JSON", [sticky(projection("not json"))], ["comment"], False, "Could not decode"),
    ("marker that is not an object", [sticky(projection("[1]"))], ["comment"], False, "has no action"),
    ("marker without an action", [sticky(projection({"version": 2}))], ["comment"], False, "has no action"),
    ("marker with a non-string action", [sticky(projection({"action": 1}))], ["comment"], False, "has no action"),
]

for name, comments, allowed, want, substr in ACTION_CASES:
    annotations = {} if allowed is None else {"review_action": allowed}
    # A formal review is never the source: approve is rejected in evals (#245).
    expect(name, check, outputs_for({"comments": comments, "reviews": []}, annotations), want, substr)

expect("a formal review cannot supply the action", check,
       outputs_for({"comments": [], "reviews": [review("APPROVED")]}, {"review_action": ["approve"]}),
       False, "found 0")
expect("failed capture is not a pass", check,
       outputs_for({"pr_fetch_failed": True, "comments": [], "reviews": []}, {"review_action": ["comment"]}),
       False, "found 0")
expect("missing fixture-state.json fails", check,
       {"files": {}, "annotations": {"review_action": ["comment"]}}, False, "not found")

print(f"\n=== {total} tests, {failures} failures ===")
sys.exit(1 if failures else 0)
PY
