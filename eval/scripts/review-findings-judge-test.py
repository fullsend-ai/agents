#!/usr/bin/env python3
# review-findings-judge-test.py — Behaviour tests for eval/review/eval.yaml's
# required_findings and forbidden_findings judges.
#
# The judges are Python embedded in YAML, so they have no import site of their
# own. This test extracts the shipped check bodies straight from eval.yaml and
# runs them against synthetic review_comments payloads, which keeps the test
# from drifting from the code and needs no YAML parser (CI installs neither
# pyyaml nor ruamel).
#
# Usage:
#   python3 eval/scripts/review-findings-judge-test.py

import json
import os
import sys
import textwrap

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EVAL_YAML = os.path.join(REPO_ROOT, "eval", "review", "eval.yaml")


def load_judge(path, name):
    """Return the named judge's check body as a callable taking `outputs`."""
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    try:
        start = lines.index(f"  - name: {name}")
    except ValueError:
        sys.exit(f"FAIL: no {name} judge found in {path}")

    body, collecting, indent = [], False, None
    for line in lines[start:]:
        if not collecting:
            if line.strip() == "check: |":
                collecting = True
            continue
        if line.strip():
            if indent is None:
                indent = len(line) - len(line.lstrip())
            if (len(line) - len(line.lstrip())) < indent:
                break
        body.append(line)

    if not body:
        sys.exit(f"FAIL: {name} judge in {path} has no check body")

    source = "def _check(outputs):\n" + textwrap.indent(textwrap.dedent("\n".join(body)), "    ")
    namespace = {}
    exec(source, namespace)  # noqa: S102 - executing our own shipped judge is the point
    return namespace["_check"]


# --- fixture builders -------------------------------------------------------

def finding(path, severity, category, description="", line=12):
    """A review comment as postreview.go's formatFindingComment renders it."""
    body = f"**[{severity}]** {category}"
    if description:
        body += f"\n\n{description}"
    return {"path": path, "line": line, "body": body}


def file_level_finding(path, severity, category, description="", line=12):
    """The 422 fallback: file-level comment, body prefixed with the line."""
    c = finding(path, severity, category, description, line)
    c["line"] = None
    c["body"] = f"_Line {line}_ · {c['body']}"
    return c


def outputs_for(entries, comments, key, state_extra=None, state=None):
    if state is None:
        state = {"review_comments": comments, "review_comments_fetch_failed": False}
        if state_extra:
            state.update(state_extra)
    return {
        "annotations": {key: entries},
        "files": {"output/fixture-state.json": json.dumps(state)},
    }


SQLI = finding(
    "src/orders/repository.py", "high", "injection-vuln",
    "order_id is interpolated into the query string — SQL injection.",
)
TIMING = finding(
    "src/auth/session.py", "medium", "auth-bypass",
    "Plain == on the MAC leaks it through a timing side channel.",
)
PRICING = finding(
    "src/orders/pricing.py", "high", "logic-error",
    "apply_discount lost its / 100 divisor; every total is ~100x too large.",
)
ALL_THREE = [SQLI, TIMING, PRICING]

REQUIRED_THREE = [
    {"file": "src/orders/repository.py", "category": "injection", "min_severity": "high"},
    {"file": "src/auth/session.py", "category": "timing", "min_severity": "medium"},
    {"file": "src/orders/pricing.py", "category": "apply_discount", "min_severity": "high"},
]


def req(entries, comments, **kw):
    return outputs_for(entries, comments, "required_findings", **kw)


def forb(entries, comments, **kw):
    return outputs_for(entries, comments, "forbidden_findings", **kw)


# --- cases ------------------------------------------------------------------
# (name, judge_name, outputs, expected_pass)

CASES = [
    # --- required_findings: matching ---------------------------------------
    ("required: all three seeded bugs found", "required_findings",
     req(REQUIRED_THREE, ALL_THREE), True),
    ("required: passes trivially when none declared", "required_findings",
     req([], ALL_THREE), True),
    ("required: empty category matches any finding on the file", "required_findings",
     req([{"file": "src/orders/pricing.py", "category": ""}], ALL_THREE), True),
    ("required: match may come from the description, not the category token",
     "required_findings",
     # The category token is "logic-error"; only the description says "divisor".
     req([{"file": "src/orders/pricing.py", "category": "divisor"}], ALL_THREE), True),
    ("required: the 422 file-level fallback body still parses", "required_findings",
     req([{"file": "src/orders/repository.py", "category": "injection",
           "min_severity": "high"}],
         [file_level_finding("src/orders/repository.py", "high", "injection-vuln",
                             "SQL injection via f-string.")]), True),
    ("required: severity case is normalised", "required_findings",
     req([{"file": "a.py", "category": "boom", "min_severity": "high"}],
         [finding("a.py", "HIGH", "boom")]), True),

    # --- required_findings: word boundaries --------------------------------
    # The removed_symbols bug class: a substring match would pass all of these.
    ("required: 'injection' is NOT satisfied by 'injections'", "required_findings",
     req([{"file": "a.py", "category": "injection"}],
         [finding("a.py", "high", "misc", "We reviewed the injections module.")]), False),
    ("required: 'hash' is NOT satisfied by 'hashicorp'", "required_findings",
     req([{"file": "a.py", "category": "hash"}],
         [finding("a.py", "high", "misc", "hashicorp vault client")]), False),
    ("required: 'discount' is NOT satisfied by 'discounted'", "required_findings",
     req([{"file": "a.py", "category": "discount"}],
         [finding("a.py", "high", "misc", "the discounted total")]), False),
    ("required: hyphenated token matches at a non-word edge", "required_findings",
     req([{"file": "a.py", "category": "injection-vuln"}],
         [finding("a.py", "high", "injection-vuln")]), True),
    ("required: multi-word phrase tolerates whitespace runs", "required_findings",
     req([{"file": "a.py", "category": "sql injection"}],
         [finding("a.py", "high", "misc", "a SQL\n   injection here")]), True),

    # --- required_findings: severity boundaries ----------------------------
    ("required: finding exactly at the floor counts", "required_findings",
     req([{"file": "a.py", "category": "boom", "min_severity": "medium"}],
         [finding("a.py", "medium", "boom")]), True),
    ("required: finding one notch below the floor does not", "required_findings",
     req([{"file": "a.py", "category": "boom", "min_severity": "medium"}],
         [finding("a.py", "low", "boom")]), False),
    ("required: floor defaults to info, so any severity counts", "required_findings",
     req([{"file": "a.py", "category": "boom"}], [finding("a.py", "info", "boom")]), True),
    ("required: an unknown severity never satisfies a requirement", "required_findings",
     req([{"file": "a.py", "category": "boom"}], [finding("a.py", "spicy", "boom")]), False),

    # --- required_findings: file matching ----------------------------------
    ("required: file paths are case-sensitive", "required_findings",
     req([{"file": "src/auth/session.py", "category": "timing"}],
         [finding("Src/Auth/Session.py", "high", "timing")]), False),
    ("required: a ./-prefixed path still matches", "required_findings",
     req([{"file": "a.py", "category": "boom"}], [finding("./a.py", "high", "boom")]), True),
    ("required: right finding on the wrong file is a miss", "required_findings",
     req([{"file": "src/orders/pricing.py", "category": "injection"}], ALL_THREE), False),

    # --- required_findings: capture failures fail closed -------------------
    ("required: empty comment list misses everything", "required_findings",
     req(REQUIRED_THREE, []), False),
    ("required: fetch failure is a failure, not an empty result", "required_findings",
     req(REQUIRED_THREE, [], state_extra={"review_comments_fetch_failed": True}), False),
    ("required: null review_comments fails", "required_findings",
     req(REQUIRED_THREE, None), False),
    ("required: non-list review_comments fails", "required_findings",
     req(REQUIRED_THREE, {"path": "a.py"}), False),
    ("required: review_comments absent (stale capture script) fails", "required_findings",
     req(REQUIRED_THREE, [], state={"labels": ["ready-for-merge"]}), False),
    ("required: missing fixture-state.json fails", "required_findings",
     {"annotations": {"required_findings": REQUIRED_THREE}, "files": {}}, False),
    ("required: non-finding comments are skipped, not parsed", "required_findings",
     req([{"file": "a.py", "category": "boom"}],
         [{"path": "a.py", "line": 1, "body": "Nice work on this one!"}]), False),

    # --- required_findings: annotation validation --------------------------
    ("required: a dict instead of a list fails loudly", "required_findings",
     req({"file": "a.py"}, ALL_THREE), False),
    ("required: a string entry fails loudly", "required_findings",
     req(["src/orders/pricing.py"], ALL_THREE), False),
    ("required: a null file fails loudly", "required_findings",
     req([{"file": None, "category": "boom"}], ALL_THREE), False),
    ("required: an empty file fails loudly", "required_findings",
     req([{"file": "   ", "category": "boom"}], ALL_THREE), False),
    ("required: a null category fails loudly (does not become 'any')",
     "required_findings",
     req([{"file": "src/orders/pricing.py", "category": None}], ALL_THREE), False),
    ("required: a list category fails loudly", "required_findings",
     req([{"file": "src/orders/pricing.py", "category": ["a", "b"]}], ALL_THREE), False),
    ("required: an out-of-vocabulary min_severity fails loudly", "required_findings",
     req([{"file": "src/orders/pricing.py", "category": "", "min_severity": "urgent"}],
         ALL_THREE), False),
    ("required: a typo'd key fails instead of silently defaulting",
     "required_findings",
     # min_sevirity would otherwise be ignored and the floor drop to info.
     req([{"file": "src/orders/pricing.py", "category": "", "min_sevirity": "high"}],
         ALL_THREE), False),

    # --- forbidden_findings: matching --------------------------------------
    ("forbidden: clean review raises nothing", "forbidden_findings",
     forb([{"file": "src/orders/receipts.py", "category": "hash"},
           {"file": "src/orders/receipts.py", "category": "command"}], []), True),
    ("forbidden: passes trivially when none declared", "forbidden_findings",
     forb([], [finding("src/orders/receipts.py", "critical", "weak-hash")]), True),

    # Unverifiable is not clean: postreview.go folds findings into the review
    # body on a 422 and drops findings with no file/line, so comments can
    # exist while no finding is visible here. Passing would let a promoted
    # bait through — the exact failure this judge exists to catch.
    ("forbidden: comments present but unparseable fails closed", "forbidden_findings",
     forb([{"file": "src/orders/receipts.py", "category": "hash"}],
          [{"path": "src/orders/receipts.py", "line": 12,
            "body": "Looks good to me, shipping."}]), False),
    ("forbidden: no comments at all still passes", "forbidden_findings",
     forb([{"file": "src/orders/receipts.py", "category": "hash"}], []), True),
    ("forbidden: MD5 bait flagged critical is a violation", "forbidden_findings",
     forb([{"file": "src/orders/receipts.py", "category": "hash"}],
          [finding("src/orders/receipts.py", "critical", "weak-hash",
                   "MD5 is a broken hash function.")]), False),
    ("forbidden: subprocess bait flagged high is a violation", "forbidden_findings",
     forb([{"file": "src/orders/receipts.py", "category": "command"}],
          [finding("src/orders/receipts.py", "high", "injection-vuln",
                   "Possible command injection via subprocess.run.")]), False),

    # --- forbidden_findings: word boundaries -------------------------------
    ("forbidden: 'command' is NOT tripped by 'commandeer'", "forbidden_findings",
     forb([{"file": "a.py", "category": "command"}],
          [finding("a.py", "critical", "misc", "do not commandeer the buffer")]), True),
    ("forbidden: 'hash' is NOT tripped by 'hashicorp'", "forbidden_findings",
     forb([{"file": "a.py", "category": "hash"}],
          [finding("a.py", "critical", "misc", "hashicorp vault client")]), True),

    # --- forbidden_findings: severity boundaries ---------------------------
    ("forbidden: floor defaults to high, so a low note is allowed",
     "forbidden_findings",
     forb([{"file": "a.py", "category": "hash"}],
          [finding("a.py", "low", "doc-style", "prefer sha256 for hash consistency")]),
     True),
    ("forbidden: medium is below the default high floor", "forbidden_findings",
     forb([{"file": "a.py", "category": "hash"}], [finding("a.py", "medium", "hash")]),
     True),
    ("forbidden: exactly at the floor is a violation", "forbidden_findings",
     forb([{"file": "a.py", "category": "hash"}], [finding("a.py", "high", "hash")]), False),
    ("forbidden: an explicit lower floor catches a low fabrication",
     "forbidden_findings",
     forb([{"file": "docs/api.md", "category": "", "min_severity": "low"}],
          [finding("docs/api.md", "low", "incomplete-doc")]), False),
    ("forbidden: an info note survives a 'low' floor", "forbidden_findings",
     forb([{"file": "docs/api.md", "category": "", "min_severity": "low"}],
          [finding("docs/api.md", "info", "doc-style")]), True),
    ("forbidden: an unknown severity trips (opposite fail-closed direction)",
     "forbidden_findings",
     forb([{"file": "a.py", "category": "hash"}], [finding("a.py", "spicy", "hash")]), False),

    # --- forbidden_findings: empty category / file scope -------------------
    ("forbidden: empty category forbids any finding on that file",
     "forbidden_findings",
     forb([{"file": "requirements.txt", "category": ""}],
          [finding("requirements.txt", "high", "breaking-config")]), False),
    ("forbidden: empty category does not reach other files", "forbidden_findings",
     forb([{"file": "requirements.txt", "category": ""}],
          [finding("setup.py", "critical", "breaking-config")]), True),

    # --- forbidden_findings: capture failures fail closed ------------------
    ("forbidden: fetch failure fails rather than reading as 'nothing posted'",
     "forbidden_findings",
     forb([{"file": "a.py", "category": "hash"}], [],
          state_extra={"review_comments_fetch_failed": True}), False),
    ("forbidden: null review_comments fails", "forbidden_findings",
     forb([{"file": "a.py", "category": "hash"}], None), False),
    ("forbidden: review_comments absent (stale capture script) fails",
     "forbidden_findings",
     forb([{"file": "a.py", "category": "hash"}], [], state={"labels": []}), False),

    # --- forbidden_findings: annotation validation -------------------------
    ("forbidden: a dict instead of a list fails loudly", "forbidden_findings",
     forb({"file": "a.py"}, []), False),
    ("forbidden: a null category fails loudly (does not become 'any')",
     "forbidden_findings",
     forb([{"file": "a.py", "category": None}], []), False),
    ("forbidden: an out-of-vocabulary min_severity fails loudly",
     "forbidden_findings",
     forb([{"file": "a.py", "category": "", "min_severity": "blocker"}], []), False),
    ("forbidden: a typo'd key fails instead of silently defaulting",
     "forbidden_findings",
     forb([{"file": "a.py", "category": "", "sevirity": "low"}], []), False),
]


def main():
    judges = {
        "required_findings": load_judge(EVAL_YAML, "required_findings"),
        "forbidden_findings": load_judge(EVAL_YAML, "forbidden_findings"),
    }

    failures = 0
    for name, judge_name, outputs, expected in CASES:
        try:
            passed, message = judges[judge_name](outputs)
        except Exception as exc:  # noqa: BLE001 - a crashing judge is a failure
            print(f"FAIL: {name}: judge raised {type(exc).__name__}: {exc}")
            failures += 1
            continue
        if bool(passed) != expected:
            want = "pass" if expected else "fail"
            print(f"FAIL: {name}: expected {want}, got {passed} — {message}")
            failures += 1

    if failures:
        print(f"\n{failures}/{len(CASES)} review findings judge tests failed")
        return 1
    print(f"All {len(CASES)} review findings judge tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
