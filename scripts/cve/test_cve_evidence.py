"""Tests for cve-evidence.py against real OSV records for CVE-2025-27516 and a
synthetic CSAF VEX document from a made-up vendor.

Run: python3 -I -m unittest discover -s scripts/cve -p 'test_*.py'
"""
import importlib.util
import io
import json
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIX = HERE / "test-fixtures" / "cve-2025-27516"
spec = importlib.util.spec_from_file_location("cve_evidence", HERE / "cve-evidence.py")
cve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cve)


def run(*argv):
    buf = io.StringIO()
    with redirect_stdout(buf):
        cve.main(list(argv))
    return json.loads(buf.getvalue())


class AdvisoryTest(unittest.TestCase):
    def test_range_comes_from_alias_record_and_fix_commits_from_cve_record(self):
        out = run("advisory", "--finding", str(FIX / "finding.json"), "--evidence", str(FIX / "evidence"))
        self.assertEqual(out["fixed"], ["3.1.6"])
        self.assertIn("GHSA-cpwx-vrp4-4pq7", out["aliases"])
        commits = {c["commit"] for c in out["fix_commits"]}
        self.assertIn("90457bbf33b8662926ae65cdde4c4c32e756e403", commits)
        self.assertEqual(out["gaps"], [])

    def test_missing_evidence_is_a_gap_not_an_error(self):
        out = run("advisory", "--finding", str(FIX / "finding.json"), "--evidence", str(FIX / "nope"))
        self.assertTrue(out["gaps"])


    def test_withheld_vendor_vex_is_reported_as_withheld_not_absent(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "cve-evidence.json"
            bundle.write_text(json.dumps({"osv": [json.loads((FIX / "evidence" / "osv.json").read_text())],
                                          "vendor_vex": [], "withheld": ["vendor_vex"]}))
            out = run("vendor-vex", "--finding", str(FIX / "finding.json"), "--evidence", str(bundle))
        self.assertTrue(any("withheld" in g for g in out["gaps"]))
        self.assertFalse(any("no source is configured" in g for g in out["gaps"]))
        self.assertEqual(out["sources"], [])

    def test_bundle_file_gives_the_same_answer_as_the_directory(self):
        import tempfile
        ev = FIX / "evidence"
        bundle = {"osv": [json.loads(f.read_text()) for f in sorted(ev.glob("osv*.json"))],
                  "vendor_vex": [{"source": "example", "document": json.loads((ev / "vex-example.json").read_text())}]}
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "cve-evidence.json"
            path.write_text(json.dumps(bundle))
            adv = run("advisory", "--finding", str(FIX / "finding.json"), "--evidence", str(path))
            vex = run("vendor-vex", "--finding", str(FIX / "finding.json"), "--evidence", str(path),
                      "--component", "python-jinja2")
        self.assertEqual(adv["fixed"], ["3.1.6"])
        self.assertEqual(adv["gaps"], [])
        self.assertEqual([s["source"] for s in vex["sources"]], ["example"])
        self.assertGreater(vex["sources"][0]["product_status"]["fixed"]["count"], 0)


class ResolveTest(unittest.TestCase):
    def test_vulnerable_pin(self):
        out = run("resolve", "--finding", str(FIX / "finding.json"), "--repo", str(FIX / "repo-vulnerable"))
        self.assertEqual(out["instances"][0]["spec"], "==3.1.5")

    def test_name_normalization_and_fixed_pin(self):
        out = run("resolve", "--finding", str(FIX / "finding.json"), "--repo", str(FIX / "repo-fixed"))
        self.assertEqual(out["instances"][0]["spec"], "==3.1.6")


class VendorVexTest(unittest.TestCase):
    def vex(self, *extra, evidence=None):
        return run("vendor-vex", "--finding", str(FIX / "finding.json"),
                   "--evidence", str(evidence or FIX / "evidence"), *extra)

    def test_backport_keeps_old_version_but_is_fixed(self):
        out = self.vex("--component", "python-jinja2")
        fixed = out["sources"][0]["product_status"]["fixed"]["examples"]
        # A distribution vendor ships the fix as a backport into its 2.x
        # build: a version comparison against 3.1.6 would wrongly call it
        # vulnerable.
        self.assertTrue(any("2.10.1" in pid for pid in fixed), fixed)

    def test_publisher_comes_from_the_document(self):
        out = self.vex()
        self.assertEqual(out["sources"][0]["publisher"], "Example Vendor Product Security")
        self.assertEqual(out["gaps"], [])

    def test_no_source_configured_is_a_gap(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "cve-evidence.json"
            bundle.write_text(json.dumps({"osv": [], "vendor_vex": [], "withheld": []}))
            out = self.vex(evidence=bundle)
        self.assertEqual(out["sources"], [])
        self.assertTrue(any("no source is configured" in g for g in out["gaps"]))

    def test_several_sources_and_a_source_with_no_document(self):
        import tempfile
        doc = json.loads((FIX / "evidence" / "vex-example.json").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "cve-evidence.json"
            bundle.write_text(json.dumps({"osv": [], "withheld": [], "vendor_vex": [
                {"source": "first", "document": doc}, {"source": "second", "document": None}]}))
            both = self.vex(evidence=bundle)
            one = self.vex("--source", "first", evidence=bundle)
            none = self.vex("--source", "third", evidence=bundle)
        self.assertEqual([s["source"] for s in both["sources"]], ["first", "second"])
        self.assertTrue(any(g.startswith("second: no document staged") for g in both["gaps"]))
        self.assertEqual([s["source"] for s in one["sources"]], ["first"])
        self.assertTrue(any("third" in g for g in none["gaps"]))

    def test_document_about_another_cve_is_a_gap(self):
        import tempfile
        doc = json.loads((FIX / "evidence" / "vex-example.json").read_text())
        doc["vulnerabilities"][0]["cve"] = "CVE-1999-0001"
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "cve-evidence.json"
            bundle.write_text(json.dumps({"osv": [], "withheld": [], "vendor_vex": [{"source": "x", "document": doc}]}))
            out = self.vex(evidence=bundle)
        self.assertTrue(any("no entry for CVE-2025-27516" in g for g in out["gaps"]))
        self.assertNotIn("product_status", out["sources"][0])


if __name__ == "__main__":
    unittest.main()
