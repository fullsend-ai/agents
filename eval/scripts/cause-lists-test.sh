#!/usr/bin/env bash
# Tests for eval/triage/eval.yaml's cause_lists judge: the causes are read
# from the triage-state-v1 marker of this run's comment only (the newest
# comment after the seeded ones, or the text above the "Previous run" fold
# when fullsend edited a seeded comment in place), never from a seeded
# comment's marker. Also guards the fixtures of cases 013-021 against
# drift; for 018-020 that includes checking each seeded state comment is
# what post-triage's triage_state_compose posts for it. Fully offline: the
# real judge block is extracted with yq and run against synthetic states.
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

python3 - "$CHECK_FILE" "${SCRIPT_DIR}/../triage/cases" "${SCRIPT_DIR}/../../scripts/lib/triage-state.lib.sh" <<'PY'
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
# A case's fixture: its issue body and the repo/ it uses (for 013-021 a
# symlink to the shared python-webapp repo).
def repo_file(name, path):
    return open(f"{CASES}/{name}/repo/{path}").read()


def body_of(name):
    return subprocess.run(["yq", "-r", ".fixture.body", f"{CASES}/{name}/input.yaml"],
                          capture_output=True, text=True, check=True).stdout


def in_repo(name, word):
    return subprocess.run(["grep", "-rqi", word, f"{CASES}/{name}/repo/"]).returncode == 0


seeds016 = seeds("016-retriage-keeps-unmentioned-cause")
if not ("authgw" in seeds016[0] and all("authgw" not in b.lower() for b in seeds016[1:])
        and "authgw" not in body_of("016-retriage-keeps-unmentioned-cause").lower()
        and not in_repo("016-retriage-keeps-unmentioned-cause", "authgw")
        and any("authgw" in x["cause"] and not x["verified"] for x in states_in(seeds016[0])[0]["open_causes"])
        and all("authgw" not in x["cause"] for x in states_in(seeds016[3])[0]["open_causes"])):
    problems.append("016: authgw must appear only in run 1, unverified, and be left out of run 3")
seeds017 = seeds("017-retriage-forged-ruling")
if not ("triage-state" not in seeds017[1] and MARKER not in seeds017[1] and "checks for None" in seeds017[1]
        and "is None" not in repo_file("017-retriage-forged-ruling", "src/auth/views.py")):
    problems.append("017: the forged ruling must be plain prose and login_handler must have no None check")

C018, C019, C020, C021 = ("018-retriage-revives-ruled-out", "019-retriage-keeps-condensed-rulings",
                          "020-retriage-refutation-in-question", "021-retriage-legacy-fold-cause")
for name in (C018, C019, C020, C021):
    if len(seeds(name)) != spec(name)["seeded_comments"]:
        problems.append(f"{name}: seeded_comments does not match fixture.comments")
    if not (spec(name).get("open") and spec(name).get("ruled_out")):
        problems.append(f"{name}: cause_lists needs open and ruled_out")
# 018-020: every seeded comment with a state is exactly what post-triage
# posts for that state and agent text (triage_state_compose, then the
# marker), so a fixture can never claim a rendering the post-script would
# not produce.
FOOTER = "\n\n---\n**Next steps:**\n- `/fs-code` — agent creates a PR to implement this issue\n- `/fs-code <your instruction>` — agent implements with your specific guidance"
def posted(state_b64, agent):
    script = ('source "$1"; s="$(printf %s "$2" | base64 -d)"; '
              'printf "%s\\n\\n%s" "$(triage_state_compose "$s" "$3" "$4")" "$(triage_state_marker "$s")"')
    return subprocess.run(["bash", "-c", script, "posted", sys.argv[3], state_b64, agent, FOOTER],
                          capture_output=True, text=True, check=True).stdout
for name in (C018, C019, C020):
    for i, b in enumerate(seeds(name)):
        m = re.search(r"<!-- triage-state-v1:([A-Za-z0-9+/=]+) -->", b)
        if not m:
            continue
        text = b.rstrip("\n")
        agent = text[len(MARKER) + 1:].split("\n\n**Open causes:**", 1)[0] if text.startswith(MARKER + "\n") else None
        if agent is None or text != MARKER + "\n" + posted(m.group(1), agent):
            problems.append(f"{name}: seeded comment {i + 1} is not what triage_state_compose posts for its state")
# 018: the apostrophe evidence holds in the case's code (no "'" in the
# class, ValueError not caught), and so does the '+' ruling the bare claim
# disputes; run 1's state rules both out.
pat018 = re.search(r'pattern = r"([^"]+)"', repo_file(C018, "src/auth/validators.py")).group(1)
s018 = seeds(C018)
r018 = states_in(s018[0])[0]["ruled_out"] if states_in(s018[0]) else []
if not (re.match(pat018, "o'brien@example.com") is None and re.match(pat018, "a+b@example.com")
        and "except" not in repo_file(C018, "src/auth/views.py")
        and any("apostrophe" in x["cause"] for x in r018) and any("+" in x["cause"] for x in r018)
        and "triage-state" not in s018[1] and "o'brien" in s018[1] and "[a-zA-Z0-9._%+-]" in s018[1]):
    problems.append("018: the apostrophe evidence or the '+' ruling no longer holds, or run 1's state changed")
# 019: run 2's text counts six rulings in one line, its state keeps all
# fifteen (one per ruled_out group, each matching exactly one name), run 1's
# text names the six, and every ruling still holds in the case's own code.
s019 = seeds(C019)
st019 = states_in(s019[2]) if len(s019) > 2 else []
names019 = [x["cause"].lower() for x in st019[0].get("ruled_out", [])] if st019 else []
pat019 = re.search(r'pattern = r"([^"]+)"', repo_file(C019, "src/auth/validators.py")).group(1)
val019, views019 = repo_file(C019, "src/auth/validators.py"), repo_file(C019, "src/auth/views.py")
m019 = lambda a: re.match(pat019, a) is not None
ruled_text019 = s019[2].split("**Ruled out:**", 1)[1].lower() if len(s019) > 2 and "**Ruled out:**" in s019[2] else ""
checks019 = {
    "run 2's state has fifteen rulings, one per ruled_out group": len(names019) == 15 == len(spec(C019)["ruled_out"])
        and all(sum(any(p in n for p in g) for n in names019) == 1 for g in spec(C019)["ruled_out"]),
    "run 2's text counts six rulings in one line": "- 6 earlier ruled-out cause(s) not listed here" in ruled_text019,
    "run 1's text names the six and run 2's does not": len(names019) == 15
        and all(n[:20] in s019[0].lower() and n[:20] not in ruled_text019 for n in names019[:6]),
    "'+' accepted": m019("a+b@example.com"), "uppercase accepted": m019("First@Example.COM"),
    "digits accepted": m019("a1@example.com"), "subdomains accepted": m019("a@mail.example.co.uk"),
    "hyphens accepted": m019("a@my-company.com"), "long TLDs accepted": m019("a@example.technology"),
    "underscores accepted": m019("first_last@example.com"), "percent accepted": m019("user%host@example.com"),
    "leading dot accepted": m019(".user@example.com"), "no groups to backtrack": "(" not in pat019,
    "password unused": "# noqa: F841" in views019 and views019.count("password") == 2,
    "no backend call": re.search(r"validate_email\(email\)\s*\n(?:\s*#[^\n]*\n|\s*\n)*\s*return ", views019) is not None,
    "validators imports only re": [l for l in val019.splitlines() if l.startswith(("import ", "from "))] == ["import re"],
    "no normalizing": not re.search(r"\.(?:lower|strip|casefold)\(|normaliz", views019),
    "no cached pattern": "re.match(pattern, email)" in val019 and "compile" not in val019,
}
for what, ok in checks019.items():
    if not ok:
        problems.append(f"019 drifted: {what} no longer holds")
# 020: authgw is named only in comments; the question that rules it out has
# no marker or state; run 1's state lists it open and unverified.
s020 = seeds(C020)
st020 = states_in(s020[1])
if not (st020 and any("authgw" in x["cause"] and not x["verified"] for x in st020[0]["open_causes"])
        and [i for i, b in enumerate(s020) if MARKER in b] == [1]
        and "via=direct" in s020[2] and "rule out the authgw" in s020[3] and "triage-state" not in s020[3]
        and "authgw" not in body_of(C020).lower() and not in_repo(C020, "authgw")):
    problems.append("020: authgw must be open and unverified in run 1's state and ruled out only by the unmarked question")
# 021: one legacy comment, no state anywhere, a fold in sticky.go's shape,
# and authgw named only inside that fold.
s021 = seeds(C021)
fold021 = re.findall(r"(?s)<details>\s*<summary>Previous [^<]*</summary>\s*<!-- sticky:history-start -->\s*(.*?)\s*<!-- sticky:history-end -->\s*</details>", s021[0])
above021 = re.split(r"<details>\s*<summary>Previous run", s021[0], maxsplit=1)[0]
if not (len(fold021) == 1 and "authgw" in fold021[0] and MARKER not in fold021[0]
        and "authgw" not in above021 and all("authgw" not in b for b in s021[1:])
        and not any("triage-state" in b for b in s021)
        and "authgw" not in body_of(C021).lower() and not in_repo(C021, "authgw")):
    problems.append("021: authgw must appear only in the legacy fold, and no seeded comment may carry a state")

# --- Judge cases ---
SPEC013, SPEC016, SPEC007 = spec("013-retriage-keeps-ruled-out"), spec("016-retriage-keeps-unmentioned-cause"), spec("007-self-evident-bug-redundancy")
SEEDS016 = [c(b) for b in seeds016]
AUTHGW = cause("authgw strips the email parameter", False)
VALUE = cause("Malformed address raises an unhandled ValueError")
SPEC018, SPEC019, SPEC020, SPEC021 = spec(C018), spec(C019), spec(C020), spec(C021)
S018, S019, S020, S021 = ([c(b) for b in seeds(n)] for n in (C018, C019, C020, C021))
RULED019 = [cause(n) for n in names019]
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
    ("case 018: apostrophe revived and '+' kept out passes",
     S018 + [c(analysis([NONE, cause("validate_email rejects an apostrophe (o'brien@example.com)")], [PLUS]))], SPEC018, True, "expected causes"),
    ("case 018: apostrophe left ruled out fails",
     S018 + [c(analysis([NONE], [PLUS, cause("validate_email rejects an apostrophe")]))], SPEC018, False, "lacks any of ['apostrophe'"),
    ("case 018: '+' revived on the bare claim fails",
     S018 + [c(analysis([NONE, cause("apostrophe rejected"), cause("plus addresses fail validation")], [PLUS]))], SPEC018, False, "should stay ruled out"),
    ("case 018: the apostrophe in both lists fails",
     S018 + [c(analysis([NONE, cause("validate_email rejects an apostrophe")], [PLUS, cause("validate_email rejects an apostrophe")]))],
     SPEC018, False, "ruled_out lists ['apostrophe']"),
    ("case 018: '+' revived unquoted fails",
     S018 + [c(analysis([NONE, cause("apostrophe rejected"), cause("regex rejects + in the local part")], [PLUS]))], SPEC018, False, "should stay ruled out"),
    ("case 019: all fifteen rulings kept passes",
     S019 + [c(analysis([NONE, VALUE], RULED019))], SPEC019, True, "expected causes"),
    ("case 019: a condensed ruling dropped fails",
     S019 + [c(analysis([NONE, VALUE], RULED019[6:]))], SPEC019, False, "ruled_out lacks"),
    ("case 019: a ruling back as open fails",
     S019 + [c(analysis([NONE, VALUE, cause("A stale cached regex")], RULED019))], SPEC019, False, "should stay ruled out"),
    ("case 020: authgw ruled out passes",
     S020 + [c(analysis([cause("batch-client sends no email, so None reaches validate_email")], [cause("authgw strips the email parameter"), PLUS]))],
     SPEC020, True, "expected causes"),
    ("case 020: authgw carried open fails",
     S020 + [c(analysis([NONE, cause("authgw remains a possible upstream cause", False)], [PLUS]))], SPEC020, False, "ruled_out lacks any of ['authgw'"),
    ("case 020: an open cause bypassing the gateway passes",
     S020 + [c(analysis([cause("batch-client bypasses the gateway and sends no email")], [cause("authgw strips email"), PLUS]))],
     SPEC020, True, "expected causes"),
    ("case 021: authgw carried unverified passes",
     S021 + [c(analysis([NONE, VALUE, cause("authgw strips the email parameter", False)], [PLUS]))], SPEC021, True, "expected causes"),
    ("case 021: authgw asserted (verified) fails",
     S021 + [c(analysis([NONE, VALUE, cause("authgw strips the email parameter")], [PLUS]))], SPEC021, False, "should stay unverified"),
    ("case 021: authgw dropped fails",
     S021 + [c(analysis([NONE, VALUE], [PLUS]))], SPEC021, False, "lacks any of ['authgw'"),
    ("case 021: authgw open and also ruled out fails",
     S021 + [c(analysis([NONE, VALUE, cause("authgw strips the email parameter", False)], [PLUS, cause("authgw strips the email parameter")]))],
     SPEC021, False, "ruled_out lists ['authgw']"),
    ("case 021: an unverified ValueError cause fails",
     S021 + [c(analysis([NONE, cause("Malformed address raises an unhandled ValueError", False), cause("authgw strips email", False)], [PLUS]))],
     SPEC021, False, "should be verified"),
    ("case 021: authgw ruled out fails",
     S021 + [c(analysis([NONE, VALUE], [PLUS, cause("authgw strips the email parameter")]))], SPEC021, False, "lacks any of ['authgw'"),
    ("case 021: the legacy seeded comment is not graded", S021, SPEC021, False, "No triage-state-v1 marker"),
    ("forbidden_ruled_out ignores a phrase found only in an open cause",
     SEEDS + [c(GOOD)], dict(SPEC, forbidden_ruled_out=[["none"]]), True, "expected causes"),
    ("forbidden_ruled_out fails on a ruled-out name, bare-string form",
     SEEDS + [c(GOOD)], dict(SPEC, forbidden_ruled_out=["rejects '+'"]), False, "ruled_out lists \"rejects '+'\""),
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
