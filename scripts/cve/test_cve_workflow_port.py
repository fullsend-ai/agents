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

    def test_branch_that_moved_since_an_earlier_job_is_fetched_again(self):
        # A persistent runner keeps the checkout, so the ref from an earlier
        # shallow fetch is still there when the branch has new commits.
        workflow.prepare_mapped_source(self.context("release-same"), self.target)
        git("checkout", "-q", "--detach", "origin/main", cwd=self.target)
        seed = Path(self.folder.name) / "seed"
        git("checkout", "-q", "release-same", cwd=seed)
        (seed / "requirements.txt").write_text("Jinja2==3.1.4\n")
        git("commit", "-q", "-am", "later commit", cwd=seed)
        git("push", "-q", str(self.origin), "release-same", cwd=seed)
        workflow.prepare_mapped_source(self.context("release-same"), self.target)
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.target), git("rev-parse", "release-same", cwd=seed))
        self.assertEqual((self.target / "requirements.txt").read_text(), "Jinja2==3.1.4\n")

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



class RemoteSourceTest(unittest.TestCase):
    """A source repository on GitHub while the job runs in another project."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        root = Path(self.folder.name)
        # The job's own project: settings on main, checked out as CI would.
        seed = root / "seed"
        git("init", "-q", "-b", "main", str(seed), cwd=root)
        (seed / ".fullsend").mkdir()
        (seed / ".fullsend/config.yaml").write_text("tracker: trusted\n")
        (seed / ".gitlab-ci.yml").write_text("include: []\n")
        (seed / "app.py").write_text("print(1)\n")
        git("add", "-A", cwd=seed)
        git("commit", "-q", "-m", "job project", cwd=seed)
        self.job = root / "job"
        git("clone", "-q", str(seed), str(self.job), cwd=root)
        # The source repository, standing in for GitHub.
        upstream = root / "upstream"
        git("init", "-q", "-b", "release-1.3", str(upstream), cwd=root)
        (upstream / "go.mod").write_text("module example\n")
        git("add", "-A", cwd=upstream)
        git("commit", "-q", "-m", "source", cwd=upstream)
        git("checkout", "-q", "-b", "with-settings", cwd=upstream)
        (upstream / ".fullsend").mkdir()
        (upstream / ".fullsend/config.yaml").write_text("tracker: elsewhere\n")
        git("add", "-A", cwd=upstream)
        git("commit", "-q", "-m", "carries settings", cwd=upstream)
        self.source = {"repository": "acme/service", "host_project": "group/runner",
                       "url": str(upstream)}
        self.tip = git("rev-parse", "release-1.3", cwd=upstream)
        patch = mock.patch.dict(os.environ, GIT_ENV)
        patch.start()
        self.addCleanup(patch.stop)

    def context(self, branch):
        return {"target": {"repository": "acme/service", "branch": branch}}

    def test_policy_source_block(self):
        good = write_policy(self.folder.name, repository="acme/service",
                            source={"forge": "github", "host_project": "group/sub/runner"})
        with mock.patch.dict(os.environ, {"CVE_POLICY_FILE": good}):
            source = workflow.remote_source()
            self.assertEqual(source["url"], "https://github.com/acme/service.git")
            self.assertEqual(workflow.job_repository({"repository": "acme/service"}), "group/sub/runner")
        plain = write_policy(self.folder.name, repository="acme/service")
        with mock.patch.dict(os.environ, {"CVE_POLICY_FILE": plain}):
            self.assertIsNone(workflow.remote_source())
            self.assertEqual(workflow.job_repository({"repository": "acme/service"}), "acme/service")
        for bad in ({"forge": "gitlab", "host_project": "group/runner"},
                    {"forge": "github", "host_project": "runner"},
                    {"forge": "github", "host_project": "group/runner", "url": "https://evil.example"},
                    "github"):
            policy = write_policy(self.folder.name, repository="acme/service", source=bad)
            with mock.patch.dict(os.environ, {"CVE_POLICY_FILE": policy}):
                with self.assertRaises(workflow.GateError):
                    workflow.remote_source()

    def test_source_branch_replaces_the_tree_and_keeps_the_run_settings(self):
        workflow.prepare_remote_source(self.context("release-1.3"), self.job, self.source, token="t")
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.job), self.tip)
        self.assertEqual(git("remote", "get-url", "origin", cwd=self.job), self.source["url"])
        self.assertTrue((self.job / "go.mod").is_file())
        self.assertFalse((self.job / "app.py").exists())
        self.assertEqual((self.job / ".fullsend/config.yaml").read_text(), "tracker: trusted\n")
        self.assertTrue((self.job / ".gitlab-ci.yml").is_file())
        # Restored settings are ignored, so the coder cannot commit them.
        self.assertEqual(git("status", "--porcelain", cwd=self.job), "")
        # A second call, as the publication check makes, changes nothing.
        workflow.prepare_remote_source(self.context("release-1.3"), self.job, self.source, token="t")
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.job), self.tip)
        self.assertEqual((self.job / ".fullsend/config.yaml").read_text(), "tracker: trusted\n")

    def test_source_branch_with_settings_paths_is_refused(self):
        before = git("rev-parse", "HEAD", cwd=self.job)
        with self.assertRaises(workflow.TargetUnresolved):
            workflow.prepare_remote_source(self.context("with-settings"), self.job, self.source, token="t")
        self.assertEqual(git("rev-parse", "HEAD", cwd=self.job), before)
        self.assertEqual((self.job / ".fullsend/config.yaml").read_text(), "tracker: trusted\n")

    def test_other_repository_is_refused(self):
        with self.assertRaises(workflow.TargetUnresolved):
            workflow.prepare_remote_source(
                {"target": {"repository": "acme/other", "branch": "release-1.3"}},
                self.job, self.source, token="t")

    def test_publisher_gets_github_identity_and_no_gitlab_credentials(self):
        workflow.prepare_remote_source(self.context("release-1.3"), self.job, self.source, token="t")
        seen = Path(self.folder.name) / "seen.json"
        publisher = Path(self.folder.name) / "publisher.sh"
        publisher.write_text(
            "python3 -c 'import json,os,sys; json.dump(dict(os.environ), open(sys.argv[1], \"w\"))' "
            + str(seen) + "\n")
        env = {"REPO_DIR": str(self.job), "CODE_ALLOWED_TARGET_BRANCHES": "release-1.3",
               "GITLAB_TOKEN": "gl", "FULLSEND_JOB_TOKEN": "job", "FULLSEND_GITLAB_CODER_TOKEN": "coder",
               "CVE_PUBLISHER_GITHUB_APP_KEY_B64": "key", "FULLSEND_FORGE": "gitlab",
               "REPO_FULL_NAME": "group/runner", "JIRA_TOKEN": "jira"}
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(workflow, "remote_source", return_value=self.source), \
                mock.patch.object(workflow, "github_app_token", return_value="gh-token"):
            self.assertEqual(workflow.publish_remote(str(publisher)), 0)
        got = json.loads(seen.read_text())
        self.assertEqual((got["FULLSEND_FORGE"], got["REPO_FULL_NAME"], got["PUSH_TOKEN"], got["GH_TOKEN"]),
                         ("github", "acme/service", "gh-token", "gh-token"))
        self.assertEqual(got["GITHUB_SIGNED_COMMITS"], "true")
        self.assertEqual(got["JIRA_TOKEN"], "jira")
        for name in ("GITLAB_TOKEN", "FULLSEND_JOB_TOKEN", "FULLSEND_GITLAB_CODER_TOKEN",
                     "CVE_PUBLISHER_GITHUB_APP_KEY_B64"):
            self.assertNotIn(name, got)
        self.assertEqual(git("remote", "get-url", "origin", cwd=self.job), self.source["url"])

    def test_publisher_output_never_shows_the_token(self):
        workflow.prepare_remote_source(self.context("release-1.3"), self.job, self.source, token="t")
        publisher = Path(self.folder.name) / "publisher.sh"
        publisher.write_text(
            'echo "::add-mask::${PUSH_TOKEN}"\n'
            'echo "pushing to https://x-access-token:${PUSH_TOKEN}@github.com/acme/service.git" >&2\n'
            'echo "PR created"\n')
        env = {"REPO_DIR": str(self.job), "CODE_ALLOWED_TARGET_BRANCHES": "release-1.3"}
        import contextlib
        import io
        shown = io.StringIO()
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(workflow, "remote_source", return_value=self.source), \
                mock.patch.object(workflow, "github_app_token", return_value="gh-secret-token"), \
                contextlib.redirect_stdout(shown):
            self.assertEqual(workflow.publish_remote(str(publisher)), 0)
        self.assertNotIn("gh-secret-token", shown.getvalue())
        self.assertNotIn("add-mask", shown.getvalue())
        self.assertIn("x-access-token:[redacted]@github.com", shown.getvalue())
        self.assertIn("PR created", shown.getvalue())



class Rs256Test(unittest.TestCase):
    def test_signature_verifies_with_an_independent_library(self):
        try:
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import padding, rsa
        except ImportError:
            self.skipTest("cryptography is not installed")
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
                                serialization.NoEncryption())
        message = b"header.payload"
        key.public_key().verify(workflow.rs256_signature(pem, message), message,
                                padding.PKCS1v15(), hashes.SHA256())
        with self.assertRaises(ValueError):
            workflow.rs256_signature(b"-----BEGIN " + b"PRIVATE KEY-----\nAAAA\n", message)


if __name__ == "__main__":
    unittest.main()
