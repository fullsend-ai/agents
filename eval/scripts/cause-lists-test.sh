#!/usr/bin/env bash
# Tests for eval/triage/eval.yaml's cause_lists judge: the Open causes and
# Ruled out lists are read from this run's analysis only (the newest marked
# comment after the seeded ones, or the text above the "Previous run" fold
# when fullsend edited a seeded comment in place), never from the seeded
# analyses. Fully offline: the real judge block is extracted with yq and
# run against synthetic states.
#
# Usage:
#   bash eval/scripts/cause-lists-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_YAML="${SCRIPT_DIR}/../triage/eval.yaml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fail hard rather than skip, so a missing dependency can never yield a
# green run in which the judge was not exercised.
if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required to extract judge blocks from ${EVAL_YAML}" >&2
  exit 1
fi

CHECK_FILE="$TMP/cause_lists.py"
yq -r '.judges[] | select(.name == "cause_lists") | .check' "$EVAL_YAML" > "$CHECK_FILE"
if [[ ! -s "$CHECK_FILE" ]]; then
  echo "ERROR: could not extract judge 'cause_lists' from ${EVAL_YAML}" >&2
  exit 1
fi

python3 - "$CHECK_FILE" "${SCRIPT_DIR}/../triage/cases" <<'PY'
import json
import sys
import textwrap

ns = {}
exec("def check(outputs):\n" + textwrap.indent(open(sys.argv[1]).read(), "    "), ns)

MARKER = "<!-- fullsend:triage-agent -->"
FOOTER = "\n\n---\n**Next steps:**\n- `/fs-code` — agent creates a PR to implement this issue"


def c(body):
    return {"author": "eval-bot", "body": body, "created_at": "2026-01-01T00:00:00Z"}


def analysis(open_lines, ruled_lines=None):
    body = MARKER + "\nSummary.\n\n**Open causes:**\n" + "\n".join(f"- {l}" for l in open_lines)
    if ruled_lines:
        body += "\n\n**Ruled out:**\n" + "\n".join(f"- {l}" for l in ruled_lines)
    return body + FOOTER


def folded(current, old):
    """A seeded comment edited in place, in the shape sticky.go writes."""
    return (current + "\n\n<details>\n<summary>Previous run</summary>\n\n"
            "<!-- sticky:history-start -->\n" + old + "\n<!-- sticky:history-end -->\n\n</details>")


RUN1 = analysis(["None reaches validate_email", "regex rejects '+'"])
RUN2 = analysis(["None reaches validate_email"], ["regex rejects '+' — the class includes it"])
HUMAN = "Still seeing this."
SEEDS = [c(RUN1), c(RUN2), c(HUMAN)]
SPEC = {"seeded_comments": 3,
        "open": [["none", "missing email"]],
        "ruled_out": [["'+'", "plus"]],
        "forbidden_open": ["'+'"]}

# The annotations of the real cases, read from the repository.
import subprocess
def case_spec(name):
    out = subprocess.run(["yq", "-o=json", ".cause_lists", f"{sys.argv[2]}/{name}/annotations.yaml"],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)
SPEC013 = case_spec("013-retriage-keeps-ruled-out")
SPEC007 = case_spec("007-self-evident-bug-redundancy")

GOOD = analysis(["None reaches validate_email — unchecked"], ["regex rejects '+' — class includes '+'"])
RESTORED = analysis(["None reaches validate_email", "regex rejects '+'"])
NO_LISTS = MARKER + "\nThe None cause still holds." + FOOTER

cases = [
    ("appended run with correct lists passes", SEEDS + [c(GOOD)], SPEC, True, "match"),
    ("appended run restoring the ruled-out cause fails", SEEDS + [c(RESTORED)], SPEC, False, "should stay ruled out"),
    ("appended run without lists fails", SEEDS + [c(NO_LISTS)], SPEC, False, "No Open causes list"),
    ("seeded analyses alone are not this run's output", SEEDS, SPEC, False, "No triage analysis from this run"),
    ("in-place edit: only the text above the fold counts",
     [c(folded(GOOD, RUN1)), c(RUN2), c(HUMAN)], SPEC, True, "match"),
    ("in-place edit: the folded run 1 cannot satisfy the lists",
     [c(folded(NO_LISTS, RUN1)), c(RUN2), c(HUMAN)], SPEC, False, "No Open causes list"),
    ("the footer after the lists is not read as Ruled out",
     SEEDS + [c(analysis(["None reaches validate_email"]))], SPEC, False, "Ruled out lacks"),
    ("a forbidden phrase in an open cause's evidence is allowed",
     SEEDS + [c(analysis(["ValueError reaches the framework — the '+' check does not cover it", "None reaches validate_email"],
                         ["regex rejects '+' — class includes '+'"]))], SPEC, True, "match"),
    ("a numbered Open causes list restoring the ruled-out cause fails",
     SEEDS + [c(MARKER + "\n\n**Open causes:**\n1. None reaches validate_email\n2. regex rejects '+' in the local part\n\n**Ruled out:**\n- regex rejects '+' — class includes it" + FOOTER)],
     SPEC, False, "should stay ruled out"),
    ("headings spelled loosely are still read",
     SEEDS + [c(MARKER + "\n\n**Open Causes**:\n- None reaches validate_email\n\n### Ruled out\n- regex rejects '+' — class includes it" + FOOTER)],
     SPEC, True, "match"),
    ("a bold phrase mid-sentence is not a list heading",
     SEEDS + [c(MARKER + "\n\nWe keep the **open causes:** idea in mind.\n- regex rejects '+'" + FOOTER)],
     SPEC, False, "No Open causes list"),
    ("a required cause named only in another cause's evidence does not count",
     SEEDS + [c(analysis(["ValueError reaches the framework — the missing email cause was ruled out"],
                         ["regex rejects '+' — class includes '+'"]))], SPEC, False, "Open causes lacks"),
    ("other correct wordings of both causes pass",
     SEEDS + [c(analysis(["Missing email field reaches validate_email unchecked"], ["Regex rejects + in the local part — class includes it"]))],
     SPEC013, True, "match"),
    ("an unrelated email cause does not satisfy case 007",
     [c(analysis(["validate_email accepts addresses without a TLD"]))], SPEC007, False, "Open causes lacks"),
    ("a heading with a trailing note is still read",
     SEEDS + [c(MARKER + "\n\n**Open causes** (1 kept):\n- None reaches validate_email\n\n### Ruled out (from run 2)\n- regex rejects '+' — class includes it" + FOOTER)],
     SPEC, True, "match"),
    ("a bold Ruled out heading with a trailing note ends the Open causes section",
     SEEDS + [c(MARKER + "\n\n**Open causes:**\n- None reaches validate_email\n\n**Ruled out** (from run 2):\n- regex rejects '+' — class includes it" + FOOTER)],
     SPEC, True, "match"),
    ("a revived cause written with a double-quoted plus is caught",
     SEEDS + [c(analysis(["None reaches validate_email", 'regex rejects "+"'], ["regex rejects '+' — class includes it"]))],
     SPEC013, False, "should stay ruled out"),
    ("case 007 accepts the reporter's words for the open cause",
     [c(analysis(["Blank email input reaches the validator, as reported"]))], SPEC007, True, "match"),
    ("a ruled-out cause reworded with plus is still caught",
     SEEDS + [c(analysis(["None reaches validate_email", "regex rejects plus addresses"], ["regex rejects '+' — class includes it"]))],
     SPEC013, False, "should stay ruled out"),
    ("an unmarked status comment after the run is ignored",
     SEEDS + [c(GOOD), c("🤖 Finished Triage")], SPEC, True, "match"),
    ("a fresh triage with no seeds passes on its lists",
     [c(analysis(["missing email reaches validate_email as None"]))],
     {"open": [["none", "missing"]]}, True, "match"),
    ("no cause_lists expectations: skipped", SEEDS, None, True, "No cause_lists"),
]

failures = 0
for name, comments, spec, want, substr in cases:
    annotations = {"cause_lists": spec} if spec else {}
    outputs = {"files": {"output/fixture-state.json": json.dumps({"comments": comments})},
               "annotations": annotations}
    ok, msg = ns["check"](outputs)
    if ok is want and substr in msg:
        print(f"PASS: {name}")
    else:
        failures += 1
        print(f"FAIL: {name}: expected {want} containing {substr!r}, got {ok} {msg!r}")

ok, msg = ns["check"]({"files": {}, "annotations": {"cause_lists": SPEC}})
if ok is False and "not found" in msg:
    print("PASS: missing fixture-state.json fails")
else:
    failures += 1
    print(f"FAIL: missing fixture-state.json: got {ok} {msg!r}")

print(f"\n=== {len(cases) + 1} tests, {failures} failures ===")
sys.exit(1 if failures else 0)
PY
