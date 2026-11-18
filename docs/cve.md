# CVE Agent

DRAFT. The cve agent assesses one public CVE, named by a Jira work item, against
the maintained branch that the work item's intake maps to. It records a verdict
and a remediation plan on the work item and never changes code.

## Setup

Register `harness/cve.yaml` in the repository's agents, keep the code and triage
agents from the same commit of this repository, and add the two policy files
described under [Configuration](#configuration). On GitLab the agent name `cve`
needs a registered role; it only comments and sets issue properties, so it can
reuse the analyst credential:

```json
{"roles": [{"name": "cve", "credential": "reuse", "reuse": "analyst",
  "capabilities": ["read_issues", "write_issues", "write_notes", "write_labels"],
  "agents": ["cve"]}]}
```

passed as `fullsend repos install <group/project> --gitlab-role-registry <file>`.

## How it helps

A vulnerability tracker gets a verdict on one exact branch and revision, with
evidence, before anyone writes code. When the branch is affected, the plan
compares five remediation types (`dependency_update`, `patched_fork`,
`patch_backport`, `source_fix` and `rebuild`) and recommends one. A person
adopts the recommendation with `/fs-code`, and the code agent then implements
only that plan, on that branch, in the planned files.

## Triggers

| Event | Who | Starts |
|---|---|---|
| `/fs-cve-triage` comment on a Jira Task, Bug or Vulnerability | a person with write access | the cve agent |
| `fullsend-cve` label added to a Jira Task, Bug or Vulnerability | anyone who may edit the work item | the cve agent |
| A Jira Task, Bug or Vulnerability opened with the `fullsend-cve` label | an automation account, or a person with write access | the cve agent |
| `/fs-code` comment on a work item labelled `fullsend-cve` | a person with write access | the code agent, behind the cve gate |

The last row is how a work item from the alert steps below starts its own
assessment: those steps open it with the label already set. The trigger does
not tell one automation account from another, so any of them that can open a
labelled work item can start a run. The run is read-only, and the host gate
still refuses a work item without a valid intake record.

Write access comes from the installation's `authorization` setting. The issue
types are names on the Jira site, so an adopter whose site names them
differently restates the trigger in a harness that composes `harness/cve.yaml`.

## Commands

| Command | Effect |
|---|---|
| `/fs-cve-triage` | Assess the work item again. The new run first marks the previous result as superseded. |
| `/fs-code` | Implement the recommended option of a current affected verdict with a ready plan. Anything else is refused with a comment saying why. |

## Control labels

| Label | Meaning |
|---|---|
| `fullsend-cve` | The work item belongs to this agent. Triage does not run on it, and `ready-to-code` does not start the code agent on it. |
| `cve-public` | Required with `fullsend-cve` by the default policy; the CVE is public. |
| `embargoed`, `security-embargo`, `confidential` | Blocked: the run stops before any model sees the work item. |

The required and blocked labels are set in the adopter's policy.

## Configuration

Two files in the repository's `.fullsend` directory, reviewed like any other
configuration.

`.fullsend/cve-policy.json`:

```json
{
  "repository": "example-org/example-service",
  "project": "PROJ",
  "jira": {"base_url": "https://example.atlassian.net", "account_email": "fullsend-bot@example.com"},
  "forge_url": "https://gitlab.example.com",
  "owners": ["example-team"],
  "fix_category": "dependency-update",
  "remediation": {
    "preference_order": [["dependency_update", "rebuild"], ["patch_backport", "patched_fork", "source_fix"]],
    "coding_types": ["dependency_update"],
    "change_paths": ["requirements.txt", "tests/test_app.py"]
  },
  "required_labels": ["fullsend-cve", "cve-public"],
  "blocked_labels": ["embargoed", "security-embargo", "confidential"],
  "assessment_profile": "jinja_template_preview",
  "prepare_checkout": true,
  "release_mappings_file": "release-mappings.yaml"
}
```

`forge_url` is needed only when the repository is not on GitHub. With
`prepare_checkout`, the pre-scripts fetch the mapped branch and check it out.
`.fullsend/release-mappings.yaml` maps a product and version to one repository,
branch and component:

```yaml
version: 2
products:
  example-service:
    repository: example-org/example-service
    versions:
      "1.8":
        branch: release-1.8
        component: app.py
        manifest: requirements.txt
        manifest_format: requirements
        manifest_identity: Jinja2
        owner: example-team
```

The work item needs the policy's required labels, no Jira security level, an
assignee and a `fullsend.cve.intake` issue property:

```json
{"cve": "CVE-2025-27516", "disclosure": "public",
 "advisory_url": "https://github.com/advisories/GHSA-cpwx-vrp4-4pq7",
 "repository": "example-org/example-service", "owner": "example-team",
 "fix_category": "dependency-update", "product": "example-service",
 "release": "1.8", "stream": "1.8", "component": "app.py"}
```

Known limit: a Jira site that puts a security level on every vulnerability
tracker, public CVEs included, has all of them refused. The gate does not yet
let a policy name the levels it accepts.

On GitLab an agent job assesses the project directory itself, which also holds
the run's `.fullsend` directory, read from the default branch. The pre-script
checks a mapped branch out there only when that branch carries exactly the same
`.fullsend` tree as the commit the job runs on, so a branch can never change the
run's settings. Keep each mapped branch's `.fullsend` directory identical to the
default branch's, or the run stops before the checkout.

### Source on GitHub while the job runs on GitLab

DRAFT, stopgap. A policy `source` block lets a GitLab installation work on a
GitHub repository:

```json
{
  "repository": "example-org/example-service",
  "source": {"forge": "github", "host_project": "group/runner-project"}
}
```

`repository` is then a github.com repository and `host_project` is the GitLab
project the agents run in. The pre-scripts fetch the mapped branch from GitHub
into the job's checkout and point its origin there. The run's own `.fullsend`,
`.gitlab` and `.gitlab-ci.yml` are restored from the job's commit as ignored
files, and a source branch that carries any of those paths is refused. The code
agent's change is published by the stock publisher as a pull request on the
GitHub repository, with signed commits.

The GitHub identity is a GitHub App installed on that repository only. Three
protected CI/CD variables on the GitLab project supply it:
`CVE_PUBLISHER_GITHUB_APP_ID`, `CVE_PUBLISHER_GITHUB_INSTALLATION_ID` and
`CVE_PUBLISHER_GITHUB_APP_KEY_B64` (the private key, base64 on one line, masked
and hidden). Each use mints a token limited to that repository, valid for an
hour. This is a stand-in until the token mint can serve a GitLab caller
([fullsend#402](https://github.com/fullsend-ai/fullsend/issues/402)): a
long-lived key in a CI/CD variable is readable by every host-side script in the
job.

Known limits: a branch that carries a `.fullsend` directory cannot be a source,
the pull request comes from a branch in the repository and not from a fork, and
review and fix run on the pull request only if Fullsend is also installed on
the GitHub repository.

### Work items from Dependabot alerts

DRAFT. `scripts/cve/cve_alerts.py` opens the work items the cve agent starts
from, so that nobody has to write the intake record by hand. It runs on the
host in steps and calls no model:

```sh
python3 scripts/cve/cve_alerts.py collect --candidates candidates.json
python3 scripts/cve/cve_alerts.py investigate --candidates candidates.json \
  --workdir evidence --tool "<evidence tool command>"   # optional
python3 scripts/cve/cve_alerts.py publish --candidates candidates.json
```

`collect` reads the open Dependabot alerts of the policy's `repository`. For
each alert it takes every version in the release mapping whose `manifest` is
the alert's manifest, reads that manifest at the head of the mapped branch and
compares the required version with the advisory's vulnerable range. An alert
is checked on each maintained branch, not only on the default branch that
Dependabot reports on.

`collect --alert N` looks only at alert number N and leaves every other alert
alone; give it more than once for several alerts. Use it to bring the step up
one alert at a time.

| Result for an alert and a version | What happens |
|---|---|
| The required version is in the vulnerable range | A candidate |
| The version cannot be compared, for example behind a `replace` to a local directory | A candidate, marked undetermined |
| The version is outside the range, or the package is not required on that branch | Skipped, with the reason |
| The manifest is not in the release mapping, or the advisory has no CVE identifier | Skipped, with the reason |
| The public advisory database does not serve the advisory under that CVE | Skipped: the finding is not shown to be public |
| An ecosystem with no reader | Skipped, with the reason |

The only built-in reader today is for Go modules (`manifest_format:
go-module`). It reads `go.mod` and reports what the file requires. It does not
say whether the vulnerable code is reachable; that is the cve agent's
assessment.

`publish` creates one Jira work item per vulnerability and maintained version.
Each gets the policy's required labels, the `fullsend.cve.intake` record (set
in the same request as the work item) and a description made only of public
facts and what the host read. A candidate that already has a work item is
skipped, and one run creates at most `max_new_work_items`. The cve agent
starts on each new work item when the Jira poller next sees it (see Triggers),
so `max_new_work_items` is also the number of assessments a run can start.

The candidates file between the steps is the place for an evidence tool.
`publish` builds every work item from the policy again, so an entry that names
a repository, version or branch the policy does not map is refused.

`investigate` asks an evidence tool about each candidate. The tool is a
command the operator chose, for example a wrapper around a runtime extension's
evidence collection. It is run once per candidate as `TOOL REQUEST RESULT`. The
request file holds the candidate's public facts:

```json
{
  "schema_version": 1,
  "repository": "example-org/service",
  "branch": "release-1.4",
  "commit": "<40 hex>",
  "manifest": "go.mod",
  "ecosystem": "go",
  "package": "example.com/web/v5",
  "module": "example.com/web/v5",
  "cve": "CVE-2026-10001",
  "ghsa": "GHSA-xxxx-xxxx-xxxx",
  "alert_number": 7,
  "vulnerable_range": "< 5.2.2",
  "first_patched_version": "5.2.2"
}
```

The tool gets the source itself; `investigate` passes no checkout and no
credential. It writes its answer to the result path:

```json
{
  "schema_version": 1,
  "tool": "example-evidence 1.0",
  "outcome": "in_vulnerable_range",
  "coverage": "partial",
  "gaps": ["Requesters of indirect modules are not recorded"],
  "observed": {"module": "example.com/web/v5", "version": "v5.2.1", "direct": true},
  "evidence_sha256": "<64 hex>"
}
```

| Field | Values |
|---|---|
| `outcome` | `in_vulnerable_range`, `outside_vulnerable_range`, `not_found`, `undetermined` |
| `coverage` | `complete`, `partial`, `unknown` |
| `gaps` | What the evidence does not show, as short sentences |
| `evidence_sha256` | The digest of the tool's own evidence record, if it keeps one |

`publish` keeps only these fields, each bounded, and writes them into the work
item. It leaves a candidate out only when the tool reports complete evidence
that the version in use is outside the vulnerable range. A tool that did not
find the package, reports gaps, fails or answers in another shape clears
nothing: that candidate is published as it would be without the tool.

Optional settings, in the policy:

```json
{
  "alerts": {
    "issue_type": "Task",
    "labels": ["team-queue"],
    "assignee_account_id": "<Jira account id>",
    "max_new_work_items": 5
  }
}
```

`labels` are added to every work item, for example the label the Jira poller's
query selects. The cve gate refuses a work item without an assignee, so set
`assignee_account_id` or assign each one by hand.

`collect` needs a GitHub token that can read the repository's Dependabot
alerts and contents. It uses `CVE_ALERTS_GITHUB_TOKEN` when that is set.
Otherwise it mints a read-only token from the GitHub App described above,
which then needs the "Dependabot alerts: read" permission. `publish` uses the
same Jira variables as the agent's scripts.

Known limits: nothing in Fullsend starts these steps, so an adopter runs them
from its own job. Alerts in other ecosystems are skipped until a reader or an
evidence tool covers them. Dependabot alerts exist only on GitHub. Jira's
search can lag behind a work item that was just created, so two `publish` runs
seconds apart can open the same work item twice.

### Variables

| Variable | Set in | Meaning |
|---|---|---|
| `CVE_POLICY_FILE` | `harness/cve.yaml`, cve overlay in `harness/code.yaml` | The adopter's policy, `${FULLSEND_DIR}/cve-policy.json` |
| `CVE_ISSUE_URL` | same | The Jira work item, from `FULLSEND_WORK_ITEM_URL` |
| `CVE_CODE_COMMAND_AUTHORIZATION` | cve overlay in `harness/code.yaml` | `recommended-plan`: `/fs-code` adopts only the recommended option |
| `CVE_SCHEMA_FILE` | optional | Overrides the schema shipped in `scripts/cve/` |

## How the agent works

```
pre-cve-assess (host)   disclosure and intake gates → release mapping picks one
   │                    repository and branch → checkout verified → context staged;
   │                    fullsend.cve.assessment is set to "assessing"
   ▼
cve agent (sandbox)     cve prompt + cve-security skill, read-only checkout,
   │                    writes agent-result.json, checked against the schema
   ▼
post-cve-assess (host)  result stored as fullsend.cve.assessment, work item
   │                    rechecked, verdict and plan posted as a comment
   │  a person comments /fs-code
   ▼
code agent              pre-cve-code: current affected verdict, ready plan, same
                        target and revision, mapped branch checked out;
                        post-cve-code: plan paths only, assessed branch only,
                        then the stock publisher
```

No free text from the work item reaches the host gates. The agent reads the
staged context and may read the work item through the read-only Jira provider.
Running an assessment again is another `/fs-cve-triage` comment. A new run
first marks the previous result as superseded, so an old affected verdict can't
be coded after a failed reassessment.

This is the CVE workflow from
[fullsend-playground/cve-workflow-experiment](https://github.com/fullsend-playground/cve-workflow-experiment)
at `42b1a2e`, by Ella Shulman: its cve-security skill, host gates
(`scripts/cve/`) and sandbox policy, with the prompt and schema of the later
Jira triage agent built on it. Changes to `scripts/cve/cve_workflow.py`:

- The Jira site and service account come from the policy (`jira.base_url`,
  `jira.account_email`) instead of constants.
- A checkout origin may be GitHub or the forge named by `forge_url`. A CI job
  token in the origin URL is skipped, never kept.
- The mapped branch is fetched from the checkout's own origin, after the origin
  is checked against the mapping, instead of from github.com with `gh`. The
  fetch forces the update, so a runner that keeps its checkout between jobs
  follows a branch that has moved. When the
  run's `.fullsend` directory sits inside the checkout, a branch whose
  `.fullsend` tree differs is refused before the checkout.
- The code publisher is the stock `post-code.sh` from the same pinned scripts
  directory, instead of a hash-checked copy from the harness cache.
- The schema ships next to the module, and messages name `/fs-cve-triage`.
- The cve-security skill tells the coder to set `closes_issue: false`, as the
  later cve-code prompt does. The publication check requires it.

Not included from the later version of the workflow: a recovery journal and
operator-launched jobs, approval checks beyond Fullsend's `authorization` (a
Jira role checked by id and direct membership, refusing an edited command, a
command age limit), the coder's fresh-context review extension, and a
validation-only coding mode.

## Source

[`harness/cve.yaml`](https://github.com/fullsend-ai/agents/blob/main/harness/cve.yaml),
[`agents/cve.md`](https://github.com/fullsend-ai/agents/blob/main/agents/cve.md),
[`skills/cve-security`](https://github.com/fullsend-ai/agents/tree/main/skills/cve-security),
[`scripts/cve`](https://github.com/fullsend-ai/agents/tree/main/scripts/cve)
