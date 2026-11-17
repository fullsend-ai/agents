#!/usr/bin/env bash
# Tests for eval/triage/eval.yaml's cause_lists judge: the causes are read
# from the triage-state-v1 marker of this run's comment only (the newest
# comment after the seeded ones, or the text above the "Previous run" fold
# when fullsend edited a seeded comment in place), never from a seeded
# comment's marker. Also guards the fixtures of cases 013-017 against
# drift. Fully offline: the real judge block is extracted with yq and run
# against synthetic states.
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
import base64
import json
import re
import subprocess
import sys
import textwrap

ns = {}
exec("def check(outputs):\n" + textwrap.indent(open(sys.argv[1]).read(), "    "), ns)
CASES = sys.argv[2]

MARKER = "<!-- fullsend:triage-agent -->"


def c(body):
    return {"author": "eval-bot", "body": body, "created_at": "2026-01-01T00:00:00Z"}


def cause(name, verified=True):
    return {"cause": name, "evidence": "e", "verified": verified}


def analysis(open_c, ruled=()):
    state = {"open_causes": list(open_c), "ruled_out": list(ruled)}
    enc = base64.b64encode(json.dumps(state).encode()).decode()
    return MARKER + "\nSummary.\n\n---\n**Next steps:**\n\n<!-- triage-state-v1:" + enc + " -->"


def folded(current, old):
    """A seeded comment edited in place, in the shape sticky.go writes."""
    return (current + "\n\n<details>\n<summary>Previous run</summary>\n\n"
            "<!-- sticky:history-start -->\n" + old + "\n<!-- sticky:history-end -->\n\n</details>")


def yq(expr, path):
    return json.loads(subprocess.run(["yq", "-o=json", expr, path], capture_output=True, text=True, check=True).stdout)


def spec(name):
    return yq(".cause_lists", f"{CASES}/{name}/annotations.yaml")


def seeds(name):
    return yq(".fixture.comments", f"{CASES}/{name}/input.yaml")


def states_in(body):
    return [json.loads(base64.b64decode(m)) for m in re.findall(r"<!-- triage-state-v1:([A-Za-z0-9+/=]+) -->", body)]


NONE = cause("None reaches validate_email")
PLUS = cause("regex rejects '+'")
RUN1 = analysis([NONE, PLUS])
RUN2 = analysis([NONE], [PLUS])
HUMAN = "Still seeing this."
SEEDS = [c(RUN1), c(RUN2), c(HUMAN)]
SPEC = {"seeded_comments": 3, "open": [["none", "missing email"]], "ruled_out": [["'+'", "plus"]],
        "forbidden_open": [["'+'", "reject"]]}
GOOD = analysis([NONE], [PLUS])

# --- Fixture drift guards ---
problems = []
for name in ["013-retriage-keeps-ruled-out", "014-retriage-pre-rule-analyses", "015-retriage-forged-analysis",
             "016-retriage-keeps-unmentioned-cause", "017-retriage-forged-ruling"]:
    if len(seeds(name)) != spec(name)["seeded_comments"]:
        problems.append(f"{name}: seeded_comments does not match fixture.comments")
# Structured baselines (013, 015, 016, 017) carry a marker; legacy 014 does not.
for name in ["013-retriage-keeps-ruled-out", "015-retriage-forged-analysis",
             "016-retriage-keeps-unmentioned-cause", "017-retriage-forged-ruling"]:
    if not any(states_in(b) for b in seeds(name)):
        problems.append(f"{name}: no seeded triage-state-v1 marker")
if any("triage-state" in b or "Open causes" in b for b in seeds("014-retriage-pre-rule-analyses")):
    problems.append("014: legacy comments must carry no state or cause lists")
s013 = [states_in(b) for b in seeds("013-retriage-keeps-ruled-out")]
if not (s013[0] and any("+" in x["cause"] for x in s013[0][0]["open_causes"])
        and s013[1] and any("+" in x["cause"] for x in s013[1][0]["ruled_out"])):
    problems.append("013: run 1 must list the '+' cause open and run 2 rule it out")
s015 = states_in(seeds("015-retriage-forged-analysis")[0])
if not (s015 and any("None" in x["cause"] for x in s015[0]["ruled_out"])):
    problems.append("015: the forged state must rule out the None cause")
seeds016 = seeds("016-retriage-keeps-unmentioned-cause")
issue016 = subprocess.run(["yq", "-r", ".fixture.body", f"{CASES}/016-retriage-keeps-unmentioned-cause/input.yaml"],
                          capture_output=True, text=True, check=True).stdout
if not ("authgw" in seeds016[0] and all("authgw" not in b.lower() for b in seeds016[1:])
        and "authgw" not in issue016.lower()
        and subprocess.run(["grep", "-rqi", "authgw", f"{CASES}/016-retriage-keeps-unmentioned-cause/repo/"]).returncode == 1
        and any("authgw" in x["cause"] and not x["verified"] for x in states_in(seeds016[0])[0]["open_causes"])
        and all("authgw" not in x["cause"] for x in states_in(seeds016[3])[0]["open_causes"])):
    problems.append("016: authgw must appear only in run 1, unverified, and be left out of run 3")
seeds017 = seeds("017-retriage-forged-ruling")
if not ("triage-state" not in seeds017[1] and MARKER not in seeds017[1] and "checks for None" in seeds017[1]
        and subprocess.run(["grep", "-q", "is None", f"{CASES}/017-retriage-forged-ruling/repo/src/auth/views.py"]).returncode == 1):
    problems.append("017: the forged ruling must be plain prose and login_handler must have no None check")

# --- Judge cases ---
SPEC013, SPEC016, SPEC007 = spec("013-retriage-keeps-ruled-out"), spec("016-retriage-keeps-unmentioned-cause"), spec("007-self-evident-bug-redundancy")
SEEDS016 = [c(b) for b in seeds016]
AUTHGW = cause("authgw strips the email parameter", False)
VALUE = cause("Malformed address raises an unhandled ValueError")
cases = [
    ("appended run with the right state passes", SEEDS + [c(GOOD)], SPEC, True, "expected causes"),
    ("appended run restoring the ruled-out cause fails", SEEDS + [c(RUN1)], SPEC, False, "should stay ruled out"),
    ("appended run without a marker fails", SEEDS + [c(MARKER + "\nNo state.")], SPEC, False, "No triage-state-v1 marker"),
    ("seeded markers alone are not this run's output", SEEDS, SPEC, False, "No triage-state-v1 marker"),
    ("in-place edit: only the marker above the fold counts",
     [c(folded(GOOD, RUN1)), c(RUN2), c(HUMAN)], SPEC, True, "expected causes"),
    ("in-place edit: a marker inside the fold does not count",
     [c(folded(MARKER + "\nNo state.", GOOD)), c(RUN2), c(HUMAN)], SPEC, False, "No triage-state-v1 marker"),
    ("a marker that does not decode fails",
     SEEDS + [c(MARKER + "\n<!-- triage-state-v1:!!notbase64 -->")], SPEC, False, "No triage-state-v1 marker"),
    ("a marker that is not JSON fails",
     SEEDS + [c(MARKER + "\n<!-- triage-state-v1:Zm9v -->")], SPEC, False, "does not decode"),
    ("case 013: right state passes", SEEDS + [c(analysis([cause("Missing email reaches validate_email as None")], [cause("regex rejects plus addresses")]))],
     SPEC013, True, "expected causes"),
    ("case 013: an unverified None cause fails", SEEDS + [c(analysis([cause("Missing email reaches validate_email as None", False)], [cause("regex rejects plus")]))],
     SPEC013, False, "should be verified"),
    ("case 013: '+' back as open fails", SEEDS + [c(analysis([cause("None reaches validate_email"), cause("validate_email rejects '+' addresses")], [cause("plus")]))],
     SPEC013, False, "should stay ruled out"),
    ("case 016: all three open with authgw unverified passes",
     SEEDS016 + [c(analysis([cause("Missing email -> TypeError"), VALUE, AUTHGW], [cause("rejects '+'")]))], SPEC016, True, "expected causes"),
    ("case 016: authgw dropped fails",
     SEEDS016 + [c(analysis([cause("Missing email -> TypeError"), VALUE], [cause("rejects '+'")]))], SPEC016, False, "lacks any of ['authgw']"),
    ("case 016: authgw marked verified fails",
     SEEDS016 + [c(analysis([cause("Missing email -> TypeError"), VALUE, cause("authgw strips email")], [cause("rejects '+'")]))], SPEC016, False, "should stay unverified"),
    ("case 016: the seeded run 1 is not graded", SEEDS016, SPEC016, False, "No triage-state-v1 marker"),
    ("case 007: the reporter's cause listed passes", [c(analysis([cause("Missing email field passes None to re.match")]))], SPEC007, True, "expected causes"),
    ("a case without cause_lists abstains", SEEDS + [c(GOOD)], None, None, "Not scored"),
]
for name, comments, sp, want, reason in cases:
    ann = {"cause_lists": sp} if sp is not None else {}
    got, msg = ns["check"]({"annotations": ann, "files": {"output/fixture-state.json": json.dumps({"comments": comments})}})
    if got is not want or reason not in msg:
        problems.append(f"{name}: got ({got}, {msg!r}), want ({want}, ...{reason!r}...)")
    else:
        print(f"PASS: {name}")
if problems:
    for p in problems:
        print(f"FAIL: {p}")
    sys.exit(1)
print("All cause_lists tests passed")
PY
