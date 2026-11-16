"""Tests for the parts of cve_workflow.py that differ from cve-workflow-experiment.

Run: python3 -m unittest discover -s scripts/cve -p 'test_*.py'
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cve_workflow as workflow  # noqa: E402

GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "test",
    "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "test",
    "GIT_COMMITTER_EMAIL": "test@example.com",
}


def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True,
                          env={**os.environ, **GIT_ENV}).stdout.strip()


def write_policy(folder, **extra):
    policy = {"jira": {"base_url": "https://example.atlassian.net", "account_email": "bot@example.com"}}
    policy.update(extra)
    path = Path(folder) / "cve-policy.json"
    path.write_text(json.dumps(policy))
    return str(path)


class TrustedSettingsTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)

    def test_jira_site_and_account_come_from_the_policy(self):
        policy = write_policy(self.folder.name)
        with mock.patch.dict(os.environ, {"CVE_POLICY_FILE": policy}):
            workflow.Jira("https://example.atlassian.net", "bot@example.com", "token")
            for url, email, token in (("https://other.atlassian.net", "bot@example.com", "token"),
                                      ("https://example.atlassian.net", "person@example.com", "token"),
                                      ("https://example.atlassian.net", "bot@example.com", "")):
                with self.assertRaises(workflow.GateError):
                    workflow.Jira(url, email, token)

    def test_no_policy_refuses_jira_and_keeps_github_only_origins(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(workflow.GateError):
                workflow.Jira("https://example.atlassian.net", "bot@example.com", "token")
            self.assertEqual(workflow.repository_identity("https://github.com/acme/demo.git"), "acme/demo")
            with self.assertRaises(workflow.TargetUnresolved):
                workflow.repository_identity("https://gitlab.example.com/acme/demo.git")

    def test_forge_origin_drops_the_job_token(self):
        policy = write_policy(self.folder.name, forge_url="https://gitlab.example.com")
        with mock.patch.dict(os.environ, {"CVE_POLICY_FILE": policy}):
            self.assertEqual(
                workflow.repository_identity("https://gitlab-ci-token:SECRET@gitlab.example.com/group/sub/demo.git"),
                "group/sub/demo")
            for remote in ("https://gitlab.other.com/group/demo.git", "http://gitlab.example.com/group/demo.git"):
                with self.assertRaises(workflow.TargetUnresolved):
                    workflow.repository_identity(remote)


class SettingsTreeTest(unittest.TestCase):
    """The mapped branch is checked out where the run keeps its .fullsend settings."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        root = Path(self.folder.name)
        self.origin = root / "origin"
        work = root / "seed"
        git("init", "-q", "-b", "main", str(work), cwd=root)
        (work / ".fullsend").mkdir()
        (work / ".fullsend/config.yaml").write_text("tracker: trusted\n")
        (work / "requirements.txt").write_text("Jinja2==3.1.6\n")
        git("add", "-A", cwd=work)
        git("commit", "-q", "-m", "main", cwd=work)
        git("checkout", "-q", "-b", "release-same", cwd=work)
        (work / "requirements.txt").write_text("Jinja2==3.1.5\n")
        git("commit", "-q", "-am", "same settings", cwd=work)
        git("checkout", "-q", "-b", "release-other", "main", cwd=work)
        (work / ".fullsend/config.yaml").write_text("tracker: elsewhere\n")
        git("commit", "-q", "-am", "other settings", cwd=work)
        git("clone", "-q", "--bare", str(work), str(self.origin), cwd=root)
        self.target = root / "project"
        git("clone", "-q", "--branch", "main", str(self.origin), str(self.target), cwd=root)
        env = {"FULLSEND_DIR": str(self.target / ".fullsend")}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        identity = mock.patch.object(workflow, "repository_identity", return_value="acme/demo")
        identity.start()
        self.addCleanup(identity.stop)

    def context(self, branch):
        return {"target": {"repository": "acme/demo", "branch": branch}}

    def test_branch_with_the_same_settings_is_checked_out(self):
        workflow.prepare_mapped_source(self.context("release-same"), self.target)
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.target),
                         git("rev-parse", "refs/remotes/origin/release-same", cwd=self.target))
        self.assertEqual((self.target / "requirements.txt").read_text(), "Jinja2==3.1.5\n")
        self.assertEqual((self.target / ".fullsend/config.yaml").read_text(), "tracker: trusted\n")

    def test_branch_with_other_settings_is_refused_before_checkout(self):
        before = git("rev-parse", "HEAD", cwd=self.target)
        with self.assertRaisesRegex(workflow.TargetUnresolved, "different .fullsend settings"):
            workflow.prepare_mapped_source(self.context("release-other"), self.target)
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.target), before)
        self.assertEqual((self.target / ".fullsend/config.yaml").read_text(), "tracker: trusted\n")

    def test_settings_outside_the_checkout_are_not_compared(self):
        with mock.patch.dict(os.environ, {"FULLSEND_DIR": self.folder.name + "/elsewhere/.fullsend"}):
            workflow.prepare_mapped_source(self.context("release-other"), self.target)
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.target),
                         git("rev-parse", "refs/remotes/origin/release-other", cwd=self.target))


class PublisherTest(unittest.TestCase):
    def test_publisher_is_the_stock_script_next_to_this_module(self):
        path = Path(workflow.upstream_publisher())
        self.assertEqual(path, Path(workflow.__file__).resolve().parent.parent / "post-code.sh")
        self.assertTrue(path.is_file())


if __name__ == "__main__":
    unittest.main()
