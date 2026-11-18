"""Tests for cve_alerts.py. No network: GitHub and Jira are stand-ins.

Run: python3 -m unittest discover -s scripts/cve -p 'test_*.py'
"""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cve_alerts as alerts  # noqa: E402
import cve_workflow as workflow  # noqa: E402

GHSA = "GHSA-2345-6789-cfgh"
GO_MOD = """module example.com/service

go 1.24

require (
\texample.com/web/v5 v5.2.1
\texample.com/engine v28.0.0+incompatible
\texample.com/forked v1.0.0
)

require example.com/telemetry/sdk v1.30.0 // indirect

replace example.com/forked => ../forked
replace example.com/engine v28.0.0+incompatible => example.com/engine v28.1.0+incompatible
"""


def policy(**alert_block):
    with tempfile.TemporaryDirectory() as folder:
        (Path(folder) / "release-mappings.yaml").write_text(
            json.dumps(
                {
                    "version": 2,
                    "products": {
                        "service": {
                            "repository": "example-org/service",
                            "versions": {
                                version: {
                                    "branch": "release-" + version,
                                    "component": ".",
                                    "manifest": "go.mod",
                                    "manifest_format": "go-module",
                                    "manifest_identity": "example.com/service",
                                    "owner": "example-team",
                                }
                                for version in ("1.3", "1.4")
                            },
                        }
                    },
                }
            )
        )
        path = Path(folder) / "cve-policy.json"
        path.write_text(
            json.dumps(
                {
                    "repository": "example-org/service",
                    "project": "PROJ",
                    "jira": {"base_url": "https://example.atlassian.net"},
                    "owners": ["example-team"],
                    "fix_category": "dependency-update",
                    "required_labels": ["fullsend-cve", "cve-public"],
                    "blocked_labels": ["embargoed"],
                    "release_mappings_file": "release-mappings.yaml",
                    **({"alerts": alert_block} if alert_block else {}),
                }
            )
        )
        return workflow.read_policy_file(path)


def alert(number, package, vulnerable_range, cve="CVE-2026-10001", ecosystem="go", manifest="go.mod"):
    return {
        "number": number,
        "dependency": {
            "package": {"ecosystem": ecosystem, "name": package},
            "manifest_path": manifest,
            "scope": "runtime",
        },
        "security_advisory": {"ghsa_id": GHSA, "cve_id": cve, "severity": "high", "withdrawn_at": None},
        "security_vulnerability": {
            "vulnerable_version_range": vulnerable_range,
            "first_patched_version": {"identifier": "5.2.2"},
        },
    }


class FakeGitHub:
    def __init__(self, listing, manifests, advisory_cve="CVE-2026-10001"):
        self.listing, self.manifests, self.advisory_cve = listing, manifests, advisory_cve

    def alerts(self):
        return self.listing

    def branch_commit(self, branch):
        return ("a" if branch.endswith("1.3") else "b") * 40

    def file_at(self, path, sha):
        return self.manifests.get(sha[0])

    def public_advisory(self, ghsa):
        return {"ghsa_id": ghsa, "cve_id": self.advisory_cve, "withdrawn_at": None}


class FakeJira:
    def __init__(self, existing=()):
        self.existing, self.created = set(existing), []

    def request(self, method, path, body=None):
        if path == "/search/jql":
            label = body["jql"].rsplit('"', 2)[1]
            return {"issues": [{"key": "PROJ-1"}] if label in self.existing else []}
        if method == "POST" and path == "/issue":
            self.created.append(body)
            return {"key": f"PROJ-{100 + len(self.created)}"}
        raise AssertionError(path)


class VersionTest(unittest.TestCase):
    def test_orders_go_versions(self):
        key = alerts.version_key
        self.assertLess(key("v1.2.3"), key("1.2.4"))
        self.assertLess(key("v1.2.3-rc.1"), key("v1.2.3"))
        self.assertLess(key("v0.0.0-20240101000000-abcdef123456"), key("v0.0.1"))
        self.assertEqual(key("v28.0.0+incompatible"), key("28.0.0"))
        self.assertIsNone(key("latest"))

    def test_range(self):
        self.assertTrue(alerts.in_range("v5.2.1", "< 5.2.2"))
        self.assertFalse(alerts.in_range("v5.2.2", "< 5.2.2"))
        self.assertTrue(alerts.in_range("v1.30.0", ">= 1.20.0, < 1.40.0"))
        self.assertFalse(alerts.in_range("v1.10.0", ">= 1.20.0, < 1.40.0"))
        self.assertIsNone(alerts.in_range("v1.0.0", "before the fix"))
        self.assertIsNone(alerts.in_range("devel", "< 1.0.0"))


class GoModTest(unittest.TestCase):
    def test_reads_block_single_line_and_indirect(self):
        self.assertEqual(
            alerts.observe_go(GO_MOD, "example.com/web/v5"),
            {"module": "example.com/web/v5", "version": "v5.2.1", "indirect": False, "replaced": False},
        )
        self.assertTrue(alerts.observe_go(GO_MOD, "example.com/telemetry/sdk")["indirect"])

    def test_package_inside_a_module(self):
        self.assertEqual(alerts.observe_go(GO_MOD, "example.com/web/v5/middleware")["module"], "example.com/web/v5")
        self.assertIsNone(alerts.observe_go(GO_MOD, "example.com/absent"))

    def test_replacements(self):
        self.assertEqual(alerts.observe_go(GO_MOD, "example.com/engine")["version"], "v28.1.0+incompatible")
        self.assertTrue(alerts.observe_go(GO_MOD, "example.com/forked")["replaced"])


class CollectTest(unittest.TestCase):
    def collect(self, listing, **kwargs):
        patched = GO_MOD.replace("v5.2.1", "v5.2.2")
        return alerts.collect(policy(), FakeGitHub(listing, {"a": GO_MOD, "b": patched}, **kwargs))

    def test_one_candidate_per_affected_version(self):
        document = self.collect([alert(7, "example.com/web/v5", "< 5.2.2")])
        self.assertEqual([c["release"] for c in document["candidates"]], ["1.3"])
        candidate = document["candidates"][0]
        self.assertEqual(candidate["commit"], "a" * 40)
        self.assertEqual(candidate["outcome"], "in_vulnerable_range")
        self.assertEqual(candidate["observed"]["version"], "v5.2.1")
        self.assertEqual(
            [(s["release"], s["reason"]) for s in document["skipped"]],
            [("1.4", "required version v5.2.2 is outside the vulnerable range")],
        )

    def test_skips_what_it_cannot_place(self):
        document = self.collect(
            [
                alert(1, "left-pad", "< 1.0.0", ecosystem="npm", manifest="package-lock.json"),
                alert(2, "example.com/web/v5", "< 5.2.2", manifest="tools/go.mod"),
                alert(3, "example.com/web/v5", "< 5.2.2", cve=None),
                alert(4, "example.com/absent", "< 1.0.0"),
            ]
        )
        self.assertEqual(document["candidates"], [])
        reasons = [s["reason"] for s in document["skipped"]]
        self.assertIn("no evidence reader for ecosystem npm", reasons)
        self.assertIn("manifest tools/go.mod is not in the release mapping", reasons)
        self.assertIn("advisory has no CVE identifier", reasons)
        self.assertEqual(reasons.count("package not required on the mapped branch"), 2)

    def test_a_version_that_cannot_be_compared_stays_a_candidate(self):
        document = self.collect([alert(5, "example.com/forked", "< 2.0.0")])
        self.assertEqual({c["outcome"] for c in document["candidates"]}, {"undetermined"})
        self.assertEqual(len(document["candidates"]), 2)

    def test_advisory_must_be_confirmed_public(self):
        document = self.collect([alert(6, "example.com/web/v5", "< 5.2.2")], advisory_cve="CVE-2026-99999")
        self.assertEqual(document["candidates"], [])
        self.assertIn("public advisory could not be confirmed", [s["reason"] for s in document["skipped"]])


class PublishTest(unittest.TestCase):
    def document(self, settings=None):
        selected = policy(**(settings or {}))
        github = FakeGitHub([alert(7, "example.com/web/v5", "< 5.2.2")], {"a": GO_MOD, "b": GO_MOD})
        return selected, alerts.collect(selected, github)

    def test_creates_work_items_the_cve_gate_accepts(self):
        selected, document = self.document({"labels": ["team-queue"], "assignee_account_id": "abc123"})
        jira = FakeJira()
        report = alerts.publish(selected, document, jira)
        self.assertEqual(len(report["created"]), 2)
        body = jira.created[0]
        fields = body["fields"]
        self.assertEqual(fields["project"], {"key": "PROJ"})
        self.assertEqual(fields["assignee"], {"accountId": "abc123"})
        self.assertTrue({"fullsend-cve", "cve-public", "team-queue"}.issubset(fields["labels"]))
        self.assertEqual(fields["summary"], "CVE-2026-10001: example.com/web/v5 in service 1.3")
        intake = body["properties"][0]["value"]
        self.assertEqual(body["properties"][0]["key"], workflow.INTAKE_PROPERTY)
        self.assertEqual(intake["advisory_url"], "https://github.com/advisories/" + GHSA)
        # The record is the one the cve agent's own gate resolves to a target.
        self.assertEqual(workflow.resolve_target(intake, selected)["branch"], "release-1.3")

    def test_one_work_item_for_a_vulnerability_with_several_packages(self):
        selected = policy()
        listing = [alert(7, "example.com/web/v5", "< 5.2.2"), alert(8, "example.com/telemetry/sdk", "< 2.0.0")]
        document = alerts.collect(selected, FakeGitHub(listing, {"a": GO_MOD, "b": GO_MOD}))
        self.assertEqual(len(document["candidates"]), 4)
        jira = FakeJira()
        alerts.publish(selected, document, jira)
        self.assertEqual(len(jira.created), 2)
        fields = jira.created[0]["fields"]
        self.assertEqual(fields["summary"], "CVE-2026-10001: example.com/web/v5 and 1 more in service 1.3")
        text = workflow.adf_plain_text(fields["description"]["content"][0])
        self.assertIn("example.com/telemetry/sdk", text)

    def test_skips_a_candidate_that_already_has_a_work_item(self):
        selected, document = self.document()
        label = "fullsend-cve-alert-" + document["candidates"][0]["key"]
        jira = FakeJira(existing=[label])
        report = alerts.publish(selected, document, jira)
        self.assertEqual(len(report["existing"]), 1)
        self.assertEqual(len(jira.created), 1)

    def test_limit_and_dry_run(self):
        selected, document = self.document({"max_new_work_items": 1})
        jira = FakeJira()
        report = alerts.publish(selected, document, jira)
        self.assertEqual((len(report["created"]), report["over_limit"]), (1, 1))
        dry = FakeJira()
        alerts.publish(selected, document, dry, dry_run=True)
        self.assertEqual(dry.created, [])

    def test_the_file_cannot_add_a_target(self):
        selected, document = self.document()
        widened = json.loads(json.dumps(document))
        widened["candidates"][0]["release"] = "9.9"
        widened["candidates"][1]["repository"] = "example-org/other"
        jira = FakeJira()
        report = alerts.publish(selected, widened, jira)
        self.assertEqual((report["refused"], jira.created), (2, []))
        with self.assertRaises(workflow.GateError):
            alerts.publish(selected, {**document, "repository": "example-org/other"}, jira)

    def test_rejects_a_malformed_alerts_block(self):
        for block in ({"max_new_work_items": 0}, {"labels": ["has space"]}, {"unknown": 1}):
            with self.assertRaises(workflow.GateError):
                alerts.alert_settings({"alerts": block})


class TokenPermissionTest(unittest.TestCase):
    def test_app_token_helper_accepts_narrower_permissions(self):
        import inspect

        self.assertIn("permissions", inspect.signature(workflow.github_app_token).parameters)


if __name__ == "__main__":
    unittest.main()
