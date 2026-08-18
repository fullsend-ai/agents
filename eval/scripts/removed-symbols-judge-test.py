#!/usr/bin/env python3
# removed-symbols-judge-test.py — Behaviour tests for eval/code/eval.yaml's
# removed_symbols judge.
#
# The judge is Python embedded in YAML, so it has no import site of its own.
# This test extracts the shipped check body straight from eval.yaml and runs it
# against synthetic diffs, which keeps the test from drifting from the code and
# needs no YAML parser (CI installs neither pyyaml nor ruamel).
#
# Usage:
#   python3 eval/scripts/removed-symbols-judge-test.py

import json
import os
import sys
import textwrap

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EVAL_YAML = os.path.join(REPO_ROOT, "eval", "code", "eval.yaml")

SYMBOLS = {
    "VerboseLogging": ["config/config.go", "config/fields.go", "config/config_test.go"],
    "verbose_logging": ["config/config.go", "config/fields.go", "config/config_test.go"],
}


def load_judge(path):
    """Return the removed_symbols check body as a callable taking `outputs`."""
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    try:
        start = lines.index("  - name: removed_symbols")
    except ValueError:
        sys.exit(f"FAIL: no removed_symbols judge found in {path}")

    body, collecting, indent = [], False, None
    for line in lines[start:]:
        if not collecting:
            if line.strip() == "check: |":
                collecting = True
            continue
        if line.strip() and indent is None:
            indent = len(line) - len(line.lstrip())
        if line.strip() and (len(line) - len(line.lstrip())) < indent:
            break
        body.append(line)

    if not body:
        sys.exit(f"FAIL: removed_symbols judge in {path} has no check body")

    source = "def _check(outputs):\n" + textwrap.indent(textwrap.dedent("\n".join(body)), "    ")
    namespace = {}
    exec(source, namespace)  # noqa: S102 - executing our own shipped judge is the point
    return namespace["_check"]


def hunk(path, *lines):
    return "\n".join([
        f"diff --git a/{path} b/{path}",
        "index 1111111..2222222 100644",
        f"--- a/{path}",
        f"+++ b/{path}",
        "@@ -1,6 +1,4 @@",
        *lines,
    ])


DELETE_CONFIG = hunk(
    "config/config.go",
    '-\tVerboseLogging bool `yaml:"verbose_logging"`',
    " \tName string",
)
DELETE_FIELDS = hunk(
    "config/fields.go",
    '-\tcase "verbose_logging":',
    "-\t\tc.VerboseLogging = v",
    '-\tcase "name":',
)
DELETE_TEST = hunk(
    "config/config_test.go",
    "-verbose_logging: true",
    "-\tif cfg.VerboseLogging != true {",
    ' \tif cfg.Name != "x" {',
)
COMPLETE = "\n".join([DELETE_CONFIG, DELETE_FIELDS, DELETE_TEST])


def outputs_for(diff, symbols=None, pr_state=None):
    if symbols is None:
        symbols = SYMBOLS
    if pr_state is None:
        pr_state = {"number": 7, "state": "OPEN", "diff_fetch_failed": False}
    return {
        "annotations": {"removed_symbols": symbols},
        "files": {
            "output/fixture-state.json": json.dumps({"pull_requests": [pr_state]}),
            "output/pr-7.diff": diff,
        },
    }


CASES = [
    ("complete removal across every declared file", outputs_for(COMPLETE), True),
    # The partial-removal gap: config_test.go is touched, but not on any line
    # mentioning the symbol, so its raw `verbose_logging: true` literal survives
    # outside the diff entirely. A global "deleted somewhere" count passes this.
    ("partial removal leaves a declared file untouched",
     outputs_for("\n".join([
         DELETE_CONFIG, DELETE_FIELDS,
         hunk("config/config_test.go", "-\tfoo := 1", " \tbar := 2"),
     ])), False),
    ("symbol survives on an added line",
     outputs_for("\n".join([
         DELETE_CONFIG, DELETE_FIELDS,
         hunk("config/config_test.go", "-verbose_logging: true",
              "+\tcfg.VerboseLogging = true"),
     ])), False),
    ("symbol survives on an unchanged context line",
     outputs_for("\n".join([
         DELETE_CONFIG, DELETE_FIELDS,
         hunk("config/config_test.go", "-verbose_logging: true",
              " \tif cfg.VerboseLogging != true {"),
     ])), False),
    # Metadata lines are not content: a rename to a path containing the symbol
    # must not read as a survivor.
    ("rename, mode and binary metadata naming the symbol",
     outputs_for("\n".join([
         COMPLETE,
         "diff --git a/config/VerboseLogging.go b/config/VerboseLoggingHandler.go",
         "similarity index 95%",
         "rename from config/VerboseLogging.go",
         "rename to config/VerboseLoggingHandler.go",
         "old mode 100644",
         "new mode 100755",
         "Binary files a/VerboseLogging.bin and b/x.bin differ",
     ])), True),
    ("renamed identifier that merely contains the symbol",
     outputs_for("\n".join([
         COMPLETE,
         hunk("config/other.go", "+\tVerboseLoggingEnabled bool", "+\tverbose_logging_v2 := 1"),
     ])), True),
    ("comment-only lines may still mention the symbol",
     outputs_for("\n".join([
         COMPLETE,
         hunk("CHANGELOG.md", "+# Removed unused VerboseLogging",
              "+// drop verbose_logging", "+ * VerboseLogging is gone"),
     ])), True),
    ("no removed_symbols declared passes trivially",
     outputs_for(DELETE_CONFIG, symbols={}), True),
    # The pre-per-file schema is a bare list; accepting it silently would
    # reinstate the gap this judge closes.
    ("legacy list schema is rejected rather than ignored",
     outputs_for(DELETE_CONFIG, symbols=["VerboseLogging"]), False),
    ("diff fetch failure is surfaced",
     outputs_for(COMPLETE, pr_state={"number": 7, "state": "OPEN", "diff_fetch_failed": True}),
     False),
    ("no open or merged PR to inspect",
     outputs_for(COMPLETE, pr_state={"number": 7, "state": "CLOSED"}), False),
]


def main():
    check = load_judge(EVAL_YAML)
    failures = 0
    for name, outputs, expect_pass in CASES:
        passed, message = check(outputs)
        ok = passed is expect_pass
        if not ok:
            failures += 1
            print(f"FAIL: {name} — expected {'pass' if expect_pass else 'fail'}, "
                  f"got {'pass' if passed else 'fail'}: {message}")
        else:
            print(f"ok: {name}")
    if failures:
        print(f"FAIL: {failures}/{len(CASES)} removed_symbols judge behaviours wrong")
        return 1
    print(f"All removed_symbols judge tests passed ({len(CASES)} cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
