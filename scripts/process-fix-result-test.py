#!/usr/bin/env python3
"""Tests for process-fix-result.py."""

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(__file__))

from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location(
    "process_fix_result",
    os.path.join(os.path.dirname(__file__), "process-fix-result.py"),
)
assert spec is not None and spec.loader is not None
mod = module_from_spec(spec)
spec.loader.exec_module(mod)

build_summary_body = mod.build_summary_body
main = mod.main

_SCHEMA_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "schemas",
    "fix-result.schema.json",
)
_SCHEMA_ENV = {"FULLSEND_OUTPUT_SCHEMA": _SCHEMA_PATH}


class TestBuildSummaryBody(unittest.TestCase):
    def test_basic_summary_with_fixes(self):
        data = {
            "summary": "Fixed 2 issues.",
            "trigger_source": "bot",
            "iteration": 3,
            "tests_passed": True,
            "actions": [
                {
                    "type": "fix",
                    "finding": "missing nil check",
                    "path": "pkg/handler.go",
                    "description": "Added nil check",
                },
                {
                    "type": "fix",
                    "finding": "unused import",
                    "path": "pkg/util.go",
                    "description": "Removed unused import",
                },
            ],
        }
        body = build_summary_body(data)
        self.assertIn("iteration 3", body)
        self.assertIn("bot-triggered", body)
        self.assertIn("Fixed 2 issues.", body)
        self.assertIn("Fixed (2)", body)
        self.assertIn("missing nil check", body)
        self.assertIn("`pkg/handler.go`", body)
        self.assertIn("**Tests:** passed", body)

    def test_disagreements(self):
        data = {
            "summary": "Disagreed with 1 finding.",
            "tests_passed": True,
            "actions": [
                {
                    "type": "disagree",
                    "finding": "refactor to strategy pattern",
                    "reason": "Out of scope for this PR",
                },
            ],
        }
        body = build_summary_body(data)
        self.assertIn("Disagreed (1)", body)
        self.assertIn("refactor to strategy pattern", body)
        self.assertIn("Out of scope", body)

    def test_failed_tests(self):
        data = {"summary": "Partial fix.", "tests_passed": False, "actions": []}
        body = build_summary_body(data)
        self.assertIn("**Tests:** **failed**", body)

    def test_decision_points(self):
        data = {
            "summary": "Done.",
            "tests_passed": True,
            "actions": [],
            "decision_points": [
                {
                    "description": "Chose approach A",
                    "alternatives": ["B", "C"],
                    "rationale": "Simpler",
                }
            ],
        }
        body = build_summary_body(data)
        self.assertIn("Decision points", body)
        self.assertIn("Chose approach A", body)
        self.assertIn("B, C", body)
        self.assertIn("Simpler", body)

    def test_strategy_change_rendered(self):
        data = {
            "summary": "Done.",
            "tests_passed": True,
            "actions": [{"type": "fix", "finding": "bug", "description": "Fixed"}],
            "strategy_change": "Switched from inline fix to extract-method approach",
        }
        body = build_summary_body(data)
        self.assertIn("Strategy change:", body)
        self.assertIn("extract-method approach", body)

    def test_conflict_update_rendered(self):
        data = {
            "summary": "Merged target to resolve conflict.",
            "tests_passed": True,
            "actions": [
                {
                    "type": "fix",
                    "finding": "forge merge conflict",
                    "description": "Merged origin/main",
                }
            ],
            "conflict_update": {
                "forge_state": "CONFLICTING",
                "target_branch": "main",
                "target_sha": "abc123",
                "strategy": "merge",
                "outcome": "merged",
            },
        }
        body = build_summary_body(data)
        self.assertIn("**Conflict update:**", body)
        self.assertIn("merged", body)
        self.assertIn("strategy `merge`", body)
        self.assertIn("forge `CONFLICTING`", body)
        self.assertIn("`main@abc123`", body)

    def test_strategy_change_omitted_when_empty(self):
        data = {"summary": "Done.", "tests_passed": True, "actions": []}
        body = build_summary_body(data)
        self.assertNotIn("Strategy change:", body)

    def test_no_decision_points(self):
        data = {"summary": "Done.", "tests_passed": True, "actions": []}
        body = build_summary_body(data)
        self.assertNotIn("Decision points", body)

    def test_defaults_for_missing_fields(self):
        data = {}
        body = build_summary_body(data)
        self.assertIn("Fix agent completed.", body)
        self.assertIn("unknown-triggered", body)
        self.assertIn("iteration 1", body)

    def test_mixed_fix_and_disagree(self):
        data = {
            "summary": "Addressed 2 of 3.",
            "trigger_source": "bot",
            "iteration": 1,
            "tests_passed": True,
            "actions": [
                {"type": "fix", "finding": "bug A", "description": "Fixed A"},
                {"type": "fix", "finding": "bug B", "description": "Fixed B"},
                {"type": "disagree", "finding": "refactor C", "reason": "Out of scope"},
            ],
        }
        body = build_summary_body(data)
        self.assertIn("Fixed (2)", body)
        self.assertIn("Disagreed (1)", body)

    def test_no_actions(self):
        data = {
            "summary": "Nothing to fix.",
            "tests_passed": True,
            "actions": [],
        }
        body = build_summary_body(data)
        self.assertNotIn("Fixed (", body)
        self.assertNotIn("Disagreed (", body)

    def test_fix_without_path(self):
        data = {
            "summary": "Fixed.",
            "tests_passed": True,
            "actions": [
                {"type": "fix", "finding": "typo in docs", "description": "Fixed typo"},
            ],
        }
        body = build_summary_body(data)
        self.assertIn("**typo in docs**:", body)
        self.assertNotIn("(`", body)

    def test_action_hints_footer_constant(self):
        self.assertIn("**Next steps:**", mod.FOOTER)
        self.assertIn("/fs-review", mod.FOOTER)
        self.assertIn("/fs-fix", mod.FOOTER)
        self.assertIn("Push commits directly", mod.FOOTER)

    def test_disagree_only_body(self):
        data = {
            "summary": "Disagreed with all findings.",
            "tests_passed": True,
            "actions": [
                {"type": "disagree", "finding": "refactor X", "reason": "Out of scope"},
            ],
        }
        body = build_summary_body(data)
        self.assertIn("Disagreed (1)", body)
        self.assertNotIn("Fixed (", body)

    def test_ci_inspections_rendered(self):
        data = {
            "summary": "Fixed lint.",
            "tests_passed": True,
            "actions": [
                {"type": "fix", "finding": "nil check", "description": "Fixed"},
            ],
            "ci_inspections": [
                {
                    "job": "lint",
                    "status": "failure",
                    "classification": "pr-related",
                    "diagnosis": "ruff failed on src/input.sh.",
                    "remediation": "Formatted src/input.sh.",
                },
                {
                    "job": "e2e",
                    "status": "failure",
                    "classification": "flaky",
                    "diagnosis": "Timeout talking to staging.",
                    "remediation": "Rerun the e2e job; this is not caused by the PR.",
                },
                {
                    "job": "coverage",
                    "status": "failure",
                    "classification": "unrelated",
                    "diagnosis": "Coverage gate failed on files this PR did not touch.",
                    "remediation": "File an issue with the coverage-gate owners.",
                },
            ],
        }
        body = build_summary_body(data)
        self.assertIn("CI inspections (3)", body)
        self.assertIn("**lint** (pr-related, `failure`)", body)
        self.assertIn("ruff failed on src/input.sh.", body)
        self.assertIn("Formatted src/input.sh.", body)
        self.assertIn("**e2e** (flaky, `failure`)", body)
        self.assertIn("Rerun the e2e job", body)
        self.assertIn("**coverage** (unrelated, `failure`)", body)
        self.assertIn("File an issue with the coverage-gate owners.", body)

    def test_ci_inspections_omitted_when_absent(self):
        data = {"summary": "Done.", "tests_passed": True, "actions": []}
        body = build_summary_body(data)
        self.assertNotIn("CI inspections", body)

    def test_ci_inspections_empty_omitted(self):
        data = {
            "summary": "Done.",
            "tests_passed": True,
            "actions": [],
            "ci_inspections": [],
        }
        body = build_summary_body(data)
        self.assertNotIn("CI inspections", body)

    def test_ci_inspections_without_optional_fields(self):
        data = {
            "summary": "Done.",
            "tests_passed": True,
            "actions": [],
            "ci_inspections": [
                {"job": "unit-tests", "classification": "passing"},
            ],
        }
        body = build_summary_body(data)
        self.assertIn("CI inspections (1)", body)
        self.assertIn("**unit-tests** (passing)", body)
        self.assertNotIn("`passing`)", body)


post_summary = mod.post_summary
MAX_COMMENT_LENGTH = mod.MAX_COMMENT_LENGTH


_VALID_FIX_RESULT = {
    "pr_number": 1,
    "trigger_source": "bot",
    "actions": [{"type": "fix", "finding": "nil check", "description": "Fixed"}],
    "summary": "Short.",
    "tests_passed": True,
    "files_changed": ["foo.go"],
}


def _run_main_capture(data):
    """Run main() in dry-run mode, capturing the body and suffix handed to
    post_summary so tests can assert on the assembled comment text."""
    captured = {}

    def fake_post_summary(repo, pr_number, body, suffix="", dry_run=False):
        captured["body"] = body
        captured["suffix"] = suffix
        return True

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(data, f)
        path = f.name
    try:
        with patch.dict(os.environ, _SCHEMA_ENV), \
             patch.object(mod, "post_summary", fake_post_summary), \
             contextlib.redirect_stdout(io.StringIO()):
            rc = main([path, "org/repo", "1", "--dry-run"])
    finally:
        os.unlink(path)
    return rc, captured.get("body", ""), captured.get("suffix", "")



class TestCommentTruncation(unittest.TestCase):
    def test_long_body_truncated(self):
        data = {
            "summary": "x" * 70000,
            "tests_passed": True,
            "actions": [],
        }
        body = build_summary_body(data)
        suffix = mod.FOOTER + mod.ATTRIBUTION
        with contextlib.redirect_stdout(io.StringIO()) as captured:
            post_summary("org/repo", "1", body, suffix=suffix, dry_run=True)
        output = captured.getvalue()
        self.assertIn("[dry-run]", output)
        self.assertRegex(output, r"\d+ chars\)")
        reported = int(output.split("(")[1].split(" chars")[0])
        self.assertLessEqual(reported, MAX_COMMENT_LENGTH)

    def test_signoff_note_rendered_from_env(self):
        data = dict(_VALID_FIX_RESULT)
        with patch.dict(os.environ, {"SIGNOFF_STRIPPED_COUNT": "1"}):
            rc, _body, suffix = _run_main_capture(data)
        self.assertEqual(rc, 0)
        self.assertIn("Removed a Signed-off-by trailer from 1 agent commit.", suffix)
        self.assertNotIn("commits.", suffix)
        with patch.dict(os.environ, {"SIGNOFF_STRIPPED_COUNT": "3"}):
            _rc, _body, suffix = _run_main_capture(data)
        self.assertIn("Removed a Signed-off-by trailer from 3 agent commits.", suffix)

    def test_signoff_note_absent_when_unset_or_zero(self):
        data = dict(_VALID_FIX_RESULT)
        for val in ("", "0", "not-a-number"):
            with patch.dict(os.environ, {"SIGNOFF_STRIPPED_COUNT": val}):
                rc, _body, suffix = _run_main_capture(data)
            self.assertEqual(rc, 0)
            self.assertNotIn("Signed-off-by", suffix)

    def test_signoff_note_survives_truncation(self):
        # The note lives in the suffix, which post_summary must keep whole while
        # it trims the body to fit. Take a real suffix from a valid run, then
        # feed an oversized body through the real truncation path.
        with patch.dict(os.environ, {"SIGNOFF_STRIPPED_COUNT": "2"}):
            rc, _body, suffix = _run_main_capture(dict(_VALID_FIX_RESULT))
        self.assertEqual(rc, 0)
        self.assertIn("Removed a Signed-off-by trailer from 2 agent commits.", suffix)
        body = build_summary_body(dict(_VALID_FIX_RESULT, summary="x" * 70000))
        with contextlib.redirect_stdout(io.StringIO()) as captured:
            post_summary("org/repo", "1", body, suffix=suffix, dry_run=True)
        reported = int(captured.getvalue().split("(")[1].split(" chars")[0])
        self.assertLessEqual(reported, MAX_COMMENT_LENGTH)

    def test_short_body_not_truncated(self):
        data = {
            "summary": "Short.",
            "tests_passed": True,
            "actions": [],
        }
        body = build_summary_body(data)
        self.assertLess(len(body), MAX_COMMENT_LENGTH)

    def test_attribution_separated_from_last_bullet(self):
        # A single newline after a Markdown list item continues that item, so
        # the <sub> attribution must be preceded by a blank line.
        sep = "review re-runs automatically on push\n\n<sub>"
        rc, _body, suffix = _run_main_capture(dict(_VALID_FIX_RESULT))
        self.assertEqual(rc, 0)
        self.assertIn(sep, suffix)
        # The separator must survive truncation of an oversized body.
        body = build_summary_body(dict(_VALID_FIX_RESULT, summary="x" * 70000))
        posted = {}
        with patch.dict(os.environ, {"FULLSEND_FORGE": "github"}), \
             patch.object(mod, "_post_comment_github",
                          lambda _r, _n, full: posted.update(full=full)), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(post_summary("org/repo", "1", body, suffix=suffix))
        self.assertLessEqual(len(posted["full"]), MAX_COMMENT_LENGTH)
        self.assertTrue(posted["full"].endswith(suffix))
        self.assertIn(sep, posted["full"])


@patch.dict(os.environ, _SCHEMA_ENV)
class TestUnknownActionType(unittest.TestCase):
    def test_unknown_type_rejected_by_schema(self):
        """Unknown action types are now caught by schema validation (exit 1)."""
        data = {
            "pr_number": 1,
            "trigger_source": "bot",
            "actions": [
                {"type": "exfiltrate", "finding": "sneaky"},
                {"type": "fix", "finding": "real fix", "description": "Fixed"},
            ],
            "summary": "Done.",
            "tests_passed": True,
            "files_changed": [],
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                with contextlib.redirect_stderr(io.StringIO()) as captured:
                    result = main([f.name, "org/repo", "1", "--dry-run"])
                self.assertEqual(result, 1)
                self.assertIn("schema validation", captured.getvalue())
            finally:
                os.unlink(f.name)


@patch.dict(os.environ, _SCHEMA_ENV)
class TestPostSummaryFailure(unittest.TestCase):
    def test_returns_2_when_comment_post_fails(self):
        data = {
            "pr_number": 42,
            "trigger_source": "bot",
            "actions": [
                {"type": "fix", "finding": "nil check", "description": "Fixed"},
            ],
            "summary": "All good.",
            "tests_passed": True,
            "files_changed": ["foo.go"],
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                with patch(
                    "subprocess.run",
                    side_effect=subprocess.CalledProcessError(1, "gh", stderr="API error"),
                ):
                    result = main([f.name, "org/repo", "42"])
                self.assertEqual(result, 2)
            finally:
                os.unlink(f.name)


@patch.dict(os.environ, _SCHEMA_ENV)
class TestMain(unittest.TestCase):
    def test_missing_args(self):
        self.assertEqual(main([]), 1)
        self.assertEqual(main(["file.json"]), 1)

    def test_nonexistent_file(self):
        self.assertEqual(main(["/nonexistent.json", "org/repo", "42"]), 1)

    def test_invalid_json(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            f.write("not json")
            f.flush()
            try:
                self.assertEqual(main([f.name, "org/repo", "42"]), 1)
            finally:
                os.unlink(f.name)

    def test_valid_dry_run(self):
        data = {
            "pr_number": 42,
            "trigger_source": "bot",
            "actions": [
                {"type": "fix", "finding": "nil check", "description": "Fixed"},
            ],
            "summary": "All good.",
            "tests_passed": True,
            "files_changed": ["foo.go"],
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                self.assertEqual(main([f.name, "org/repo", "42", "--dry-run"]), 0)
            finally:
                os.unlink(f.name)

    def test_empty_actions_fails_schema_validation(self):
        data = {
            "pr_number": 10,
            "trigger_source": "human",
            "actions": [],
            "summary": "Nothing to do.",
            "tests_passed": True,
            "files_changed": [],
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                self.assertEqual(main([f.name, "org/repo", "10", "--dry-run"]), 1)
            finally:
                os.unlink(f.name)


@patch.dict(os.environ, _SCHEMA_ENV)
class TestSchemaValidation(unittest.TestCase):
    """Tests for schema validation added in #412."""

    def test_missing_required_field_fails(self):
        """Missing 'actions' field triggers a validation error."""
        data = {
            "pr_number": 1,
            "trigger_source": "bot",
            "summary": "Done.",
            "tests_passed": True,
            "files_changed": [],
            # 'actions' is missing
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                self.assertEqual(main([f.name, "org/repo", "1", "--dry-run"]), 1)
            finally:
                os.unlink(f.name)

    def test_fix_action_missing_description_fails(self):
        """A 'fix' action without 'description' fails validation."""
        data = {
            "pr_number": 1,
            "trigger_source": "bot",
            "actions": [
                {"type": "fix", "finding": "bug"},
                # missing 'description' required for fix actions
            ],
            "summary": "Done.",
            "tests_passed": True,
            "files_changed": [],
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                self.assertEqual(main([f.name, "org/repo", "1", "--dry-run"]), 1)
            finally:
                os.unlink(f.name)

    def test_disagree_action_missing_reason_fails(self):
        """A 'disagree' action without 'reason' fails validation."""
        data = {
            "pr_number": 1,
            "trigger_source": "bot",
            "actions": [
                {"type": "disagree", "finding": "refactor"},
                # missing 'reason' required for disagree actions
            ],
            "summary": "Done.",
            "tests_passed": True,
            "files_changed": [],
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                self.assertEqual(main([f.name, "org/repo", "1", "--dry-run"]), 1)
            finally:
                os.unlink(f.name)

    def test_additional_properties_rejected(self):
        """Extra top-level keys are rejected by the schema."""
        data = {
            "pr_number": 1,
            "trigger_source": "bot",
            "actions": [
                {"type": "fix", "finding": "bug", "description": "Fixed"},
            ],
            "summary": "Done.",
            "tests_passed": True,
            "files_changed": [],
            "unexpected_field": "should fail",
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                self.assertEqual(main([f.name, "org/repo", "1", "--dry-run"]), 1)
            finally:
                os.unlink(f.name)

    def test_valid_data_passes_validation(self):
        """Fully valid data passes schema validation and processes normally."""
        data = {
            "pr_number": 42,
            "trigger_source": "bot",
            "actions": [
                {"type": "fix", "finding": "nil check", "description": "Fixed"},
            ],
            "summary": "All good.",
            "tests_passed": True,
            "files_changed": ["foo.go"],
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                self.assertEqual(main([f.name, "org/repo", "42", "--dry-run"]), 0)
            finally:
                os.unlink(f.name)

    def test_valid_data_with_ci_inspections_passes(self):
        """Optional ci_inspections is accepted when well-formed."""
        data = {
            "pr_number": 42,
            "trigger_source": "bot",
            "actions": [
                {"type": "fix", "finding": "nil check", "description": "Fixed"},
            ],
            "summary": "All good.",
            "tests_passed": True,
            "files_changed": ["foo.go"],
            "ci_inspections": [
                {
                    "job": "lint",
                    "status": "success",
                    "classification": "passing",
                    "diagnosis": "Lint passed.",
                }
            ],
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                self.assertEqual(main([f.name, "org/repo", "42", "--dry-run"]), 0)
            finally:
                os.unlink(f.name)

    def test_invalid_trigger_source_fails(self):
        """trigger_source must be 'bot' or 'human'."""
        data = {
            "pr_number": 1,
            "trigger_source": "unknown",
            "actions": [
                {"type": "fix", "finding": "bug", "description": "Fixed"},
            ],
            "summary": "Done.",
            "tests_passed": True,
            "files_changed": [],
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                self.assertEqual(main([f.name, "org/repo", "1", "--dry-run"]), 1)
            finally:
                os.unlink(f.name)


@patch.dict(os.environ, _SCHEMA_ENV)
class TestSchemaEnvVar(unittest.TestCase):
    """Tests for FULLSEND_OUTPUT_SCHEMA env var requirement (#526)."""

    def test_missing_env_var_fails(self):
        """Missing FULLSEND_OUTPUT_SCHEMA exits 1 with a clear error."""
        data = {
            "pr_number": 42,
            "trigger_source": "bot",
            "actions": [
                {"type": "fix", "finding": "nil check", "description": "Fixed"},
            ],
            "summary": "All good.",
            "tests_passed": True,
            "files_changed": ["foo.go"],
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                os.environ.pop("FULLSEND_OUTPUT_SCHEMA", None)
                with contextlib.redirect_stderr(io.StringIO()) as captured:
                    result = main([f.name, "org/repo", "42", "--dry-run"])
                self.assertEqual(result, 1)
                self.assertIn("FULLSEND_OUTPUT_SCHEMA", captured.getvalue())
            finally:
                os.unlink(f.name)

    def test_env_var_used_for_schema_path(self):
        """When FULLSEND_OUTPUT_SCHEMA is set, it is used as the schema path."""
        data = {
            "pr_number": 42,
            "trigger_source": "bot",
            "actions": [
                {"type": "fix", "finding": "nil check", "description": "Fixed"},
            ],
            "summary": "All good.",
            "tests_passed": True,
            "files_changed": ["foo.go"],
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                # FULLSEND_OUTPUT_SCHEMA is set by the class-level @patch.dict
                result = main([f.name, "org/repo", "42", "--dry-run"])
                self.assertEqual(result, 0)
            finally:
                os.unlink(f.name)


_post_comment_gitlab = mod._post_comment_gitlab


class TestGitLabPostComment(unittest.TestCase):
    """Tests for GitLab comment posting logic (#807)."""

    def _valid_data(self):
        return {
            "pr_number": 42,
            "trigger_source": "bot",
            "actions": [
                {"type": "fix", "finding": "nil check", "description": "Fixed"},
            ],
            "summary": "All good.",
            "tests_passed": True,
            "files_changed": ["foo.go"],
        }

    @patch.dict(
        os.environ,
        {
            **_SCHEMA_ENV,
            "FULLSEND_FORGE": "gitlab",
            "GITLAB_HOST": "gitlab.com",
            "GITLAB_TOKEN": "fake-token",
            "CI_SERVER_HOST": "gitlab.com",
        },
    )
    @patch("subprocess.run")
    def test_gitlab_uses_curl_not_gh(self, mock_run):
        """GitLab mode calls curl, not gh."""
        mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0)
        data = self._valid_data()
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
            f.flush()
            try:
                result = main([f.name, "org/repo", "42"])
                self.assertEqual(result, 0)
                args_list = mock_run.call_args[0][0]
                self.assertEqual(args_list[0], "curl")
                # Token must NOT appear in the command args (security).
                for arg in args_list:
                    self.assertNotIn("fake-token", arg)
                # Token is passed via --config - (stdin).
                self.assertIn("--config", args_list)
                self.assertIn("-", args_list)
                config_input = mock_run.call_args[1].get("input", "")
                self.assertIn("PRIVATE-TOKEN: fake-token", config_input)
            finally:
                os.unlink(f.name)

    @patch.dict(
        os.environ,
        {
            **_SCHEMA_ENV,
            "FULLSEND_FORGE": "gitlab",
            "GITLAB_HOST": "evil.example.com",
            "GITLAB_TOKEN": "fake-token",
            "CI_SERVER_HOST": "gitlab.com",
        },
    )
    def test_rejected_host_raises(self):
        """A host not in the dynamic trust sources raises ValueError."""
        with self.assertRaises(ValueError) as ctx:
            _post_comment_gitlab("org/repo", "42", "body")
        self.assertIn("evil.example.com", str(ctx.exception))
        self.assertIn("not in the allowed host list", str(ctx.exception))

    @patch.dict(
        os.environ,
        {
            **_SCHEMA_ENV,
            "FULLSEND_FORGE": "gitlab",
            "GITLAB_TOKEN": "fake-token",
            "CI_SERVER_HOST": "gitlab.com",
        },
        clear=False,
    )
    def test_missing_host_and_url_raises(self):
        """Missing both GITLAB_HOST and PR_URL raises ValueError."""
        os.environ.pop("GITLAB_HOST", None)
        os.environ.pop("PR_URL", None)
        with self.assertRaises(ValueError) as ctx:
            _post_comment_gitlab("org/repo", "42", "body")
        self.assertIn("cannot be derived", str(ctx.exception))

    @patch.dict(
        os.environ,
        {
            **_SCHEMA_ENV,
            "FULLSEND_FORGE": "gitlab",
            "GITLAB_TOKEN": "fake-token",
            "CI_SERVER_HOST": "gitlab.com",
            "PR_URL": "https://gitlab.com/group/project/-/merge_requests/42",
        },
        clear=False,
    )
    @patch("subprocess.run")
    def test_host_derived_from_pr_url(self, mock_run):
        """GITLAB_HOST is derived from PR_URL when not set directly."""
        os.environ.pop("GITLAB_HOST", None)
        mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0)
        _post_comment_gitlab("group/project", "42", "body")
        args_list = mock_run.call_args[0][0]
        # The API URL should use gitlab.com derived from PR_URL
        api_url = args_list[-1]
        self.assertIn("gitlab.com", api_url)

    @patch.dict(
        os.environ,
        {
            **_SCHEMA_ENV,
            "FULLSEND_FORGE": "gitlab",
            "GITLAB_HOST": "gitlab.com",
            "CI_SERVER_HOST": "gitlab.com",
        },
        clear=False,
    )
    def test_missing_token_raises(self):
        """Missing GITLAB_TOKEN raises ValueError."""
        os.environ.pop("GITLAB_TOKEN", None)
        with self.assertRaises(ValueError) as ctx:
            _post_comment_gitlab("org/repo", "42", "body")
        self.assertIn("GITLAB_TOKEN is not set", str(ctx.exception))

    @patch.dict(
        os.environ,
        {
            **_SCHEMA_ENV,
            "FULLSEND_FORGE": "gitlab",
            "GITLAB_HOST": "gitlab.com",
            "GITLAB_TOKEN": "fake-token",
            "CI_SERVER_HOST": "gitlab.com",
        },
    )
    @patch("subprocess.run")
    def test_allowed_host_accepted(self, mock_run):
        """A host in the dynamic trust sources is accepted."""
        mock_run.return_value = subprocess.CompletedProcess(args=[], returncode=0)
        _post_comment_gitlab("org/repo", "42", "body")
        mock_run.assert_called_once()

    @patch.dict(
        os.environ,
        {
            **_SCHEMA_ENV,
            "FULLSEND_FORGE": "gitlab",
            "GITLAB_HOST": "gitlab.com",
            "GITLAB_TOKEN": "fake-token",
        },
    )
    def test_no_trust_source_fails_closed(self):
        """Fails closed when CI_SERVER_HOST is not set."""
        os.environ.pop("CI_SERVER_HOST", None)
        with self.assertRaises(ValueError) as ctx:
            _post_comment_gitlab("org/repo", "42", "body")
        self.assertIn("No trusted GitLab host configured", str(ctx.exception))


# ---------------------------------------------------------------------------
# PR/MR metadata update (issue #519)
# ---------------------------------------------------------------------------

build_pr_body = mod.build_pr_body
managed_sections_exposed = mod.managed_sections_exposed
_sanitize = mod._sanitize

LIVE_TITLE = "docs(#484): document X in AGENTS.md"
LIVE_BODY = (
    "Adds docs to AGENTS.md.\n\n---\n\nCloses #484\n\n"
    "### Post-script verification\n\n"
    "- [x] Branch is not main/master (`agent/484-x`)\n"
    "- [x] Secret scan passed"
)
NEW_TITLE = "docs(#484): document X in docs/code.md"
NEW_BODY = 'Moves the docs to `docs/code.md`.\n\nKeeps "double", \'single\' and `back`ticks.\n$(not run)'


def _sha(text):
    import hashlib

    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _metadata_result(**extra):
    data = {
        "pr_number": 42,
        "trigger_source": "human",
        "actions": [
            {"type": "fix", "finding": "Stale PR metadata", "description": "Proposed new metadata"},
        ],
        "summary": "Updated PR metadata.",
        "tests_passed": True,
        "files_changed": [],
    }
    data.update(extra)
    return data


def _both_fields(**overrides):
    fields = {
        "pr_title": NEW_TITLE,
        "pr_title_base_sha256": _sha(LIVE_TITLE),
        "pr_body": NEW_BODY,
        "pr_body_base_sha256": _sha(LIVE_BODY),
    }
    fields.update(overrides)
    return fields


class FakeForge:
    """subprocess.run stand-in that records gh/curl calls."""

    def __init__(self, title=LIVE_TITLE, body=LIVE_BODY, fail_view=False, fail_edit=False):
        self.title = title
        self.body = body
        self.fail_view = fail_view
        self.fail_edit = fail_edit
        self.calls = []

    def __call__(self, cmd, input=None, **kwargs):
        self.calls.append((list(cmd), input))
        joined = " ".join(cmd)
        if cmd[0] == "gh" and cmd[1:3] == ["pr", "view"]:
            if self.fail_view:
                raise subprocess.CalledProcessError(1, cmd, stderr="view failed")
            return subprocess.CompletedProcess(
                cmd, 0, stdout=json.dumps({"title": self.title, "body": self.body})
            )
        if cmd[0] == "gh" and cmd[1:3] == ["pr", "edit"]:
            if self.fail_edit:
                raise subprocess.CalledProcessError(1, cmd, stderr="edit failed")
            return subprocess.CompletedProcess(cmd, 0, stdout="")
        if cmd[0] == "curl" and "GET" in cmd:
            if self.fail_view:
                raise subprocess.CalledProcessError(22, cmd, stderr="view failed")
            return subprocess.CompletedProcess(
                cmd, 0, stdout=json.dumps({"title": self.title, "description": self.body})
            )
        if cmd[0] == "curl" and "PUT" in cmd:
            if self.fail_edit:
                raise subprocess.CalledProcessError(22, cmd, stderr="edit failed")
            return subprocess.CompletedProcess(cmd, 0, stdout="{}")
        assert "comment" in joined or "/notes" in joined, joined
        return subprocess.CompletedProcess(cmd, 0, stdout="")

    def edits(self):
        return [
            (c, i)
            for c, i in self.calls
            if c[:3] == ["gh", "pr", "edit"] or (c[0] == "curl" and "PUT" in c)
        ]

    def views(self):
        return [
            c
            for c, _ in self.calls
            if c[:3] == ["gh", "pr", "view"] or (c[0] == "curl" and "GET" in c)
        ]

    def comment_body(self):
        for c, i in self.calls:
            if c[:3] == ["gh", "pr", "comment"]:
                return i
            if c[0] == "curl" and "POST" in c:
                return next(a for a in c if a.startswith("body="))
        return None


_METADATA_ENV = {**_SCHEMA_ENV, "FIX_RESULT_SECRET_SCAN": "passed", "FULLSEND_FORGE": "github"}


@patch.dict(os.environ, _METADATA_ENV)
class TestPrMetadataGitHub(unittest.TestCase):
    def _run(self, data, forge):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(data, f)
        try:
            err = io.StringIO()
            out = io.StringIO()
            with patch("subprocess.run", side_effect=forge), contextlib.redirect_stderr(
                err
            ), contextlib.redirect_stdout(out):
                rc = main([f.name, "org/repo", "42"])
            return rc, out.getvalue() + err.getvalue()
        finally:
            os.unlink(f.name)

    def test_both_fields_updated(self):
        forge = FakeForge()
        rc, _ = self._run(_metadata_result(**_both_fields()), forge)
        self.assertEqual(rc, 0)
        (cmd, stdin), = forge.edits()
        self.assertIn(f"--title={NEW_TITLE}", cmd)
        self.assertEqual(cmd[-2:], ["--body-file", "-"])
        self.assertTrue(stdin.startswith(NEW_BODY))
        self.assertIn("Closes #484", stdin)
        self.assertIn("### Post-script verification", stdin)
        self.assertNotIn("Adds docs to AGENTS.md.", stdin)
        self.assertIn("**PR metadata:** title updated; body updated", forge.comment_body())

    def test_title_only(self):
        forge = FakeForge()
        data = _metadata_result(pr_title=NEW_TITLE, pr_title_base_sha256=_sha(LIVE_TITLE))
        self.assertEqual(self._run(data, forge)[0], 0)
        (cmd, stdin), = forge.edits()
        self.assertIn(f"--title={NEW_TITLE}", cmd)
        self.assertNotIn("--body-file", cmd)
        self.assertIsNone(stdin)

    def test_body_only(self):
        forge = FakeForge()
        data = _metadata_result(pr_body=NEW_BODY, pr_body_base_sha256=_sha(LIVE_BODY))
        self.assertEqual(self._run(data, forge)[0], 0)
        (cmd, stdin), = forge.edits()
        self.assertFalse(any(a.startswith("--title") for a in cmd))
        self.assertIn("--body-file", cmd)
        self.assertIn(NEW_BODY, stdin)

    def test_neither_field_makes_no_metadata_calls(self):
        forge = FakeForge()
        self.assertEqual(self._run(_metadata_result(), forge)[0], 0)
        self.assertEqual(forge.views(), [])
        self.assertEqual(forge.edits(), [])
        self.assertNotIn("**PR metadata:**", forge.comment_body())

    def test_multiline_body_passed_intact_via_stdin(self):
        forge = FakeForge()
        data = _metadata_result(pr_body=NEW_BODY, pr_body_base_sha256=_sha(LIVE_BODY))
        self._run(data, forge)
        (cmd, stdin), = forge.edits()
        self.assertIn(NEW_BODY, stdin)
        # The body never travels on the command line.
        self.assertFalse(any(NEW_BODY in a for a in cmd))

    def test_concurrent_title_edit_refused(self):
        forge = FakeForge(title="docs: a human retitled this")
        rc, log = self._run(_metadata_result(**_both_fields()), forge)
        self.assertEqual(rc, 0)
        (cmd, _), = forge.edits()
        self.assertFalse(any(a.startswith("--title") for a in cmd))
        self.assertIn("--body-file", cmd)
        self.assertIn("title changed since the fix agent read it", log)
        self.assertIn("title not updated (changed since the agent read it)", forge.comment_body())

    def test_concurrent_body_edit_refused(self):
        forge = FakeForge(body=LIVE_BODY + "\n\nHuman note.")
        rc, log = self._run(
            _metadata_result(pr_body=NEW_BODY, pr_body_base_sha256=_sha(LIVE_BODY)), forge
        )
        self.assertEqual(rc, 0)
        self.assertEqual(forge.edits(), [])
        self.assertIn("body changed since the fix agent read it", log)
        self.assertIn("body not updated", forge.comment_body())

    def test_hiding_body_skipped_but_title_still_updated(self):
        for hiding in ("```text\nnever closed", "<!-- never closed", "~~~"):
            with self.subTest(hiding=hiding):
                forge = FakeForge()
                rc, log = self._run(
                    _metadata_result(**_both_fields(pr_body=f"{NEW_BODY}\n\n{hiding}")), forge
                )
                self.assertEqual(rc, 0)
                (cmd, stdin), = forge.edits()
                self.assertIn(f"--title={NEW_TITLE}", cmd)
                self.assertNotIn("--body-file", cmd)
                self.assertIsNone(stdin)
                self.assertIn("PR body not updated", log)
                comment = forge.comment_body()
                self.assertIn("title updated", comment)
                self.assertIn("body not updated (proposed Markdown could hide", comment)

    def test_unclosed_fence_with_quote_marker_skips_body_keeps_title(self):
        forge = FakeForge()
        rc, log = self._run(
            _metadata_result(**_both_fields(pr_body=f"{NEW_BODY}\n\n```\n> example")), forge
        )
        self.assertEqual(rc, 0)
        (cmd, stdin), = forge.edits()
        self.assertIn(f"--title={NEW_TITLE}", cmd)
        self.assertNotIn("--body-file", cmd)
        self.assertIn("PR body not updated", log)
        self.assertIn("body not updated (proposed Markdown could hide", forge.comment_body())

    def test_hiding_body_only_makes_no_edit(self):
        forge = FakeForge()
        data = _metadata_result(pr_body="New.\n\n```", pr_body_base_sha256=_sha(LIVE_BODY))
        rc, log = self._run(data, forge)
        self.assertEqual(rc, 0)
        self.assertEqual(forge.edits(), [])
        self.assertIn("PR body not updated", log)

    def test_edit_failure_is_non_fatal(self):
        forge = FakeForge(fail_edit=True)
        rc, log = self._run(_metadata_result(**_both_fields()), forge)
        self.assertEqual(rc, 0)
        self.assertIn("::warning::Failed to update PR title and body", log)
        self.assertIn("title update failed; body update failed", forge.comment_body())

    def test_read_failure_is_non_fatal(self):
        forge = FakeForge(fail_view=True)
        rc, log = self._run(_metadata_result(**_both_fields()), forge)
        self.assertEqual(rc, 0)
        self.assertEqual(forge.edits(), [])
        self.assertIn("could not read current metadata", log)
        self.assertIsNotNone(forge.comment_body())

    def test_unchanged_values_not_edited(self):
        forge = FakeForge()
        data = _metadata_result(pr_title=LIVE_TITLE, pr_title_base_sha256=_sha(LIVE_TITLE))
        self._run(data, forge)
        self.assertEqual(forge.edits(), [])
        self.assertIn("title already up to date", forge.comment_body())

    def test_metadata_only_run_validates_and_applies(self):
        """A run with no code change (files_changed empty) can still update metadata."""
        forge = FakeForge()
        data = _metadata_result(**_both_fields())
        self.assertEqual(data["files_changed"], [])
        self.assertEqual(self._run(data, forge)[0], 0)
        self.assertEqual(len(forge.edits()), 1)

    def test_secret_scan_not_passed_blocks_update(self):
        forge = FakeForge()
        with patch.dict(os.environ, {"FIX_RESULT_SECRET_SCAN": "skipped"}):
            rc, log = self._run(_metadata_result(**_both_fields()), forge)
        self.assertEqual(rc, 0)
        self.assertEqual(forge.views(), [])
        self.assertEqual(forge.edits(), [])
        self.assertIn("secret scan did not run or did not pass", log)

    def test_unvalidated_output_blocks_update(self):
        forge = FakeForge()
        with patch.object(mod, "jsonschema", None):
            rc, log = self._run(_metadata_result(**_both_fields()), forge)
        self.assertEqual(rc, 0)
        self.assertEqual(forge.edits(), [])
        self.assertIn("not schema-validated", log)

    def test_schema_failure_blocks_update(self):
        forge = FakeForge()
        rc, _ = self._run(_metadata_result(**_both_fields(pr_title="a\nb")), forge)
        self.assertEqual(rc, 1)
        self.assertEqual(forge.calls, [])


@patch.dict(
    os.environ,
    {
        **_METADATA_ENV,
        "FULLSEND_FORGE": "gitlab",
        "GITLAB_HOST": "gitlab.com",
        "GITLAB_TOKEN": "fake-token",
        "CI_SERVER_HOST": "gitlab.com",
    },
)
class TestPrMetadataGitLab(unittest.TestCase):
    _run = TestPrMetadataGitHub._run

    def test_gitlab_updates_title_and_description(self):
        forge = FakeForge()
        rc, _ = self._run(_metadata_result(**_both_fields()), forge)
        self.assertEqual(rc, 0)
        self.assertFalse(any(c[0] == "gh" for c, _ in forge.calls))
        (cmd, stdin), = forge.edits()
        self.assertIn(f"title={NEW_TITLE}", cmd)
        desc = next(a for a in cmd if a.startswith("description="))
        self.assertIn(NEW_BODY, desc)
        self.assertIn("Closes #484", desc)
        self.assertTrue(cmd[-1].endswith("/projects/org%2Frepo/merge_requests/42"))
        for arg in cmd:
            self.assertNotIn("fake-token", arg)
        self.assertIn("PRIVATE-TOKEN: fake-token", stdin)

    def test_gitlab_quick_action_lines_in_body_not_sent(self):
        for text in (
            "New.\n\n/close",
            "New.\n/label ~x",
            "New.\r\n  /assign @someone",
            "New.\n\n```\n/close\n```",
            "New.\n\n\u00a0/close",
            "New.\n\u2003/label ~x",
        ):
            with self.subTest(text=text):
                forge = FakeForge()
                data = _metadata_result(pr_body=text, pr_body_base_sha256=_sha(LIVE_BODY))
                rc, log = self._run(data, forge)
                self.assertEqual(rc, 0)
                self.assertEqual(forge.edits(), [])
                self.assertIn("GitLab quick action", log)
                self.assertIn("quick-action line", forge.comment_body())

    def test_gitlab_quick_action_in_preserved_live_tail_not_resent(self):
        live_body = LIVE_BODY + "\n/close"
        forge = FakeForge(body=live_body)
        data = _metadata_result(pr_body=NEW_BODY, pr_body_base_sha256=_sha(live_body))
        rc, log = self._run(data, forge)
        self.assertEqual(rc, 0)
        self.assertEqual(forge.edits(), [])
        self.assertIn("GitLab quick action", log)
        self.assertIn("quick-action line", forge.comment_body())

    def test_gitlab_unicode_blank_quick_action_in_preserved_live_tail_not_resent(self):
        for blank in ("\u00a0", "\u2003"):
            with self.subTest(blank=repr(blank)):
                live_body = LIVE_BODY + "\n" + blank + "/close"
                forge = FakeForge(body=live_body)
                data = _metadata_result(pr_body=NEW_BODY, pr_body_base_sha256=_sha(live_body))
                rc, log = self._run(data, forge)
                self.assertEqual(rc, 0)
                self.assertEqual(forge.edits(), [])
                self.assertIn("GitLab quick action", log)

    def test_gitlab_ordinary_markdown_with_slashes_still_sent(self):
        body = "New: see `scripts/a.py` and https://example.com/a/b.\n\n- a/b\n> /note quoted"
        forge = FakeForge()
        data = _metadata_result(pr_body=body, pr_body_base_sha256=_sha(LIVE_BODY))
        self.assertEqual(self._run(data, forge)[0], 0)
        (cmd, _), = forge.edits()
        desc = next(a for a in cmd if a.startswith("description="))
        self.assertIn("https://example.com/a/b.", desc)

    def test_gitlab_title_only_leaves_description(self):
        forge = FakeForge()
        data = _metadata_result(pr_title=NEW_TITLE, pr_title_base_sha256=_sha(LIVE_TITLE))
        self._run(data, forge)
        (cmd, _), = forge.edits()
        self.assertIn(f"title={NEW_TITLE}", cmd)
        self.assertFalse(any(a.startswith("description=") for a in cmd))

    def test_gitlab_concurrent_edit_refused(self):
        forge = FakeForge(body="edited by a human")
        data = _metadata_result(pr_body=NEW_BODY, pr_body_base_sha256=_sha(LIVE_BODY))
        rc, _ = self._run(data, forge)
        self.assertEqual(rc, 0)
        self.assertEqual(forge.edits(), [])

    def test_gitlab_edit_failure_is_non_fatal(self):
        forge = FakeForge(fail_edit=True)
        rc, _ = self._run(_metadata_result(**_both_fields()), forge)
        self.assertEqual(rc, 0)
        self.assertIn("title update failed", forge.comment_body())


class TestSanitize(unittest.TestCase):
    def test_neutralizes_annotation_injection(self):
        text = "a\r\nb\x1b[31mred\x1b[0m\x07 100% ::error::x %0A"
        self.assertEqual(_sanitize(text), "abred 100%25 %3A%3Aerror%3A%3Ax %250A")


class TestBuildPrBody(unittest.TestCase):
    def test_preserves_closing_reference_and_verification(self):
        merged = build_pr_body("New description.", LIVE_BODY)
        self.assertTrue(merged.startswith("New description.\n\n---\n\nCloses #484\n\n"))
        self.assertTrue(merged.endswith("- [x] Secret scan passed"))

    def test_related_to_reference_preserved(self):
        current = LIVE_BODY.replace("Closes #484", "Related to #484")
        merged = build_pr_body("New.", current)
        self.assertIn("Related to #484", merged)

    def test_forged_sections_in_proposal_dropped(self):
        proposed = (
            "New description.\n\nFixes #999\n\n---\n\nCloses #1\n\n"
            "### Post-script verification\n\n- [x] Everything passed"
        )
        merged = build_pr_body(proposed, LIVE_BODY)
        self.assertNotIn("#999", merged)
        self.assertNotIn("Closes #1\n", merged)
        self.assertNotIn("Everything passed", merged)
        self.assertEqual(merged.count("### Post-script verification"), 1)
        self.assertIn("Closes #484", merged)

    def test_human_body_closing_lines_kept(self):
        current = "Human description.\n\nFixes #12\nresolves org/repo#3"
        merged = build_pr_body("Agent description.", current)
        self.assertEqual(merged, "Agent description.\n\nFixes #12\nresolves org/repo#3")

    def test_bulleted_and_inline_references_preserved(self):
        current = (
            "Old description. This change fixes #519.\n\n"
            "- Closes #484\n"
            "* Resolves org/repo#7\n"
        )
        merged = build_pr_body("New.", current)
        self.assertEqual(merged, "New.\n\nfixes #519\n- Closes #484\n* Resolves org/repo#7")

    def test_inline_and_list_closing_references_in_proposal_neutralized(self):
        proposed = (
            "Updated implementation; fixes #999.\n"
            "- Fixes #888\n"
            "Also resolves: org/repo#777 and Closes https://github.com/o/r/issues/6\n"
            "See GH-5 and closes GH-4."
        )
        merged = build_pr_body(proposed, "Old.")
        self.assertEqual(
            merged,
            "Updated implementation; #999.\n"
            "Also org/repo#777 and https://github.com/o/r/issues/6\n"
            "See GH-5 and GH-4.",
        )
        self.assertIsNone(
            re.search(r"(?i)\b(?:fix|close|resolve)\w*\b[\s:]*\S*#", merged)
        )

    def test_nested_closing_keywords_neutralized(self):
        merged = build_pr_body("This fixes fixes #999.", "Old.")
        self.assertEqual(merged, "This #999.")
        self.assertIsNone(re.search(r"(?i)\b(?:fix|close|resolve)\w*\b[\s:]*\S*#", merged))

    def test_keyword_and_target_on_separate_lines_neutralized(self):
        merged = build_pr_body("Details.\nThis fixes\n#999", "Old.")
        self.assertEqual(merged, "Details.\nThis #999")

    def test_keyword_exposed_by_dropped_line_neutralized(self):
        merged = build_pr_body("Note: fixes\nCloses #5\n#999", "Old.")
        self.assertNotIn("ixes", merged)
        self.assertNotIn("Closes", merged)

    def test_inline_multi_target_references_preserved(self):
        for current, ref in (
            ("This change fixes #519 and #520.", "fixes #519 and #520"),
            ("This change fixes #519, #520.", "fixes #519, #520"),
            ("It resolves #1, #2 and org/repo#3.", "resolves #1, #2 and org/repo#3"),
        ):
            with self.subTest(current=current):
                self.assertEqual(build_pr_body("New description.", current), f"New description.\n\n{ref}")

    def test_inline_multi_target_references_in_proposal_neutralized(self):
        merged = build_pr_body("Closes nothing but fixes #1, #2 and #3.", "Old.")
        self.assertEqual(merged, "Closes nothing but #1, #2 and #3.")

    def test_gitlab_closing_variants_in_proposal_neutralized(self):
        for text, expected in (
            ("Note: closing #5", "Note: #5"),
            ("Note: Fixing #5", "Note: #5"),
            ("Note: resolving #5", "Note: #5"),
            ("Note: Implementing #5", "Note: #5"),
            ("Note: Closes issue #5", "Note: #5"),
            ("Note: fixes issues #5 and #6", "Note: #5 and #6"),
            ("Note: Resolved: issue org/repo#5", "Note: org/repo#5"),
            ("Details. Closing issue\n#5", "Details. #5"),
        ):
            with self.subTest(text=text):
                self.assertEqual(build_pr_body(text, "Old."), expected)

    def test_gitlab_closing_variants_in_current_preserved(self):
        for current, ref in (
            ("Fixing #5", "Fixing #5"),
            ("Closes issue #5", "Closes issue #5"),
            ("This is resolving #5 and #6.", "resolving #5 and #6"),
        ):
            with self.subTest(current=current):
                self.assertEqual(build_pr_body("New.", current), f"New.\n\n{ref}")

    def test_equivalent_verification_headings_in_proposal_dropped(self):
        for heading in (
            "### Post-script verification ###",
            "### Post-script verification #",
            "  ### Post-script verification",
            "### Post-script verification   ",
            "###\tPost-script verification",
        ):
            with self.subTest(heading=heading):
                merged = build_pr_body(f"New.\n\n{heading}\n\n- [x] Forged", LIVE_BODY)
                self.assertNotIn("Forged", merged)
                self.assertEqual(merged.count("Post-script verification"), 1)
                self.assertTrue(merged.endswith("- [x] Secret scan passed"))

    def test_wrapped_existing_references_preserved(self):
        self.assertEqual(
            build_pr_body("New description.", "This change resolves #1,\n#2 and org/repo#3."),
            "New description.\n\nresolves #1, #2 and org/repo#3",
        )
        self.assertEqual(
            build_pr_body("New description.", "Old text.\nCloses\n#519\n"),
            "New description.\n\nCloses #519",
        )

    def test_code_examples_in_current_body_not_preserved(self):
        for current in (
            "Old.\n\n```text\nFixes #519\n```",
            "Old.\n\n~~~\nCloses #519\n~~~\n",
            "Old.\n\n````md\nFixes #519\n```\nstill code\n````",
            "Old.\n\n```text\nFixes #519\n",
            "Old. Use `Fixes #519` to close.",
            "Old. Use ``Fixes #519`` to close.",
        ):
            with self.subTest(current=current):
                self.assertEqual(build_pr_body("New.", current), "New.")

    def test_indented_and_mixed_fence_code_not_preserved(self):
        for current in (
            "Old.\n\n    Fixes #519\n",
            "Old.\n\n\tFixes #519\n",
            "    Fixes #519\n\nOld.",
            "Old.\n\n    code\n\n    Fixes #519\n",
            # A tilde line does not close a backtick fence (and vice versa).
            "Old.\n\n```\nexample\n~\nFixes #999\n```",
            "Old.\n\n~~~\nexample\n```\nFixes #999\n~~~",
            # A closing fence cannot carry other characters.
            "Old.\n\n```\nexample\n```~\nFixes #999\n```",
        ):
            with self.subTest(current=current):
                self.assertEqual(build_pr_body("New.", current), "New.")

    def test_fence_closed_by_longer_fence_ends_code(self):
        current = "Old.\n\n```\nFixes #1\n`````\n\nCloses #519"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")

    def test_indented_text_after_paragraph_is_not_code(self):
        # Indented code cannot interrupt a paragraph: this is a continuation line.
        self.assertEqual(
            build_pr_body("New.", "Old text\n    Fixes #519\n"),
            "New.\n\nFixes #519",
        )

    def test_reference_does_not_span_masked_code(self):
        for current in (
            "Old. Fixes `example` #519.",
            "Old. Fixes ``a ` b`` #519.",
            "Old. Fixes\n\n    code\n\n#519",
            "Old. Fixes `x`#519.",
        ):
            with self.subTest(current=current):
                self.assertEqual(build_pr_body("New.", current), "New.")
        # Targets before the masked code survive.
        self.assertEqual(
            build_pr_body("New.", "Old. Fixes #1, `x`#2."),
            "New.\n\nFixes #1",
        )

    def test_references_outside_code_preserved_alongside_code(self):
        current = "Old.\n\n```text\nFixes #1\n```\n\nCloses #519\n\nUse `Fixes #2` here."
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        # An unrelated, unbalanced backtick does not hide a real reference.
        self.assertEqual(
            build_pr_body("New.", "Uses a ` tick.\n\nCloses #519"),
            "New.\n\nCloses #519",
        )

    def test_code_examples_of_verification_heading_in_current_ignored(self):
        example = "### Post-script verification\n\n- [x] Example"
        for code in (
            f"```md\n{example}\n```",
            f"~~~\n{example}\n~~~",
            "    " + example.replace("\n", "\n    "),
            "\t" + example.replace("\n", "\n\t"),
            f"- item\n\n  ```md\n  {example.replace(chr(10), chr(10) + '  ')}\n  ```",
        ):
            with self.subTest(code=code):
                tail = LIVE_BODY[LIVE_BODY.index("---"):]
                current = f"Old.\n\n{code}\n\nCloses #1\n\n{tail}"
                merged = build_pr_body("New.", current)
                self.assertEqual(merged, f"New.\n\nCloses #1\n\n{tail}")

    def test_code_examples_of_verification_heading_in_proposal_ignored(self):
        example = "### Post-script verification\n\n- [x] Example"
        for code in (
            f"```md\n{example}\n```",
            "    " + example.replace("\n", "\n    "),
            f"- item\n\n  ```md\n  {example.replace(chr(10), chr(10) + '  ')}\n  ```",
        ):
            with self.subTest(code=code):
                merged = build_pr_body(f"New.\n\n{code}\n\nMore text.", "Old.")
                self.assertEqual(merged, f"New.\n\n{code}\n\nMore text.")
        # A real heading after a code example is still dropped.
        merged = build_pr_body(
            f"New.\n\n```md\n{example}\n```\n\n### Post-script verification\n\n- [x] Forged", "Old."
        )
        self.assertEqual(merged, f"New.\n\n```md\n{example}\n```")

    def test_list_contained_fence_closing_references_not_preserved(self):
        for current in (
            "Old.\n\n- item\n\n  ```text\n  Fixes #519\n  ```\n",
            "Old.\n\n1. item\n\n   ~~~\n   Closes #519\n   ~~~\n",
            "Old.\n\n- outer\n  - inner\n\n    ```\n    Fixes #519\n    ```\n",
            "Old.\n\n- ```text\n  Fixes #519\n  ```\n",
            # Unclosed fence runs to the end of its list item.
            "Old.\n\n- item\n\n  ```text\n  Fixes #519\n",
            # A tab-indented fence line inside the item.
            "Old.\n\n- item\n\n\t```text\n\tFixes #519\n\t```\n",
        ):
            with self.subTest(current=current):
                self.assertEqual(build_pr_body("New.", current), "New.")
        # Live text after the list item's fence is still preserved.
        current = "Old.\n\n- item\n\n  ```text\n  Fixes #1\n  ```\n\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        # A reference after an unclosed list fence that the item ended is live.
        current = "- item\n\n  ```text\n  Fixes #1\n\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")

    def test_closing_examples_in_proposed_code_preserved(self):
        for text in (
            "New.\n\n```md\nFixes #123\nCloses #4\n```\n\nMore.",
            "New.\n\n~~~\nResolves org/repo#5\n~~~",
            "New.\n\n- item\n\n  ```\n  Fixes #123\n  ```",
            "New.\n\n    Fixes #123\n\nMore.",
            "New.\n\n\tCloses #123",
            "Use `Fixes #123` to close an issue.",
            "Use ``Closes #123`` here.",
            "New.\n\n<!-- Fixes #123 -->",
        ):
            with self.subTest(text=text):
                self.assertEqual(build_pr_body(text, "Old."), text)

    def test_live_closing_instructions_beside_code_neutralized(self):
        for text, expected in (
            ("Fixes #5\n\n```\nFixes #123\n```", "```\nFixes #123\n```"),
            ("Intro.\nCloses #5\n\n    Closes #123", "Intro.\n\n    Closes #123"),
            ("Note: fixes #5.\n\n```\nFixes #123\n```", "Note: #5.\n\n```\nFixes #123\n```"),
            ("Note: closing #5, then `Fixes #123`.", "Note: #5, then `Fixes #123`."),
        ):
            with self.subTest(text=text):
                self.assertEqual(build_pr_body(text, "Old."), expected)

    def test_mixed_code_and_live_closing_instruction_keeps_code(self):
        for text, expected in (
            ("Use `Fixes #123` and fixes #5.", "Use `Fixes #123` and #5."),
            ("Fixes #5 as in `Fixes #123`.", "#5 as in `Fixes #123`."),
            ("- Closes #5 (`Closes #123`)", "- #5 (`Closes #123`)"),
            ("`x` resolves #5 and `Closes #1`", "`x` #5 and `Closes #1`"),
            ("Fixes\n#5 and `Fixes #123`", "#5 and `Fixes #123`"),
        ):
            with self.subTest(text=text):
                merged = build_pr_body(text, "Old.")
                self.assertEqual(merged, expected)
                self.assertIsNone(
                    re.search(r"(?i)\b(?:fix|close|resolve)\w*\b[\s:]*#5", merged)
                )

    def test_mixed_space_tab_indentation_is_code(self):
        for current in (
            "Old.\n\n  \tFixes #519\n",
            "Old.\n\n \t Fixes #519\n",
            "Old.\n\n   \tFixes #519\n",
            "Old.\n\n- item\n\n  \t  Fixes #519\n",
            "Old.\n\n- item\n\n\t\tFixes #519\n",
        ):
            with self.subTest(current=current):
                self.assertEqual(build_pr_body("New.", current), "New.")
        # Three columns of indentation is not code.
        self.assertEqual(build_pr_body("New.", "Old.\n\n   Fixes #519\n"), "New.\n\nFixes #519")

    def test_indented_code_directly_after_atx_heading(self):
        for current in (
            "# Heading\n    Fixes #519\n",
            "Old.\n\n## Heading ##\n\tFixes #519\n",
            "Old.\n\n### Heading\n  \tFixes #519\n",
        ):
            with self.subTest(current=current):
                self.assertEqual(build_pr_body("New.", current), "New.")
        # Indented text directly after a paragraph is still a continuation.
        self.assertEqual(
            build_pr_body("New.", "Old text\n    Fixes #519\n"), "New.\n\nFixes #519"
        )

    def test_setext_heading_then_indented_code(self):
        for current in (
            "Heading\n=======\n    Fixes #519\n",
            "Old.\n\nHeading\n---\n    Fixes #519\n",
            "Old.\n\nHeading\n-\n\tFixes #519\n",
            "Two line\nheading\n===\n    Fixes #519\n",
        ):
            with self.subTest(current=current):
                self.assertEqual(build_pr_body("New.", current), "New.")
        # Without a paragraph above it, "===" is text, and a paragraph
        # continuation is still not code.
        self.assertEqual(
            build_pr_body("New.", "Old text\n    Fixes #519\n===\n"), "New.\n\nFixes #519"
        )

    def test_blockquoted_fenced_code_is_masked(self):
        for current in (
            "Old.\n\n> ~~~\n> Fixes #519\n> ~~~\n",
            "Old.\n\n> ```text\n> Fixes #519\n> ```\n",
            ">~~~\n>Fixes #519\n>~~~\n",
            "> > ~~~\n> > Fixes #519\n> > ~~~\n",
            # Unclosed: the fence ends with its blockquote.
            "Old.\n\n> ~~~\n> Fixes #519\n",
            # Indented code and a list item inside the quote.
            "Old.\n\n>     Fixes #519\n",
            "Old.\n\n> - ~~~\n>   Fixes #519\n>   ~~~\n",
        ):
            with self.subTest(current=current):
                self.assertEqual(build_pr_body("New.", current), "New.")
        # The quote ending also ends its fence, so later text is live.
        self.assertEqual(
            build_pr_body("New.", "> ~~~\n> Fixes #1\n\nCloses #519\n"), "New.\n\nCloses #519"
        )
        self.assertEqual(
            build_pr_body("New.", "> ~~~\n> Fixes #1\nCloses #519\n"), "New.\n\nCloses #519"
        )
        # A reference in plain quoted text is live.
        self.assertEqual(build_pr_body("New.", "> Fixes #519\n"), "New.\n\nFixes #519")

    def test_quote_marker_inside_fence_content_does_not_end_fence(self):
        for current in (
            "Old.\n\n```\n> example\nCloses #111\n```\n",
            "Old.\n\n~~~\n> example\n> > nested\nCloses #111\n~~~\n",
            "- item\n\n  ```\n  > example\n  Closes #111\n  ```\n",
            "> ```\n> > example\n> Closes #111\n> ```\n",
        ):
            with self.subTest(current=current):
                self.assertEqual(build_pr_body("New.", current), "New.")
        # Text after the closed fence is live again.
        self.assertEqual(
            build_pr_body("New.", "```\n> example\nCloses #111\n```\nCloses #222\n"),
            "New.\n\nCloses #222",
        )

    def test_commented_reference_not_preserved(self):
        current = "Old.\n\n<!-- Fixes #111 -->\nCloses #222\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #222")
        multiline = "Old.\n\n<!--\nFixes #111\n-->\nCloses #222\n"
        self.assertEqual(build_pr_body("New.", multiline), "New.\n\nCloses #222")

    def test_commented_verification_heading_is_not_the_managed_tail(self):
        current = "Old.\n\n<!--\n---\n### Post-script verification\n-->\nCloses #222\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #222")

    def test_fence_marker_inside_comment_does_not_open_code(self):
        current = (
            "Old.\n<!--\n```\n-->\nCloses #519\n\n---\n\n"
            "### Post-script verification\n\n- [x] Secret scan passed"
        )
        merged = build_pr_body("New description.", current)
        self.assertTrue(merged.startswith("New description.\n\nCloses #519\n\n"))
        self.assertIn("### Post-script verification", merged)
        self.assertTrue(managed_sections_exposed(merged, current))

    def test_comment_marker_inside_code_stays_literal(self):
        # The "<!--" in the fence is code, so the reference after it is live.
        current = "Old.\n\n```\n<!--\n```\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        # A comment that closes on the same line as its fence marker text.
        self.assertEqual(
            build_pr_body("New.", "Old.\n<!-- ``` -->\nCloses #519\n"), "New.\n\nCloses #519"
        )

    def test_comment_marker_in_multiline_code_span_stays_literal(self):
        # A code span can cross lines, so the "<!--" inside it is not a comment
        # and the closing keyword after the span is live and must be removed.
        proposed = "New `one\ntext <!--\n` fixes #999\n-->"
        body = build_pr_body(proposed, "Old.\n\nCloses #519\n")
        self.assertNotIn("fixes #999", body)
        self.assertIn("#999", body)
        self.assertTrue(managed_sections_exposed(body, "Old.\n\nCloses #519\n"))
        # The same marker in the current body must not hide its reference.
        current = "Old.\n`example\ntext <!--\nend`\nCloses #519\n"
        merged = build_pr_body("New.", current)
        self.assertEqual(merged, "New.\n\nCloses #519")
        self.assertTrue(managed_sections_exposed(merged, current))

    def test_code_span_does_not_cross_block_boundary(self):
        # A heading ends the paragraph, so the "`" before it cannot pair with the
        # one after it and the "<!--" is a live comment that hides the managed
        # sections: the update must be rejected.
        proposed = "New `one\n# Heading\n<!--\nend` "
        body = build_pr_body(proposed, "Old.\n\nCloses #519\n")
        self.assertFalse(managed_sections_exposed(body, "Old.\n\nCloses #519\n"))
        # The same boundary in the current body leaves the comment live, so the
        # commented-out reference is not activated.
        current = "Old `x\n# Header\n<!-- hidden\n`\nCloses #519\n-->"
        self.assertEqual(build_pr_body("New.", current), "New.")
        # Other block interrupters end the span the same way.
        for boundary in ("***", "```\ncode\n```", "- item", "> quote", "<!--"):
            with self.subTest(boundary=boundary):
                current = f"Old `x\n{boundary}\ny <!-- hidden\n`\nCloses #519\n-->"
                self.assertNotIn("Closes #519", build_pr_body("New.", current))

    def test_escaped_backtick_does_not_open_code_span(self):
        # A backslash-escaped backtick is literal, so the keyword after it is
        # live prose and must still be neutralized.
        merged = build_pr_body("New \\`Fixes #999` text", "Old.\n\nCloses #519\n")
        self.assertNotRegex(merged, r"(?i)fixes\s+#999")
        # An escaped backslash does not escape the backtick, so the span is code.
        merged = build_pr_body("New \\\\`Fixes #999` text", "Old.\n\nCloses #519\n")
        self.assertIn("\\\\`Fixes #999` text", merged)
        # An unescaped span still protects its content.
        merged = build_pr_body("New `Fixes #999` text", "Old.\n\nCloses #519\n")
        self.assertIn("`Fixes #999`", merged)

    def test_list_marker_that_cannot_interrupt_paragraph_keeps_span(self):
        # "2. item" cannot interrupt a paragraph, so the code span runs across
        # it and the "<!--" is literal: the closing reference stays.
        current = "Old `x\n2. item\ntext <!--\nend`\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        # Markers that can interrupt a paragraph still end the span.
        for marker in ("1. item", "- item", "* item"):
            with self.subTest(marker=marker):
                current = f"Old `x\n{marker}\ny <!-- hidden\n`\nCloses #519\n-->"
                self.assertNotIn("Closes #519", build_pr_body("New.", current))
        # After a list item, a different marker starts a new list and splits.
        current = "- a `x\n2. item\ny <!-- hidden\n`\nCloses #519\n-->"
        self.assertNotIn("Closes #519", build_pr_body("New.", current))

    def test_quoted_list_items_split_code_spans(self):
        # A list marker inside a blockquote is a block boundary, so a span cannot
        # run across two quoted items and hide the live keyword between them.
        current = "Old.\n\nCloses #519\n"
        for proposed in (
            "> - a `x\n> - Fixes #999\n> - b `y",
            "> 1. a `x\n> 1. Fixes #999\n> 1. b `y",
            "> > - a `x\n> > - Fixes #999\n> > - b `y",
            "> > 1. a `x\n> > 1. Fixes #999\n> > 1. b `y",
            "> a `x\n> - Fixes #999\n> b `y",
        ):
            with self.subTest(proposed=proposed):
                merged = build_pr_body(proposed, current)
                self.assertNotRegex(merged, r"(?i)fixes\s+#999")
                self.assertIn("#999", merged)

    def test_quote_depth_change_and_nested_list_transitions(self):
        current = "Old.\n\nCloses #519\n"
        # A change of quote depth restarts list state, so the second "2." is
        # plain text after the paragraph and the span crosses it.
        merged = build_pr_body("> - a\n> > x `y\n> > 2. Fixes #999\n> > z `", current)
        self.assertIn("Fixes #999", merged)
        # An item nested in a list item still interrupts a quoted paragraph.
        merged = build_pr_body("> - a\n>   - b `x\n>   - Fixes #999\n>   - c `", current)
        self.assertNotRegex(merged, r"(?i)fixes\s+#999")
        # Going back to the outer item inside the same quote keeps the list.
        merged = build_pr_body("> - a\n>   - b\n> - c `x\n> - Fixes #999\n> - d `", current)
        self.assertNotRegex(merged, r"(?i)fixes\s+#999")

    def test_commented_reference_stays_inactive_after_quoted_list_interruption(self):
        for marker in ("- item", "1. item"):
            with self.subTest(marker=marker):
                current = f"> Old `x\n> {marker}\n> y <!-- hidden\n> `\nCloses #519\n-->"
                self.assertEqual(build_pr_body("New.", current), "New.")
                current = f"> > Old `x\n> > {marker}\n> > y <!-- hidden\n> > `\nCloses #519\n-->"
                self.assertEqual(build_pr_body("New.", current), "New.")

    def test_heading_ending_list_keeps_live_closing_reference(self):
        # An unindented heading ends the list, so "2. item" later is plain
        # paragraph text and the span runs across it.
        current = "- item\n# Heading\nOld `x\n2. item\ntext <!--\nend`\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        quoted = "> - item\n> # Heading\n> Old `x\n> 2. item\n> text <!--\n> end`\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", quoted), "New.\n\nCloses #519")

    def test_ordered_marker_that_cannot_interrupt_paragraph_does_not_open_fence(self):
        # "2. ```" inside a paragraph is paragraph text: the backtick runs form
        # an inline code span, so the example reference stays inert.
        current = "Old paragraph\n2. ```\nCloses #519\nend ```"
        self.assertEqual(build_pr_body("New.", current), "New.")
        # A marker that can interrupt still opens a list item and its fence.
        current = "Old paragraph\n1. ```\n   Closes #999\n   ```\n\nCloses #519"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")

    def test_list_ended_by_blank_line_keeps_span_across_ordered_marker(self):
        current = "- item\n\nOld `x\n2. item\ntext <!--\nend`\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")

    def test_nested_ordered_marker_in_list_item_paragraph_keeps_span(self):
        # "  2. text" is inside the item's content and cannot interrupt its
        # paragraph, so the code span runs across it and "<!--" is literal.
        current = "- Old `x\n  2. text\n  text <!--\n  end`\n\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        quoted = "> - Old `x\n>   2. text\n>   text <!--\n>   end`\n\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", quoted), "New.\n\nCloses #519")
        # A marker that can interrupt, or that sits outside the item, still splits.
        for marker in ("  1. text", "  - text", "2. text"):
            with self.subTest(marker=marker):
                current = f"- Old `x\n{marker}\n  y <!-- hidden\n  `\nCloses #519\n-->"
                self.assertNotIn("Closes #519", build_pr_body("New.", current))
        # Sibling ordered items split as before.
        current = "1. Old `x\n2. text\ny <!-- hidden\n`\nCloses #519\n-->"
        self.assertNotIn("Closes #519", build_pr_body("New.", current))

    def test_reference_in_closed_raw_html_block_not_preserved(self):
        for tag in ("pre", "script", "style", "textarea"):
            with self.subTest(tag=tag):
                current = f"Old.\n\n<{tag}>\nFixes #999\n</{tag}>\n\nCloses #519\n"
                self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        merged = build_pr_body("New.", "Old.\n\n<pre>\nFixes #999\n</pre>\n")
        self.assertEqual(merged, "New.")
        # An inline tag in a paragraph does not start a block.
        current = "Old <pre>\nFixes #999\n</pre>\n"
        self.assertIn("Fixes #999", build_pr_body("New.", current))

    def test_reference_in_unclosed_or_contained_raw_html_block_not_preserved(self):
        # An unclosed block runs to the end of the text.
        self.assertEqual(build_pr_body("New.", "Old.\n\n<pre>\nFixes #999"), "New.")
        # A block inside a blockquote or list item is raw HTML too.
        for opener, line in (("> <pre>", "> "), ("- <pre>", "  "), ("> - <pre>", ">   ")):
            with self.subTest(opener=opener):
                closed = f"Old.\n\n{opener}\n{line}Fixes #999\n{line}</pre>\n\nCloses #519\n"
                self.assertEqual(build_pr_body("New.", closed), "New.\n\nCloses #519")
                unclosed = f"Old.\n\n{opener}\n{line}Fixes #999\n"
                self.assertEqual(build_pr_body("New.", unclosed), "New.")

    def test_unclosed_raw_html_block_ends_with_its_container(self):
        # The block runs to the end of its blockquote or list item, not the
        # text, so a top-level reference after it is kept.
        for opener, body in (
            ("> <pre>", "> example"),
            ("- <pre>", "  example"),
            ("> - <pre>", ">   example"),
            ("- > <pre>", "  > example"),
        ):
            with self.subTest(opener=opener):
                current = f"Old.\n\n{opener}\n{body}\n\nCloses #519\n"
                self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
                # Content inside the container stays literal.
                inside = f"Old.\n\n{opener}\n{body}\n{body.replace('example', 'Fixes #999')}\n"
                self.assertEqual(build_pr_body("New.", inside), "New.")

    def test_reference_in_html_pi_cdata_or_declaration_not_preserved(self):
        for opener, closer in (("<?php", "?>"), ("<![CDATA[", "]]>"), ("<!DOCTYPE x", ">")):
            with self.subTest(opener=opener):
                closed = f"Old.\n\n{opener}\nFixes #999\n{closer}\n\nCloses #519\n"
                self.assertEqual(build_pr_body("New.", closed), "New.\n\nCloses #519")
                unclosed = f"Old.\n\n{opener}\nFixes #999\n"
                self.assertEqual(build_pr_body("New.", unclosed), "New.")
                quoted = f"Old.\n\n> {opener}\n> Fixes #999\n\nCloses #519\n"
                self.assertEqual(build_pr_body("New.", quoted), "New.\n\nCloses #519")

    def test_nested_blockquote_starts_a_new_span_segment(self):
        # A span opened in the outer quote cannot close in the nested one, so
        # the nested "<!--" is a real comment and "Closes #999" stays hidden.
        current = "> Old `x\n> > text <!--\n> > end`\n> > Closes #999\n> > -->\n\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")

    def test_blank_line_in_blockquote_ends_the_quoted_paragraph(self):
        # The ">" line is blank inside the quote, so the span cannot cross it
        # and hide the real comment opener: "Closes #999" stays commented out.
        current = "> Old `x\n>\n> text <!--\n> end`\n> Closes #999\n> -->\n\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")

    def test_blank_line_in_blockquote_ends_span_when_next_paragraph_leaves_quote(self):
        # The next paragraph is outside the quote, but the span still cannot
        # cross the blank ">" line, so the real "<!--" hides "Closes #999".
        current = "> old `x\n>\ntext <!--\nend`\nCloses #999\n-->\n\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        # Nested quotes and list items behave the same.
        current = "> > old `x\n> >\ntext <!--\nend`\nCloses #999\n-->\n\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        # A span inside one quoted paragraph is still a span.
        current = "> old `x\n> text <!--\n> end`\n\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")

    def test_verification_heading_in_raw_html_block_is_not_the_managed_tail(self):
        # The heading inside <pre> is literal text, so it does not start the
        # managed block and its "Fixes #999" is not copied out as live text.
        current = "Old.\n\n<pre>\n### Post-script verification\n\nFixes #999\n</pre>"
        self.assertEqual(build_pr_body("New.", current), "New.")
        # A real heading after the block is still the managed tail.
        current = (
            "Old.\n\n<pre>\n### Post-script verification\n</pre>\n\nCloses #519\n\n---\n\n"
            "### Post-script verification\nok\n"
        )
        self.assertEqual(
            build_pr_body("New.", current),
            "New.\n\nCloses #519\n\n---\n\n### Post-script verification\nok",
        )
        # The same holds for a heading in a proposed body.
        proposed = "New.\n\n<pre>\n### Post-script verification\n</pre>\n\nMore."
        self.assertEqual(build_pr_body(proposed, ""), proposed)

    def test_fence_marker_in_raw_html_block_does_not_open_a_fence(self):
        for opener, closer in (("<pre>", "</pre>"), ("<?php", "?>"), ("<![CDATA[", "]]>")):
            with self.subTest(opener=opener):
                current = f"Old.\n\n{opener}\n```\n{closer}\n\nCloses #519\n"
                self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
                quoted = f"Old.\n\n> {opener}\n> ~~~\n> {closer}\n\nCloses #519\n"
                self.assertEqual(build_pr_body("New.", quoted), "New.\n\nCloses #519")
        # A comment opener in the block is literal too, so it hides nothing.
        current = "Old.\n\n<pre>\n<!--\n</pre>\n\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        # A closing keyword in a proposal is stripped, not shielded by a block.
        proposed = "New.\n\n<pre>\n```\n</pre>\n\nCloses #888\n"
        self.assertNotIn("Closes #888", build_pr_body(proposed, ""))

    def test_raw_html_block_in_list_item_continuation_is_contained(self):
        # The opener sits on a continuation line of an existing item, so the
        # block ends with the item and the top-level reference is kept.
        for item, cont in (("- item", "  "), ("1. item", "   "), ("> - item", ">   ")):
            with self.subTest(item=item):
                current = f"{item}\n{cont.rstrip()}\n{cont}<pre>\n{cont}example\n\nCloses #519\n"
                self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
                inside = f"{item}\n{cont.rstrip()}\n{cont}<pre>\n{cont}Fixes #999\n"
                self.assertEqual(build_pr_body("New.", inside), "New.")

    def test_reference_in_html_attribute_or_link_title_not_preserved(self):
        for body in (
            '<span title="Fixes #999">example</span>',
            "<a href='x' title='Closes #999'>x</a>",
            "<img alt=\"Resolves #999\" src=x />",
            '[x](https://example.com "Fixes #999")',
            "[x](https://example.com 'Fixes #999')",
            "[x](https://example.com (Fixes #999))",
            '![x](<a b> "Fixes #999")',
            '[x]: https://example.com "Fixes #999"',
        ):
            with self.subTest(body=body):
                current = f"{body}\n\nCloses #519\n"
                self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
                self.assertTrue(managed_sections_exposed("New.\n\nCloses #519", current))
                # A body that shows the reference only there does not expose it.
                self.assertFalse(managed_sections_exposed(f"New.\n\n{body}", current))
        # Prose around a link or tag is still live.
        current = "See [x](https://example.com) and <b>bold</b>. Closes #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        # Text that is not a link or tag is still live.
        current = "[x](Fixes #519) and 1 < 2 > 0\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nFixes #519")

    def test_inline_html_tag_line_does_not_split_code_span(self):
        # "<span>" is an HTML block of type 7, which cannot interrupt a
        # paragraph, so the span crosses it and "<!--" is literal.
        current = "Old `x\n<span>\ntext <!--\nend`\nCloses #519\n"
        self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        # A block-level tag can interrupt, so it still splits.
        current = "Old `x\n<div>\ntext <!-- hidden\n`\nCloses #519\n-->"
        self.assertNotIn("Closes #519", build_pr_body("New.", current))

    def test_multiline_span_within_one_list_item_stays_code(self):
        # A span that crosses lines inside one item is still a span, quoted or not.
        for prefix in ("", "> "):
            with self.subTest(prefix=prefix):
                current = f"{prefix}- a `x\n{prefix}  text <!--\n{prefix}  end`\nCloses #519\n"
                self.assertEqual(build_pr_body("New.", current), "New.\n\nCloses #519")
        merged = build_pr_body("> - a `one\n>   Fixes #999\n>   end`", "Old.\n\nCloses #519\n")
        self.assertIn("Fixes #999", merged)

    def test_indented_closing_reference_at_start_of_proposal_neutralized(self):
        for proposed in (
            "    Fixes #999\n\nNew description.",
            "\n\n    Closes #999\n\nNew description.",
            "Fixes #1\n\n    Fixes #999\n\nNew description.",
        ):
            with self.subTest(proposed=proposed):
                merged = build_pr_body(proposed, LIVE_BODY)
                self.assertNotRegex(merged, r"(?i)fixes\s+#999|closes\s+#999")
                self.assertIn("New description.", merged)

    def test_reference_line_with_prose_keeps_the_prose(self):
        merged = build_pr_body(
            "Fixes #519 by moving the configuration to docs/code.md.\n\nTests: 122 passed.",
            "Old.",
        )
        self.assertNotRegex(merged, r"(?i)fixes")
        self.assertIn("by moving the configuration to docs/code.md.", merged)
        self.assertIn("Tests: 122 passed.", merged)
        bullet = build_pr_body("- Closes #519 and updates the docs\n\nMore.", "Old.")
        self.assertNotRegex(bullet, r"(?i)closes")
        self.assertIn("and updates the docs", bullet)
        # A line made only of references is still dropped.
        self.assertEqual(build_pr_body("- Fixes #519.\n\nMore.", "Old."), "More.")

    def test_plain_body_replaced(self):
        self.assertEqual(build_pr_body("New.", "Old."), "New.")

    def test_empty_after_stripping(self):
        self.assertEqual(build_pr_body("Closes #5", LIVE_BODY), "")


class TestManagedSectionsExposed(unittest.TestCase):
    def _exposed(self, proposed, current=LIVE_BODY):
        return managed_sections_exposed(build_pr_body(proposed, current), current)

    def test_ordinary_proposals_are_exposed(self):
        for proposed in (
            "New description.",
            "New.\n\n```text\nclosed example\n```\n\nMore.",
            "New.\n\n~~~\nclosed\n~~~",
            "New. <!-- closed comment --> text",
            "New.\n\n<!--\nmulti\nline\n-->",
            "New.\n\n> quote",
        ):
            with self.subTest(proposed=proposed):
                self.assertTrue(self._exposed(proposed))

    def test_unclosed_fence_hides_managed_sections(self):
        for proposed in (
            "New description.\n\n```text",
            "New.\n\n```text\ncode never closed",
            "New.\n\n~~~",
        ):
            with self.subTest(proposed=proposed):
                self.assertFalse(self._exposed(proposed))
        # A fence the proposal closes does not leak into the appended text, and
        # a fence inside a list item or blockquote ends with its container.
        for proposed in ("New.\n\n```text\nx\n```", "New.\n\n- item\n\n  ```", "New.\n\n> ~~~\n> code"):
            with self.subTest(proposed=proposed):
                self.assertTrue(self._exposed(proposed))

    def test_quote_marker_in_fence_content_keeps_fence_active(self):
        self.assertFalse(self._exposed("New.\n\n```\n> example"))
        self.assertTrue(self._exposed("New.\n\n```\n> example\n```"))
        # A closed existing fence holding "> example" still masks a synthetic
        # closing reference, so it is not required to appear in the merged body.
        current = "Old.\n\n```\n> example\nCloses #111\n```\n"
        self.assertTrue(self._exposed("New.", current))

    def test_commented_reference_not_required_or_activated(self):
        current = "Old.\n\n<!-- Fixes #111 -->\nCloses #222\n"
        merged = build_pr_body("New.", current)
        self.assertNotIn("#111", merged)
        self.assertTrue(managed_sections_exposed(merged, current))

    def test_unclosed_html_comment_hides_managed_sections(self):
        for proposed in (
            "New.\n\n<!-- never closed",
            "New. <!-- never closed",
            "New.\n\n<!--",
            "New.\n\n<!-->",
        ):
            with self.subTest(proposed=proposed):
                self.assertFalse(self._exposed(proposed))

    def test_unclosed_raw_html_block_hides_managed_sections(self):
        for proposed in (
            "New.\n\n<pre>",
            "New.\n\n<PRE class=x>\ncode",
            "New.\n\n<script>",
            "New.\n\n<style>",
            "New.\n\n<textarea>",
            "New.\n\n<?php",
            "New.\n\n<![CDATA[ open",
            "New.\n\n<!DOCTYPE html",
        ):
            with self.subTest(proposed=proposed):
                self.assertFalse(self._exposed(proposed))
        for proposed in (
            "New.\n\n<pre>\nx\n</pre>",
            "New.\n\n<script>x</script>",
            "New with `<pre>` in a span.",
            "New.\n\n```\n<pre>\n```",
            "New.\n\n<!-- <pre> -->",
        ):
            with self.subTest(proposed=proposed):
                self.assertTrue(self._exposed(proposed))
        self.assertTrue(self._exposed("New.\n\n<pre>", "Old."))

    def test_comment_marker_in_code_is_not_a_comment(self):
        self.assertTrue(self._exposed("New.\n\n```\n<!-- literal\n```"))
        self.assertTrue(self._exposed("New with `<!--` in a span."))

    def test_only_references_without_verification_block(self):
        current = "Old.\n\nCloses #519"
        self.assertTrue(self._exposed("New.", current))
        self.assertFalse(self._exposed("New.\n\n```", current))
        self.assertFalse(self._exposed("New.\n\n<!--", current))

    def test_nothing_to_preserve(self):
        self.assertTrue(self._exposed("New.\n\n```", "Old."))

    def test_unrendered_current_sections_are_not_required(self):
        current = "Old.\n\n```text\n### Post-script verification\n```\n"
        self.assertTrue(self._exposed("New.", current))


@patch.dict(os.environ, _SCHEMA_ENV)
class TestPrMetadataSchema(unittest.TestCase):
    def _valid(self, **fields):
        import jsonschema

        with open(_SCHEMA_PATH) as f:
            schema = json.load(f)
        try:
            jsonschema.validate(instance=_metadata_result(**fields), schema=schema)
            return True
        except jsonschema.ValidationError:
            return False

    def test_accepts_without_fields(self):
        self.assertTrue(self._valid())

    def test_accepts_with_fields(self):
        self.assertTrue(self._valid(**_both_fields()))

    def test_accepts_either_field_alone(self):
        self.assertTrue(self._valid(pr_title="t", pr_title_base_sha256=_sha("x")))
        self.assertTrue(self._valid(pr_body="b", pr_body_base_sha256=_sha("x")))

    def test_rejects_empty_or_blank(self):
        self.assertFalse(self._valid(**_both_fields(pr_title="")))
        self.assertFalse(self._valid(**_both_fields(pr_title="   ")))
        self.assertFalse(self._valid(**_both_fields(pr_body="")))
        self.assertFalse(self._valid(**_both_fields(pr_body=" \n ")))

    def test_rejects_over_length(self):
        self.assertTrue(self._valid(**_both_fields(pr_title="t" * 200)))
        self.assertFalse(self._valid(**_both_fields(pr_title="t" * 201)))
        self.assertTrue(self._valid(**_both_fields(pr_body="b" * 8000)))
        self.assertFalse(self._valid(**_both_fields(pr_body="b" * 8001)))

    def test_rejects_title_newlines(self):
        for title in ("a\nb", "a\rb", "title\n", "\ntitle"):
            self.assertFalse(self._valid(**_both_fields(pr_title=title)), repr(title))

    def test_accepts_multiline_body(self):
        self.assertTrue(self._valid(**_both_fields(pr_body=NEW_BODY)))

    def test_requires_base_hash(self):
        self.assertFalse(self._valid(pr_title="t"))
        self.assertFalse(self._valid(pr_body="b"))
        self.assertFalse(self._valid(pr_title="t", pr_body_base_sha256=_sha("x")))

    def test_rejects_malformed_base_hash(self):
        self.assertFalse(self._valid(pr_title="t", pr_title_base_sha256="abc"))
        self.assertFalse(self._valid(pr_title="t", pr_title_base_sha256=_sha("x").upper()))
        self.assertFalse(self._valid(pr_title="t", pr_title_base_sha256=_sha("x") + "\n"))


if __name__ == "__main__":
    unittest.main()
