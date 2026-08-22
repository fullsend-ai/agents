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
    "VerboseLogging": {"config/config.go": 1, "config/fields.go": 1, "config/config_test.go": 1},
    "verbose_logging": {"config/config.go": 1, "config/fields.go": 1, "config/config_test.go": 1},
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
        if line.strip():
            if indent is None:
                indent = len(line) - len(line.lstrip())
            if (len(line) - len(line.lstrip())) < indent:
                break
        body.append(line)

    if not body:
        sys.exit(f"FAIL: removed_symbols judge in {path} has no check body")

    source = "def _check(outputs):\n" + textwrap.indent(textwrap.dedent("\n".join(body)), "    ")
    namespace = {}
    exec(source, namespace)  # noqa: S102 - executing our own shipped judge is the point
    return namespace["_check"]


def hunk(path, *lines):
    # Real @@ counts: the judge trusts them to know when a hunk ends.
    old = sum(1 for l in lines if l[:1] in (" ", "-"))
    new = sum(1 for l in lines if l[:1] in (" ", "+"))
    return "\n".join([
        f"diff --git a/{path} b/{path}",
        "index 1111111..2222222 100644",
        f"--- a/{path}",
        f"+++ b/{path}",
        f"@@ -1,{old} +1,{new} @@",
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
    ("line comments in source may still mention the symbol",
     outputs_for("\n".join([
         COMPLETE,
         hunk("runner/runner.go", "+\t// VerboseLogging was removed in #7"),
         hunk("config/gen.mk", "+# verbose_logging is gone"),
     ])), True),
    # A bare "*" is a pointer deref in Go, not a comment marker: this line is
    # executable code and must read as a survivor.
    ("pointer deref is not a comment",
     outputs_for("\n".join([
         COMPLETE,
         hunk("runner/runner.go", "+\t*VerboseLogging = true"),
     ])), False),
    # Block-comment continuations are indistinguishable from a deref by
    # prefix, so they fail closed too — documented in the judge description.
    ("block-comment continuation fails closed",
     outputs_for("\n".join([
         COMPLETE,
         hunk("runner/runner.go", "+ * VerboseLogging is gone"),
     ])), False),
    # Comment markers are keyed by extension: "#" is not a comment in Go, and
    # an unknown extension gets no exemption at all.
    ("comment marker from another language is not exempt",
     outputs_for("\n".join([
         COMPLETE,
         hunk("runner/runner.go", "+\t# verbose_logging"),
     ])), False),
    ("unknown extension gets no comment exemption",
     outputs_for("\n".join([
         COMPLETE,
         hunk("config/testdata/sample.cfg", "+# verbose_logging: true"),
     ])), False),
    # Documentation is exempt wholesale: the markdown "-" bullet and plain
    # prose have no comment prefix, yet documenting the removal is correct.
    ("README bullet and prose may mention the symbol",
     outputs_for("\n".join([
         COMPLETE,
         hunk("README.md", "+- Removed the unused verbose_logging option (VerboseLogging field).",
              "+The verbose_logging key is no longer supported."),
         hunk("docs/config.rst", "+VerboseLogging was dropped."),
     ])), True),
    # A surviving literal in a non-doc data file is still a survivor even
    # though it is not a declared site.
    ("survivor in an undeclared yaml fixture",
     outputs_for("\n".join([
         COMPLETE,
         hunk("config/testdata/full.yaml", " verbose_logging: true"),
     ])), False),
    # A known source extension is never documentation, wherever it lives,
    # and "docs" has to be a real directory segment, not a substring.
    ("source file under a docs directory is still scanned",
     outputs_for("\n".join([
         COMPLETE,
         hunk("pkg/docs/gen.go", "+\tcfg.VerboseLogging = true"),
     ])), False),
    ("yaml under docs is still scanned",
     outputs_for("\n".join([
         COMPLETE,
         hunk("docs/examples/config.yaml", "+verbose_logging: true"),
     ])), False),
    ("docs substring in a path is not a docs directory",
     outputs_for("\n".join([
         COMPLETE,
         hunk("cmd/gendocs/main.cfg", "+VerboseLogging=true"),
     ])), False),
    # Hunk counts are honoured: content beginning with "--"/"++" is content.
    ("deleted SQL comment line counts as a deletion",
     outputs_for("\n".join([
         DELETE_CONFIG, DELETE_FIELDS, DELETE_TEST,
         hunk("db/migrate.sql", "--- VerboseLogging column", " CREATE TABLE t;"),
     ]), symbols={**SYMBOLS, "VerboseLogging": {**SYMBOLS["VerboseLogging"],
                                                 "db/migrate.sql": 1}}), True),
    ("added line starting with ++ cannot rebind the file mid-hunk",
     outputs_for("\n".join([
         DELETE_FIELDS, DELETE_TEST,
         hunk("config/config.go",
              '-\tVerboseLogging bool `yaml:"verbose_logging"`',
              "-verbose_logging: x",
              "+++ b/NOTES.md",
              "+\tcfg.VerboseLogging = true"),
     ])), False),
    # One deletion line per file is not enough when the file has more sites:
    # the second occurrence sits outside every hunk and is otherwise unseen.
    ("fewer deletion lines than declared sites",
     outputs_for(COMPLETE, symbols={**SYMBOLS, "VerboseLogging": {
         **SYMBOLS["VerboseLogging"], "config/config.go": 2}}), False),
    ("extra deletion lines beyond the declared count are fine",
     outputs_for("\n".join([
         hunk("config/config.go",
              "-\t// VerboseLogging enables detailed debug output.",
              '-\tVerboseLogging bool `yaml:"verbose_logging"`',
              "-\t\tVerboseLogging: false,"),
         DELETE_FIELDS, DELETE_TEST,
     ]), symbols={**SYMBOLS, "VerboseLogging": {
         **SYMBOLS["VerboseLogging"], "config/config.go": 2}}), True),
    # Whole-file deletion: git emits "+++ /dev/null", so the lines must be
    # attributed to the "--- a/" path or the declared file looks untouched.
    ("whole-file deletion satisfies the declared file",
     outputs_for("\n".join([
         DELETE_CONFIG, DELETE_FIELDS,
         "diff --git a/config/config_test.go b/config/config_test.go",
         "deleted file mode 100644",
         "index 2222222..0000000",
         "--- a/config/config_test.go",
         "+++ /dev/null",
         "@@ -1,3 +0,0 @@",
         "-verbose_logging: true",
         "-\tif cfg.VerboseLogging != true {",
         "-}",
     ])), True),
    ("no removed_symbols declared passes trivially",
     outputs_for(DELETE_CONFIG, symbols={}), True),
    # The pre-per-file schema is a bare list; accepting it silently would
    # reinstate the gap this judge closes.
    ("legacy list schema is rejected rather than ignored",
     outputs_for(DELETE_CONFIG, symbols=["VerboseLogging"]), False),
    # Per-symbol values are validated too: a null, empty or list value would
    # otherwise iterate nothing and silently drop the per-file requirement,
    # and a scalar would crash the judge.
    ("null file map is rejected", outputs_for(COMPLETE, symbols={"VerboseLogging": None}), False),
    ("empty file map is rejected", outputs_for(COMPLETE, symbols={"VerboseLogging": {}}), False),
    ("file list without counts is rejected",
     outputs_for(COMPLETE, symbols={"VerboseLogging": ["config/config.go"]}), False),
    ("scalar file map is rejected", outputs_for(COMPLETE, symbols={"VerboseLogging": 5}), False),
    ("zero deletion count is rejected",
     outputs_for(COMPLETE, symbols={"VerboseLogging": {"config/config.go": 0}}), False),
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
