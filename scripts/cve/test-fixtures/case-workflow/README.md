# Fixtures for the cve case extension glue

Everything here is made up: the package `tinytemplate-demo`, the ids
`CVE-2099-0001` and `GHSA-2c3f-4g5h-6j7m`, and the repository
`example/app`. Nothing is copied from a real advisory or package.

| Path | What it is |
|---|---|
| `repo/` | A small npm project that calls the vulnerable function. The test turns it into a git checkout with fixed dates, so its commit id is always the same |
| `package/` | The dependency "as published". The test packs it into a tarball |
| `advisory.json` | An advisory record in the shape of GitHub's global advisory API |
| `osv.json` | The same vulnerability as an OSV record, for pre-cve's publication check |
| `case-affected/`, `case-not-affected/` | Case records written by the extension itself for those inputs, with a fixed script in place of the model (`scripts/cve/cve-case-driver.mjs`) |
| `case-binding.json` | What staging recorded for those inputs. The test checks that staging still produces exactly this |

To record the case folders again after changing the fixtures or the extension
pin, see "Checking a new pin" in `docs/cve-workflow.md`.
