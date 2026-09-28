#!/usr/bin/env python3
"""Tests for review-finding-coverage.py."""

import json
import os
import tempfile
import unittest

from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location(
    "review_finding_coverage",
    os.path.join(os.path.dirname(__file__), "review-finding-coverage.py"),
)
assert spec is not None and spec.loader is not None
mod = module_from_spec(spec)
spec.loader.exec_module(mod)

parse_finding_tags = mod.parse_finding_tags
check_coverage = mod.check_coverage
main = mod.main

TWO_FINDINGS = """\
<!-- **Head SHA:** abcdef0123456789abcdef0123456789abcdef01 -->
## Review

### Findings

#### Medium

- **[stale-docs]** `AGENTS.md:97` — Review Checklist still used old
  collection-registration language.
- **[protected-path]** `AGENTS.md` — AGENTS.md is a protected governance file.
"""

ACTIONABLE_FIXTURE = """\
## Review

### Findings

#### High

- **[missing-validation]** `scripts/example.sh:12` — Input is used without checking
  that it is non-empty. Reject empty values before processing so later steps
  cannot run on an unset path.

#### Medium

- **[test-gap]** `scripts/example-test.sh` — There is no coverage for the empty
  input case. Add a regression test that asserts the script exits non-zero.

Please address these findings before merge.
"""


class TestParseFindingTags(unittest.TestCase):
    def test_two_medium_findings(self):
        self.assertEqual(
            parse_finding_tags(TWO_FINDINGS),
            ["stale-docs", "protected-path"],
        )

    def test_actionable_fixture_format(self):
        self.assertEqual(
            parse_finding_tags(ACTIONABLE_FIXTURE),
            ["missing-validation", "test-gap"],
        )

    def test_actionable_fixture_file(self):
        path = os.path.join(
            os.path.dirname(__file__), "test-fixtures", "review-body", "actionable.txt"
        )
        with open(path, encoding="utf-8") as handle:
            body = handle.read()
        self.assertEqual(
            parse_finding_tags(body),
            ["missing-validation", "test-gap"],
        )

    def test_details_block_ignored(self):
        body = (
            TWO_FINDINGS
            + "\n<details>\n<summary>Prior iteration</summary>\n\n"
            + "- **[old-finding]** `gone.sh:1` — stale recap\n"
            + "</details>\n"
        )
        self.assertEqual(
            parse_finding_tags(body),
            ["stale-docs", "protected-path"],
        )

    def test_html_comment_ignored(self):
        body = TWO_FINDINGS + "\n<!-- - **[hidden-tag]** `x.sh:1` — not a finding -->\n"
        self.assertEqual(
            parse_finding_tags(body),
            ["stale-docs", "protected-path"],
        )

    def test_duplicate_tags_preserved(self):
        body = (
            "### Findings\n\n"
            "- **[stale-docs]** `a.md:1` — one\n"
            "- **[stale-docs]** `b.md:2` — two\n"
        )
        self.assertEqual(parse_finding_tags(body), ["stale-docs", "stale-docs"])

    def test_empty_and_unstructured(self):
        self.assertEqual(parse_finding_tags(""), [])
        self.assertEqual(parse_finding_tags("Looks good to me"), [])
        self.assertEqual(parse_finding_tags("See the review comment for full details."), [])

    def test_tag_case_normalized(self):
        body = "- **[Stale-Docs]** `AGENTS.md:97` — mixed case\n"
        self.assertEqual(parse_finding_tags(body), ["stale-docs"])


class TestCheckCoverage(unittest.TestCase):
    def test_both_findings_covered(self):
        actions = [
            {"type": "fix", "finding": "[stale-docs] AGENTS.md:97"},
            {"type": "disagree", "finding": "[protected-path] AGENTS.md"},
        ]
        ok, message = check_coverage(TWO_FINDINGS, actions)
        self.assertTrue(ok)
        self.assertIn("all 2 review findings covered", message)

    def test_original_drop_failure_mode(self):
        """The conforma/policy#1785 shape: one of two findings silently dropped."""
        actions = [
            {
                "type": "disagree",
                "finding": "the only finding is a procedural protected-path flag",
            },
        ]
        ok, message = check_coverage(TWO_FINDINGS, actions)
        self.assertFalse(ok)
        self.assertIn("[stale-docs] x1", message)
        self.assertIn("[protected-path] x1", message)

    def test_protected_path_covered_stale_docs_dropped(self):
        actions = [
            {"type": "disagree", "finding": "[protected-path] AGENTS.md is governance"},
        ]
        ok, message = check_coverage(TWO_FINDINGS, actions)
        self.assertFalse(ok)
        self.assertIn("[stale-docs] x1", message)
        self.assertIn("covered: [protected-path] x1", message)

    def test_extra_rebase_action_allowed(self):
        actions = [
            {"type": "fix", "finding": "rebase onto main", "description": "Rebased"},
            {"type": "defer", "finding": "[stale-docs] AGENTS.md:97", "reason": "rebase-only"},
            {
                "type": "defer",
                "finding": "[protected-path] AGENTS.md",
                "reason": "rebase-only",
            },
        ]
        ok, message = check_coverage(TWO_FINDINGS, actions)
        self.assertTrue(ok, message)

    def test_duplicate_tag_needs_two_actions(self):
        body = (
            "### Findings\n\n"
            "- **[stale-docs]** `a.md:1` — one\n"
            "- **[stale-docs]** `b.md:2` — two\n"
        )
        one = [{"type": "fix", "finding": "[stale-docs] a.md:1"}]
        ok, _ = check_coverage(body, one)
        self.assertFalse(ok)
        two = [
            {"type": "fix", "finding": "[stale-docs] a.md:1"},
            {"type": "fix", "finding": "[stale-docs] b.md:2"},
        ]
        ok, message = check_coverage(body, two)
        self.assertTrue(ok, message)

    def test_skip_when_no_structured_findings(self):
        ok, message = check_coverage("Looks good to me", [{"type": "fix", "finding": "x"}])
        self.assertTrue(ok)
        self.assertIn("skipping", message)

    def test_tag_match_is_bracketed(self):
        """Bare 'path' in a label must not cover [protected-path]."""
        actions = [{"type": "disagree", "finding": "protected-path without brackets"}]
        ok, message = check_coverage(TWO_FINDINGS, actions)
        self.assertFalse(ok)
        self.assertIn("[protected-path] x1", message)

    def test_two_tags_in_one_finding_still_needs_two_actions(self):
        """A single finding string embedding two bracketed tags in prose must
        not be allowed to satisfy both required findings at once — only the
        first bracketed tag token counts."""
        actions = [
            {
                "type": "disagree",
                "finding": (
                    "the only real issue is [protected-path]; "
                    "[stale-docs] is not a real defect"
                ),
            },
        ]
        ok, message = check_coverage(TWO_FINDINGS, actions)
        self.assertFalse(ok)
        self.assertIn("[stale-docs] x1", message)
        self.assertIn("covered: [protected-path] x1", message)

        # Recording the second tag as its own action closes the gap.
        actions.append({"type": "fix", "finding": "[stale-docs] AGENTS.md:97"})
        ok, message = check_coverage(TWO_FINDINGS, actions)
        self.assertTrue(ok, message)


class TestMainCli(unittest.TestCase):
    def _write(self, directory, name, content):
        path = os.path.join(directory, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
        return path

    def test_empty_body_skips(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self._write(
                tmp,
                "agent-result.json",
                json.dumps(
                    {
                        "actions": [
                            {"type": "fix", "finding": "rebase", "description": "ok"}
                        ]
                    }
                ),
            )
            body = self._write(tmp, "review-body.txt", "")
            self.assertEqual(main([result, body]), 0)

    def test_uncovered_exits_1(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self._write(
                tmp,
                "agent-result.json",
                json.dumps(
                    {
                        "actions": [
                            {
                                "type": "disagree",
                                "finding": "[protected-path] only",
                            }
                        ]
                    }
                ),
            )
            body = self._write(tmp, "review-body.txt", TWO_FINDINGS)
            self.assertEqual(main([result, body]), 1)

    def test_covered_exits_0(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self._write(
                tmp,
                "agent-result.json",
                json.dumps(
                    {
                        "actions": [
                            {"type": "fix", "finding": "[stale-docs] AGENTS.md:97"},
                            {
                                "type": "disagree",
                                "finding": "[protected-path] AGENTS.md",
                            },
                        ]
                    }
                ),
            )
            body = self._write(tmp, "review-body.txt", TWO_FINDINGS)
            self.assertEqual(main([result, body]), 0)

    def test_usage_exits_1(self):
        self.assertEqual(main([]), 1)


if __name__ == "__main__":
    unittest.main()
