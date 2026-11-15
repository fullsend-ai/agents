#!/usr/bin/env bash
# Tests for eval/review/eval.yaml's finding_expectations judge: categories
# must come from the evaluated run's write-up only — the current section of
# the review agent's sticky comment — never from formal reviews, other
# comments, or the sticky's previous-run history. The anchored
# must_report / must_not_raise checks take severity, category and file
# from that section's review-findings marker. Fully offline: the real
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
import base64
import json
import sys
import textwrap

ns = {}
exec("def check(outputs):\n" + textwrap.indent(open(sys.argv[1]).read(), "    "), ns)

MARKER = "<!-- fullsend:review-agent -->"
NOTICE = "<!-- fullsend:review-notice -->"
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
    # fullsend-ai/fullsend#9399: a run that only posted a stale-head or failure
    # notice (its own marker, no review-agent sticky) has no findings to judge.
    ("notice-only run is not scored",
     [comment(NOTICE + "\n## Review\n\n**Reason:** stale-head")], [],
     {"required": ["logic-error"]}, None, "only a review notice"),
    ("failure-notice-only run is not scored",
     [comment(NOTICE + "\n## Review\n\n**Reason:** agent-failure")], [],
     {"forbidden": ["logic-error"]}, None, "only a review notice"),
    ("a notice beside the run's review: the review is judged",
     [comment(NOTICE + "\n## Review\n\n**Reason:** stale-head"), sticky(LOGIC)], [],
     {"required": ["logic-error"]}, True, "Finding expectations met"),
    ("notice marker not on the first line is not a notice",
     [comment("Quoting:\n" + NOTICE)], [],
     {"required": ["logic-error"]}, False, "found 0"),
]


# --- must_report / must_not_raise: anchored on the review-findings marker ---
def projected(findings):
    payload = json.dumps({"version": 2, "action": "comment", "findings": findings})
    return "<!-- fullsend:review-findings-v2:" + base64.b64encode(payload.encode()).decode() + " -->"


def asticky(findings, bullets, *history):
    """Sticky whose marker projects `findings`; bullets are the prose."""
    body = MARKER + "\n" + projected(findings) + "\n\n## Review\n\n### Findings\n\n" + bullets
    for old in history:
        body += ("\n\n<details>\n<summary>Previous run</summary>\n\n"
                 "<!-- sticky:history-start -->\n" + old +
                 "\n<!-- sticky:history-end -->\n\n</details>")
    return {"author": "eval-bot", "body": body, "created_at": "2026-01-01T00:00:00Z"}


def f(file, category, severity, line=None):
    out = {"id": "f_x", "file": file, "category": category, "severity": severity}
    if line is not None:
        out["line"] = line
    return out


REPO = "src/orders/repository.py"
RECEIPTS = "src/orders/receipts.py"
SQLI = [f(REPO, "sql-query", "high", 9)]
SQLI_TEXT = "#### High\n\n- **[sql-query]** `src/orders/repository.py:9` — order_id reaches the query: SQL injection."
REPORT_SQLI = {"must_report": [{"file": REPO, "match": "injection", "min_severity": "high"}]}
BAIT = {"must_not_raise": [{"file": RECEIPTS, "match": "md5"}]}
MD5_NOTE = "- **[weak-crypto]** `src/orders/receipts.py:12` — hashlib.md5 is broken."
DOCS_ANY = {"must_not_raise": [{"file": "docs/api.md", "min_severity": "low"}]}

cases += [
    ("must_report: matched in the bullet, not the category token",
     [asticky(SQLI, SQLI_TEXT)], [], REPORT_SQLI, True, "1 anchored finding"),
    ("must_report: the category token alone can match",
     [asticky([f(REPO, "injection-vuln", "critical", 9)], "")], [], REPORT_SQLI, True, "anchored"),
    ("must_report: below the floor is not reported",
     [asticky([f(REPO, "sql-query", "medium", 9)], SQLI_TEXT)], [], REPORT_SQLI, False, "not_reported=["),
    ("must_report: a finding on another file does not count",
     [asticky([f("src/app.py", "sql-query", "high", 9)],
              "- **[sql-query]** `src/app.py:9` — SQL injection.")], [], REPORT_SQLI, False, "not_reported=["),
    ("must_report: whole words only (md5sum is not md5)",
     [asticky([f(RECEIPTS, "weak-crypto", "high", 12)],
              "- **[weak-crypto]** `src/orders/receipts.py:12` — md5sum of the payload.")], [],
     {"must_report": [{"file": RECEIPTS, "match": "md5"}]}, False, "not_reported=["),
    ("must_report: whole words only (rehash is not hash)",
     [asticky([f(RECEIPTS, "perf", "high", 12)],
              "- **[perf]** `src/orders/receipts.py:12` — rehash on every call.")], [],
     {"must_report": [{"file": RECEIPTS, "match": "hash"}]}, False, "not_reported=["),
    ("must_report: an indented Remediation line counts",
     [asticky([f("src/auth/session.py", "auth", "medium", 7)],
              "- **[auth]** `src/auth/session.py:7` — MAC compared with ==.\n"
              "  Remediation: use hmac.compare_digest.")], [],
     {"must_report": [{"file": "src/auth/session.py", "match": "timing | compare_digest",
                       "min_severity": "medium"}]}, True, "anchored"),
    ("must_report: a finding only in sticky history does not count",
     [asticky([], "Looks good to me", SQLI_TEXT)], [], REPORT_SQLI, False, "not_reported=["),
    ("must_report: a formal review cannot supply the finding",
     [asticky([], "Looks good to me")], [review(SQLI_TEXT, "CHANGES_REQUESTED")], REPORT_SQLI, False,
     "not_reported=["),
    ("must_not_raise: bait noted at low passes",
     [asticky([f(RECEIPTS, "weak-crypto", "low", 12)], MD5_NOTE)], [], BAIT, True, "anchored"),
    ("must_not_raise: bait promoted to high fails",
     [asticky([f(RECEIPTS, "weak-crypto", "high", 12)], MD5_NOTE)], [], BAIT, False, "raised=["),
    ("must_not_raise: same file and category, other line, other words",
     [asticky([f(RECEIPTS, "weak-crypto", "low", 12), f(RECEIPTS, "weak-crypto", "high", 30)],
              MD5_NOTE + "\n- **[weak-crypto]** `src/orders/receipts.py:30` — sha1 for the token.")],
     [], BAIT, True, "anchored"),
    ("must_not_raise: empty match forbids any finding at the floor",
     [asticky([f("docs/api.md", "stale-doc", "low", 3)],
              "- **[stale-doc]** `docs/api.md:3` — unclear.")], [], DOCS_ANY, False, "raised=["),
    ("must_not_raise: empty match still allows an info note",
     [asticky([f("docs/api.md", "stale-doc", "info", 3)], "")], [], DOCS_ANY, True, "anchored"),
    ("must_not_raise: ./ prefixes are normalised",
     [asticky([f("./" + RECEIPTS, "weak-crypto", "critical", 12)], MD5_NOTE)], [], BAIT, False, "raised=["),
    # The marker is the source of severity; without it there is nothing to grade.
    ("anchored: no marker in the current section is not scored",
     [comment(MARKER + "\n\n" + CLEAN)], [], BAIT, None, "no review-findings marker"),
    ("anchored: two markers fail",
     [{"author": "eval-bot", "body": MARKER + "\n" + projected([]) + "\n" + projected([]) + "\n"}], [],
     BAIT, False, "found 2"),
    ("anchored: an undecodable marker fails",
     [{"author": "eval-bot", "body": MARKER + "\n<!-- fullsend:review-findings-v2:abcde -->\n"}], [],
     BAIT, False, "Could not decode"),
    ("anchored: a marker without a findings list fails",
     [sticky(CLEAN)], [], BAIT, False, "no findings list"),
    ("anchored: category checks still run first",
     [asticky([], "Looks good to me")], [], {"required": ["logic-error"], **BAIT}, False,
     "missing=['logic-error']"),
    # Malformed ground truth fails loudly instead of skipping the case.
    ("anchored: unknown key fails",
     [asticky([], "")], [], {"must_not_raise": [{"file": RECEIPTS, "category": "md5"}]}, False, "Malformed"),
    ("anchored: unknown severity fails",
     [asticky([], "")], [], {"must_report": [{"file": REPO, "min_severity": "severe"}]}, False, "Malformed"),
    ("anchored: missing file fails",
     [asticky([], "")], [], {"must_report": [{"match": "injection"}]}, False, "Malformed"),
    ("anchored: a non-list fails",
     [asticky([], "")], [], {"must_report": {"file": REPO}}, False, "must be a list"),
    # A run whose review write-up never posted leaves only the risk-assessment
    # comment (post-review posts it before the review). That is not a clean
    # review: no sticky, no verdict.
    ("risk-assessment comment alone fails closed",
     {"comments": [comment("<!-- fullsend:risk-assessment -->\n## Risk assessment\n\nLow (1/5)")],
      "reviews": [], "review_decision": ""}, None, BAIT, False, "found 0"),
]

failures = 0
for name, comments, reviews, findings, want, substr in cases:
    if comments is None:
        state = {"pr_fetch_failed": True, "comments": [], "reviews": []}
    elif isinstance(comments, dict):
        state = comments
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
