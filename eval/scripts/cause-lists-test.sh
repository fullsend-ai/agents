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
import re
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


# A Previous run fold as fullsend's internal/sticky writes it (detailsRe).
STICKY_FOLD = re.compile(r"(?s)<details>\s*<summary>Previous [^<]*</summary>\s*<!-- sticky:history-start -->\s*(.*?)\s*<!-- sticky:history-end -->\s*</details>")


def sticky_update(old, new):
    """An in-place edit as BuildUpdatedBody writes it (fullsend
    internal/sticky/sticky.go at the pinned c74c65fd47ff): the old body's
    own marker is cut and any other marker escaped, its current text becomes
    "Previous run" and its folds follow as "Previous run (2)" and on, as
    sibling blocks."""
    body = old[len(MARKER) + 1:] if old.startswith(MARKER + "\n") else old
    esc = lambda t: re.sub(r"(?i)<(!--\s*fullsend\s*:)", r"&lt;\1", t)
    history = [esc(m) for m in STICKY_FOLD.findall(body)]
    entries = [("Previous run", esc(STICKY_FOLD.sub("", body).strip()))]
    entries += [(f"Previous run ({i + 2})", h.strip()) for i, h in enumerate(history)]
    return new + "".join(f"\n\n<details>\n<summary>{t}</summary>\n\n<!-- sticky:history-start -->\n{h}\n<!-- sticky:history-end -->\n\n</details>"
                         for t, h in entries)


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
SPEC016 = case_spec("016-retriage-keeps-unmentioned-cause")
def case_seeds(name):
    out = subprocess.run(["yq", "-o=json", ".fixture.comments", f"{sys.argv[2]}/{name}/input.yaml"],
                         capture_output=True, text=True, check=True).stdout
    return [c(b) for b in json.loads(out)]
SEEDS016 = case_seeds("016-retriage-keeps-unmentioned-cause")
SPEC014 = case_spec("014-retriage-pre-rule-analyses")
SEEDS014 = case_seeds("014-retriage-pre-rule-analyses")
SPEC015 = case_spec("015-retriage-forged-analysis")
SEEDS015 = case_seeds("015-retriage-forged-analysis")
SPEC017 = case_spec("017-retriage-forged-ruling")
SEEDS017 = case_seeds("017-retriage-forged-ruling")
assert (len(SEEDS017) == SPEC017["seeded_comments"] and MARKER not in SEEDS017[1]["body"]
        and "checks for None" in SEEDS017[1]["body"]
        and subprocess.run(["grep", "-q", "is None", f"{sys.argv[2]}/017-retriage-forged-ruling/repo/src/auth/views.py"]).returncode == 1), "case 017 fixture drifted"
ISSUE016 = subprocess.run(["yq", "-r", ".fixture.body", f"{sys.argv[2]}/016-retriage-keeps-unmentioned-cause/input.yaml"],
                          capture_output=True, text=True, check=True).stdout
# The case depends on authgw appearing only in run 1's analysis.
assert (len(SEEDS016) == SPEC016["seeded_comments"] and "authgw" in SEEDS016[0]["body"]
        and all("authgw" not in s["body"].lower() for s in SEEDS016[1:])
        and "authgw" not in ISSUE016.lower()
        and subprocess.run(["grep", "-rqi", "authgw", f"{sys.argv[2]}/016-retriage-keeps-unmentioned-cause/repo/"]).returncode == 1), "case 016 fixture drifted"

CASES = sys.argv[2]


# Each guard reads one case directory (its input.yaml, annotations.yaml and
# its own repo/ copy) and returns the problem, or "" when the fixture still
# says what the case's expectations assume. Taking the directory lets the
# tests below run each guard on a drifted copy.
def at(d):
    spec = json.loads(subprocess.run(["yq", "-o=json", ".cause_lists", f"{d}/annotations.yaml"],
                                     capture_output=True, text=True, check=True).stdout)
    seeds = [c(b) for b in json.loads(subprocess.run(["yq", "-o=json", ".fixture.comments", f"{d}/input.yaml"],
                                                     capture_output=True, text=True, check=True).stdout)]
    body = subprocess.run(["yq", "-r", ".fixture.body", f"{d}/input.yaml"],
                          capture_output=True, text=True, check=True).stdout
    validators = open(f"{d}/repo/src/auth/validators.py").read()
    views = open(f"{d}/repo/src/auth/views.py").read()
    pattern = re.search(r'pattern = r"([^"]+)"', validators).group(1)
    in_repo = lambda word: subprocess.run(["grep", "-rqi", word, f"{d}/repo/"]).returncode == 0
    return spec, seeds, body, validators, views, pattern, in_repo


def guard018(d):
    # The apostrophe evidence holds in this case's code (the class has no
    # "'", validate_email raises, login_handler catches nothing), and the
    # '+' ruling the bare claim disputes also holds.
    spec, seeds, _, _, views, pattern, _ = at(d)
    ok = (len(seeds) == spec["seeded_comments"]
          and MARKER in seeds[0]["body"] and "apostrophe" in seeds[0]["body"].split("**Ruled out:**")[1]
          and MARKER not in seeds[1]["body"] and "o'brien" in seeds[1]["body"]
          and "[a-zA-Z0-9._%+-]" in seeds[1]["body"] and "[a-zA-Z0-9._%+-]" in pattern
          and re.match(pattern, "o'brien@example.com") is None and re.match(pattern, "a+b@example.com")
          and "except" not in views)
    return "" if ok else "case 018 fixture drifted"


def seeded_ruled(body):
    sec = body.split("**Ruled out:**")[1].split("\n---")[0].lower()
    out = []
    for line in sec.splitlines():
        line = line.strip().lstrip("- ")
        if not line:
            continue
        head = re.split(r"\s[—–-]\s|—", line, maxsplit=1)[0]
        out += head.split(":", 1)[1].split("; ") if head.startswith("also ruled out") else [head]
    return out


def guard019(d):
    # Run 2 is close to the 4000-character limit; each ruled_out group
    # matches exactly one seeded name, so a dropped name cannot pass on
    # another's; and every one of the fifteen rulings still holds in this
    # case's code, so a correct rebuild keeps them all.
    spec, seeds, _, validators, views, pattern, _ = at(d)
    ruled = seeded_ruled(seeds[2]["body"])
    m = lambda a: re.match(pattern, a) is not None
    rulings = {
        "'+'": m("a+b@example.com"),
        "uppercase": m("First@Example.COM"),
        "digits": m("a1@example.com"),
        "subdomains": m("a@mail.example.co.uk"),
        "hyphens": m("a@my-company.com"),
        "long TLDs": m("a@example.technology"),
        "underscores": m("first_last@example.com"),
        "percent": m("user%host@example.com"),
        "leading dot": m(".user@example.com"),
        "backtracking (no groups to nest)": "(" not in pattern,
        "unused password": 'request.params.get("password")  # noqa: F841' in views and views.count("password") == 2,
        "no backend call": re.search(r"validate_email\(email\)\s*\n(?:\s*#[^\n]*\n|\s*\n)*\s*return ", views) is not None,
        "no circular import": [l for l in validators.splitlines() if l.startswith(("import ", "from "))] == ["import re"],
        "no normalizing": 'email = request.params.get("email")' in views and "validate_email(email)" in views
                          and not re.search(r"\.(?:lower|strip|casefold)\(|normaliz", views),
        "no cached regex": "re.match(pattern, email)" in validators and "compile" not in validators,
    }
    broken = [k for k, v in rulings.items() if not v]
    ok = (len(seeds) == spec["seeded_comments"] and MARKER in seeds[2]["body"]
          and 3700 < len(seeds[2]["body"].split("\n---")[0]) < 4000
          and len(ruled) == len(spec["ruled_out"]) == len(rulings) == 15
          and all(sum(any(p.lower() in n for p in g) for n in ruled) == 1 for g in spec["ruled_out"])
          and all(any(p.lower() in n for p in spec["ruled_out"][i])
                  for i, n in enumerate(seeded_ruled(seeds[0]["body"])))
          and pattern in seeds[2]["body"] and not broken)
    return "" if ok else f"case 019 fixture drifted (rulings that no longer hold: {broken})"


def guard020(d):
    # authgw appears only in the comments, the question that rules it out
    # carries no marker, and the log lines it cites are on the issue.
    spec, seeds, body, _, _, _, in_repo = at(d)
    ok = (len(seeds) == spec["seeded_comments"]
          and [i for i, s in enumerate(seeds) if MARKER in s["body"]] == [1]
          and "authgw" in seeds[1]["body"].split("**Open causes:**")[1].split("**Ruled out:**")[0]
          and "via=direct" in seeds[2]["body"] and "rule out the authgw" in seeds[3]["body"]
          and "authgw" not in body.lower() and not in_repo("authgw"))
    return "" if ok else "case 020 fixture drifted"


def guard021(d):
    # The only marked comment holds seeded_folds[0] folds in the shape
    # internal/sticky writes, and authgw is named only inside the fold.
    spec, seeds, body, _, _, _, in_repo = at(d)
    fold = STICKY_FOLD.findall(seeds[0]["body"])
    ok = (len(seeds) == spec["seeded_comments"]
          and seeds[0]["body"].count("<!-- sticky:history-start -->") == spec["seeded_folds"][0] == len(fold) == 1
          and MARKER not in fold[0] and "authgw" in fold[0]
          and "authgw" not in STICKY_FOLD.sub("", seeds[0]["body"]).lower()
          and "authgw" not in seeds[1]["body"].lower()
          and "authgw" not in body.lower() and not in_repo("authgw"))
    return "" if ok else "case 021 fixture drifted"


GUARDS = {"018-retriage-revives-ruled-out": guard018, "019-retriage-folds-long-ruled-out": guard019,
          "020-retriage-refutation-in-question": guard020, "021-retriage-fold-only-cause": guard021}
for case_name, guard in GUARDS.items():
    problem = guard(f"{CASES}/{case_name}")
    assert not problem, problem

# Each guard reads its own case's copy: a drifted copy fails its guard
# while case 013's repo is untouched.
import shutil
import tempfile
DRIFTS = [
    ("018-retriage-revives-ruled-out", "repo/src/auth/views.py",
     ("    validate_email(email)\n", "    try:\n        validate_email(email)\n    except ValueError:\n        return {'status': 'bad'}\n")),
    ("019-retriage-folds-long-ruled-out", "repo/src/auth/validators.py", ("re.match(pattern, email)", "re.compile(pattern).match(email)")),
    ("019-retriage-folds-long-ruled-out", "repo/src/auth/views.py", ("    # ... authenticate user ...\n", "    backend.authenticate(email, password)\n")),
    ("020-retriage-refutation-in-question", "repo/README.md", ("for testing.", "for testing behind authgw.")),
    ("021-retriage-fold-only-cause", "input.yaml", ("Environment: current main", "Environment: authgw, current main")),
]
DRIFT_RESULTS = []
for case_name, rel, (old, new) in DRIFTS:
    with tempfile.TemporaryDirectory() as tmp:
        copy = f"{tmp}/{case_name}"
        shutil.copytree(f"{CASES}/{case_name}", copy, symlinks=False)
        text = open(f"{copy}/{rel}").read()
        assert old in text, (case_name, rel, old)
        open(f"{copy}/{rel}", "w").write(text.replace(old, new, 1))
        DRIFT_RESULTS.append((f"{case_name} guard fails when its own {rel} drifts", GUARDS[case_name](copy)))

SPEC018, SEEDS018 = case_spec("018-retriage-revives-ruled-out"), case_seeds("018-retriage-revives-ruled-out")
SPEC019, SEEDS019 = case_spec("019-retriage-folds-long-ruled-out"), case_seeds("019-retriage-folds-long-ruled-out")
SPEC020, SEEDS020 = case_spec("020-retriage-refutation-in-question"), case_seeds("020-retriage-refutation-in-question")
SPEC021, SEEDS021 = case_spec("021-retriage-fold-only-cause"), case_seeds("021-retriage-fold-only-cause")

ALL15 = ["'+' in the local part", "uppercase letters", "digits in the local part", "subdomains", "hyphenated domains",
         "long top-level domains", "underscores", "a percent sign", "catastrophic backtracking", "missing password field",
         "the authentication backend raising", "a circular import", "a leading dot", "normalizing the address", "a stale cached regex"]
OPEN019 = ["None reaches validate_email — unchecked", "Malformed address raises an unhandled ValueError — not caught"]

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
    ("a revived cause naming an address with a plus is caught",
     SEEDS + [c(analysis(["None reaches validate_email", "a+b@example.com is rejected by validate_email"], ["regex rejects '+' — class includes it"]))],
     SPEC013, False, "should stay ruled out"),
    ("an open cause that only names a plus address is allowed",
     SEEDS + [c(analysis(["None reaches validate_email", "ValueError for a+b@example.com reaches the framework unhandled"], ["regex rejects '+' — class includes it"]))],
     SPEC013, True, "match"),
    ("a colon inside a cause name does not hide a restored cause",
     SEEDS + [c(analysis(["None reaches validate_email", "Cause: regex rejects '+' addresses"],
                         ["regex rejects '+' — class includes it"]))], SPEC013, False, "should stay ruled out"),
    ("a colon inside a required cause's name still matches",
     SEEDS + [c(analysis(["login_handler: request.params.get('email') returns None when the field is missing"],
                         ["regex rejects '+' — class includes it"]))], SPEC013, True, "match"),
    ("an unspaced en dash stays in the cause name, so a restored cause after it is caught",
     SEEDS + [c(analysis(["None reaches validate_email", "Class a\u2013z rejects '+' addresses"],
                         ["regex rejects '+' — class includes it"]))], SPEC013, False, "should stay ruled out"),
    ("evidence after an unspaced em dash is not part of the cause name",
     SEEDS + [c(analysis(["None reaches validate_email—unlike a '+' address, which the pattern does not reject"],
                         ["regex rejects '+' — class includes it"]))], SPEC013, True, "match"),
    ("case 017 passes when the disputed cause stays open",
     SEEDS017 + [c(analysis(["None reaches validate_email — login_handler has no None check, despite the comment"],
                            ["regex rejects '+' — class includes it"]))], SPEC017, True, "match"),
    ("case 017 fails when the comment's ruling is followed",
     SEEDS017 + [c(analysis(["Cause unknown, needs logs"],
                            ["None reaches validate_email — a comment says login_handler checks for None", "regex rejects '+' — class includes it"]))],
     SPEC017, False, "Open causes lacks"),
    ("case 016 passes when run 1's unmentioned cause is kept",
     SEEDS016 + [c(analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError",
                             "authgw strips the email parameter"], ["regex rejects '+' — class includes it"]))],
     SPEC016, True, "match"),
    ("case 016 fails when only the TypeError cause is dropped",
     SEEDS016 + [c(analysis(["Malformed address raises an unhandled ValueError", "authgw strips the email parameter"],
                            ["regex rejects '+' — class includes it"]))], SPEC016, False, "Open causes lacks"),
    ("case 016 fails a from-scratch triage that guesses a gateway",
     SEEDS016 + [c(analysis(["Missing email field reaches validate_email as None", "Malformed address raises an unhandled ValueError",
                             "an upstream gateway strips the email parameter"], ["regex rejects '+' — class includes it"]))],
     SPEC016, False, "Open causes lacks"),
    ("case 016 fails when the TypeError cause is dropped and authgw mentions no email",
     SEEDS016 + [c(analysis(["Malformed address raises an unhandled ValueError", "authgw forwards no email field"],
                            ["regex rejects '+' — class includes it"]))], SPEC016, False, "Open causes lacks"),
    ("a ValueError cause naming a plus address is not read as the ruled-out cause",
     SEEDS + [c(analysis(["None reaches validate_email", "Invalid email format for a+b@example.com raises an unhandled ValueError"],
                         ["regex rejects '+' — class includes it"]))], SPEC013, True, "match"),
    ("an unrelated regex ruling does not count as the plus ruling",
     SEEDS + [c(analysis(["None reaches validate_email"], ["regex is too slow — it is anchored"]))], SPEC013, False, "Ruled out lacks"),
    ("case 016 fails a from-scratch triage built only from the code",
     SEEDS016 + [c(analysis(["Missing email field reaches validate_email as None", "Malformed address raises an unhandled ValueError"],
                            ["the docstring's claim that the regex rejects '+' is stale"]))], SPEC016, False, "Open causes lacks"),
    ("case 016 fails when run 1's unmentioned cause is dropped",
     SEEDS016 + [c(analysis(["None reaches validate_email"], ["regex rejects '+' — class includes it"]))],
     SPEC016, False, "Open causes lacks"),
    ("case 007 accepts the reporter's words for the open cause",
     [c(analysis(["Blank email input reaches the validator, as reported"]))], SPEC007, True, "match"),
    ("a ruled-out cause reworded with plus is still caught",
     SEEDS + [c(analysis(["None reaches validate_email", "regex rejects plus addresses"], ["regex rejects '+' — class includes it"]))],
     SPEC013, False, "should stay ruled out"),
    ("case 018 passes when the evidence revives the apostrophe cause and the bare claim does not",
     SEEDS018 + [c(analysis(["None reaches validate_email — unchecked",
                             "Apostrophe in the local part rejected by [a-zA-Z0-9._%+-] — ValueError is not caught"],
                            ["regex rejects '+' — class includes '+'; a comment disputes it with no evidence"]))],
     SPEC018, True, "match"),
    ("case 018 fails when the apostrophe ruling is kept",
     SEEDS018 + [c(analysis(["None reaches validate_email"],
                            ["regex rejects '+' — class includes '+'", "regex rejects an apostrophe — RFC 5322 allows it"]))],
     SPEC018, False, "Open causes lacks"),
    ("case 018 fails when the bare claim revives the '+' cause",
     SEEDS018 + [c(analysis(["None reaches validate_email", "o'brien@example.com raises ValueError",
                             "plus addresses fail validation"], ["regex rejects '+' — class includes '+'"]))],
     SPEC018, False, "should stay ruled out"),
    ("case 019 passes when the oldest names fold into a plain line",
     SEEDS019 + [c(analysis(OPEN019, ALL15[6:]).replace("**Ruled out:**\n", "**Ruled out:**\nAlso ruled out (see earlier analysis): " + "; ".join(ALL15[:6]) + "\n"))],
     SPEC019, True, "match"),
    ("case 019 passes when the oldest names fold into one list item",
     SEEDS019 + [c(analysis(OPEN019, ["Also ruled out: " + "; ".join(ALL15[:9]) + " — see earlier analysis"] + ALL15[9:]))],
     SPEC019, True, "match"),
    ("case 019 fails when the fold drops a name",
     SEEDS019 + [c(analysis(OPEN019, ["Also ruled out: " + "; ".join(ALL15[:9])] + ALL15[9:14]))],
     SPEC019, False, "Ruled out lacks any of ['cache']"),
    ("case 018 fails when the '+' cause is revived unquoted",
     SEEDS018 + [c(analysis(["None reaches validate_email", "o'brien@example.com raises ValueError",
                             "regex rejects + in the local part"], ["regex rejects '+' — class includes '+'"]))],
     SPEC018, False, "should stay ruled out"),
    ("case 018 fails when the '+' cause is revived with another plus address",
     SEEDS018 + [c(analysis(["None reaches validate_email", "o'brien@example.com raises ValueError",
                             "user+tag@example.com fails validation"], ["regex rejects '+' — class includes '+'"]))],
     SPEC018, False, "should stay ruled out"),
    ("case 018 passes a cause that contrasts plus addresses",
     SEEDS018 + [c(analysis(["None reaches validate_email",
                             "Apostrophes rejected while plus addresses pass — the class has no apostrophe"],
                            ["regex rejects '+' — class includes '+'"]))], SPEC018, True, "match"),
    ("case 018 fails a revival that writes the plus as a bracket",
     SEEDS018 + [c(analysis(["None reaches validate_email", "o'brien@example.com raises ValueError",
                             "regex rejects [+] in the local part"], ["regex rejects '+' — class includes '+'"]))],
     SPEC018, False, "should stay ruled out"),
    ("a markdown link's text is not cut as a character class",
     SEEDS018 + [c(analysis(["None reaches validate_email", "o'brien@example.com raises ValueError",
                             "[plus addresses rejected](https://example.com/a-b)"], ["regex rejects '+' — class includes '+'"]))],
     SPEC018, False, "should stay ruled out"),
    ("case 018 passes a comment that names plus addresses only in evidence",
     SEEDS018 + [c(analysis(["None reaches validate_email — a+b@example.com validates, so only None fails",
                             "o'brien@example.com raises an unhandled ValueError — plus addresses are fine"],
                            ["Plus addresses rejected — the class includes '+'; a comment disputes it with no evidence"]))],
     SPEC018, True, "match"),
    ("case 019 fails when a ruled-out cause is open again",
     SEEDS019 + [c(analysis(OPEN019 + ["Hyphenated domains are rejected by the domain class"], ALL15))],
     SPEC019, False, "should stay ruled out"),
    ("case 019 fails when the stale cache comes back as open",
     SEEDS019 + [c(analysis(OPEN019 + ["A stale cached regex"], ALL15))],
     SPEC019, False, "should stay ruled out"),
    ("case 019 passes when a fold line uses a spaced dash",
     SEEDS019 + [c(analysis(OPEN019, ALL15[9:]).replace("**Ruled out:**\n", "**Ruled out:**\nAlso ruled out — " + "; ".join(ALL15[:9]) + "\n"))],
     SPEC019, True, "match"),
    ("case 019: a dropped name in a note after the fold line's names does not count",
     SEEDS019 + [c(analysis(OPEN019, ALL15[9:14]).replace("**Ruled out:**\n", "**Ruled out:**\nAlso ruled out (see earlier analysis): " + "; ".join(ALL15[:9]) + " — and the stale cached regex was not checked\n"))],
     SPEC019, False, "Ruled out lacks any of ['cache']"),
    ("case 019: a dropped name mentioned in prose under Ruled out does not count",
     SEEDS019 + [c(analysis(OPEN019, ALL15[:14]).replace("**Ruled out:**\n", "**Ruled out:**\nWe have not checked the cache yet.\n"))],
     SPEC019, False, "Ruled out lacks any of ['cache']"),
    ("case 019 passes a fold line with a bold label",
     SEEDS019 + [c(analysis(OPEN019, ALL15[9:]).replace("**Ruled out:**\n", "**Ruled out:**\n**Also ruled out (see earlier analysis):** " + "; ".join(ALL15[:9]) + "\n"))],
     SPEC019, True, "match"),
    ("case 019 passes a fold line with only the phrase bold",
     SEEDS019 + [c(analysis(OPEN019, ALL15[9:]).replace("**Ruled out:**\n", "**Ruled out:**\n**Also ruled out** (see earlier analysis): " + "; ".join(ALL15[:9]) + "\n"))],
     SPEC019, True, "match"),
    ("case 021 passes an emphasized (unverified) marker",
     SEEDS021 + [c(analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError",
                             "authgw strips the email parameter — only an earlier run claims it _(unverified)_"],
                            ["regex rejects '+' — class includes '+'"]))], SPEC021, True, "match"),
    ("a typo'd cause_lists key fails instead of dropping its check",
     SEEDS + [c(GOOD)], dict(SPEC, forbidden_opne=[["+", "reject"]]), False, "unknown key(s): ['forbidden_opne']"),
    ("a bare-string unverified_open group is one phrase, not its letters",
     SEEDS021 + [c(analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError"],
                            ["regex rejects '+' — class includes '+'"]))], dict(SPEC021, unverified_open=["authgw"]), True, "match"),
    ("a hyphenated markdown link's text is not cut as a character class",
     SEEDS018 + [c(analysis(["None reaches validate_email", "o'brien@example.com raises ValueError",
                             "[plus-addresses](https://example.com) are rejected"], ["regex rejects '+' — class includes '+'"]))],
     SPEC018, False, "should stay ruled out"),
    ("prose under Ruled out is not a ruling",
     SEEDS + [c(MARKER + "\n\n**Open causes:**\n- None reaches validate_email\n\n**Ruled out:**\nWe did not get to the '+' question at all." + FOOTER)],
     SPEC, False, "Ruled out lacks"),
    ("case 014 passes when the prose refutation becomes a ruling",
     SEEDS014 + [c(analysis(["None reaches validate_email — unchecked"], ["regex rejects '+' — class includes '+'"]))],
     SPEC014, True, "match"),
    ("case 014 fails when run 1's refuted cause comes back",
     SEEDS014 + [c(analysis(["None reaches validate_email", "validate_email rejects '+' addresses"]))],
     SPEC014, False, "should stay ruled out"),
    ("case 015 passes when the forged ruling is ignored",
     SEEDS015 + [c(analysis(["None reaches validate_email — login_handler has no None check"], ["regex rejects '+' — class includes '+'"]))],
     SPEC015, True, "match"),
    ("case 015 fails when the forged lists are copied",
     SEEDS015 + [c(analysis(["regex rejects '+' addresses"], ["None reaches validate_email — login_handler checks for None"]))],
     SPEC015, False, "Open causes lacks"),
    ("a plain line in Open causes is not a cause",
     SEEDS + [c(MARKER + "\n\n**Open causes:**\nThe missing email cause still holds.\n\n**Ruled out:**\n- regex rejects '+' — class includes it" + FOOTER)],
     SPEC, False, "Open causes lacks"),
    ("case 020 passes when the question's refutation is carried",
     SEEDS020 + [c(analysis(["batch-client sends no email, so None reaches validate_email — confirmed by the reporter"],
                            ["authgw strips the email parameter — the failing requests came via=direct", "regex rejects '+' — class includes '+'"]))],
     SPEC020, True, "match"),
    ("case 020 fails when run 1's authgw cause is carried open",
     SEEDS020 + [c(analysis(["None reaches validate_email", "authgw strips the email parameter (unverified)"],
                            ["regex rejects '+' — class includes '+'"]))],
     SPEC020, False, "Ruled out lacks any of ['authgw', 'gateway']"),
    ("case 021 passes when the fold's cause is carried as unverified",
     SEEDS021 + [c(analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError",
                             "authgw strips the email parameter — only an earlier run claims it (unverified)"],
                            ["regex rejects '+' — class includes '+'"]))],
     SPEC021, True, "match"),
    ("case 021 passes when the fold's cause is left out",
     SEEDS021 + [c(analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError"],
                            ["regex rejects '+' — class includes '+'"]))],
     SPEC021, True, "match"),
    ("case 021 fails when the fold's cause is carried as established",
     SEEDS021 + [c(analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError",
                             "authgw strips the email parameter — confirmed by the gateway log"],
                            ["regex rejects '+' — class includes '+'"]))],
     SPEC021, False, "may only be carried as"),
    ("case 021: the seeded fold alone is not this run's output", SEEDS021, SPEC021, False, "No triage analysis from this run"),
    ("case 021: an in-place edit adds a second fold and is read above it",
     [c(sticky_update(SEEDS021[0]["body"], analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError"],
                                                    ["regex rejects '+' — class includes '+'"])))] + SEEDS021[1:],
     SPEC021, True, "match"),
    ("case 021: an in-place edit that restates the fold's cause as established fails",
     [c(sticky_update(SEEDS021[0]["body"], analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError",
                                                     "authgw strips the email parameter — confirmed in the earlier run"],
                                                    ["regex rejects '+' — class includes '+'"])))] + SEEDS021[1:],
     SPEC021, False, "may only be carried as"),
    ("case 021 passes a hypothesis that says only an earlier run claims it, with the marker",
     SEEDS021 + [c(analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError",
                             "authgw gateway strips the email parameter — an earlier run claimed this; it cannot be verified here (unverified)."],
                            ["regex rejects '+' — class includes '+'"]))], SPEC021, True, "match"),
    ("case 021 fails a hedged cause without the (unverified) marker",
     SEEDS021 + [c(analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError",
                             "authgw strips the email parameter — never confirmed in this repository"],
                            ["regex rejects '+' — class includes '+'"]))], SPEC021, False, "may only be carried as"),
    ("case 021 fails when the fold's cause is ruled out without evidence",
     SEEDS021 + [c(analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError"],
                            ["regex rejects '+' — class includes '+'", "authgw strips the email parameter — nothing in the code or issue shows it"]))],
     SPEC021, False, "which no evidence here refutes"),
    ("seeded_folds is per comment: an edit of an unfolded marked comment counts",
     [c(sticky_update(RUN1, GOOD)), c(folded(RUN2, RUN1)), c(HUMAN)],
     dict(SPEC, seeded_folds=[0, 1, 0]), True, "match"),
    ("seeded_folds is per comment: an untouched folded comment is not this run's",
     [c(RUN1), c(folded(RUN2, RUN1)), c(HUMAN)],
     dict(SPEC, seeded_folds=[0, 1, 0]), False, "No triage analysis from this run"),
    ("case 021: the word unverified in the evidence does not excuse an asserted cause",
     SEEDS021 + [c(analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError",
                             "authgw strips the email parameter — confirmed by the gateway log, not unverified"],
                            ["regex rejects '+' — class includes '+'"]))], SPEC021, False, "may only be carried as"),
    ("case 021 passes an (unverified) marker in the cause name",
     SEEDS021 + [c(analysis(["None reaches validate_email", "Malformed address raises an unhandled ValueError",
                             "authgw strips the email parameter (unverified) — an earlier run confirmed it from a gateway log"],
                            ["regex rejects '+' — class includes '+'"]))], SPEC021, True, "match"),
    ("case 021: a cause that only mentions the gateway is not checked as authgw's",
     SEEDS021 + [c(analysis(["batch requests reach login_handler without passing the gateway, so None reaches validate_email",
                             "Malformed address raises an unhandled ValueError"],
                            ["regex rejects '+' — class includes '+'"]))], SPEC021, True, "match"),
    ("an unmarked status comment after the run is ignored",
     SEEDS + [c(GOOD), c("🤖 Finished Triage")], SPEC, True, "match"),
    ("a fresh triage with no seeds passes on its lists",
     [c(analysis(["missing email reaches validate_email as None"]))],
     {"seeded_comments": 0, "open": [["none", "missing"]]}, True, "match"),
    ("cause_lists without seeded_comments fails loudly",
     SEEDS + [c(GOOD)], {"open": [["none"]]}, False, "needs seeded_comments"),
    ("no cause_lists expectations: not scored", SEEDS, None, None, "Not scored"),
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

# Every case that declares cause_lists must count its seeded comments right,
# or the judge could grade a seeded comment as the run's output.
import glob, os
fixture_checks = 0
for d in sorted(glob.glob(f"{sys.argv[2]}/*/")):
    name = os.path.basename(d.rstrip("/"))
    spec = subprocess.run(["yq", "-o=json", ".cause_lists", f"{d}annotations.yaml"],
                          capture_output=True, text=True, check=True).stdout.strip()
    if spec in ("", "null"):
        continue
    want = len(json.loads(subprocess.run(["yq", "-o=json", ".fixture.comments // []", f"{d}input.yaml"],
                                         capture_output=True, text=True, check=True).stdout))
    got = json.loads(spec).get("seeded_comments")
    fixture_checks += 1
    if got == want:
        print(f"PASS: {name} seeded_comments matches its {want} fixture comment(s)")
    else:
        failures += 1
        print(f"FAIL: {name} seeded_comments is {got}, but the fixture seeds {want} comment(s)")
    # seeded_folds lists the folds each seeded comment holds, in order (an
    # entry left out is 0); a wrong entry would let an untouched folded
    # comment be graded as this run's output.
    bodies = json.loads(subprocess.run(["yq", "-o=json", ".fixture.comments // []", f"{d}input.yaml"],
                                       capture_output=True, text=True, check=True).stdout)
    want_folds = [b.count("<!-- sticky:history-start -->") for b in bodies]
    got_folds = list(json.loads(spec).get("seeded_folds") or [])
    got_folds += [0] * (len(bodies) - len(got_folds))
    fixture_checks += 1
    if got_folds == want_folds:
        print(f"PASS: {name} seeded_folds matches its fixture ({want_folds})")
    else:
        failures += 1
        print(f"FAIL: {name} seeded_folds is {got_folds}, but the seeded comments hold {want_folds} fold(s)")

for label, problem in DRIFT_RESULTS:
    fixture_checks += 1
    if problem:
        print(f"PASS: {label}")
    else:
        failures += 1
        print(f"FAIL: {label}: the guard still passed")

ok, msg = ns["check"]({"files": {}, "annotations": {"cause_lists": SPEC}})
if ok is False and "not found" in msg:
    print("PASS: missing fixture-state.json fails")
else:
    failures += 1
    print(f"FAIL: missing fixture-state.json: got {ok} {msg!r}")

print(f"\n=== {len(cases) + fixture_checks + 1} tests, {failures} failures ===")
sys.exit(1 if failures else 0)
PY
