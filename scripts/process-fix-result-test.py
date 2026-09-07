#!/usr/bin/env python3
"""Tests for process-fix-result.py."""

import contextlib
import io
import json
import os
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


if __name__ == "__main__":
    unittest.main()
