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
| `/fs-code` comment on a work item labelled `fullsend-cve` | a person with write access | the code agent, behind the cve gate |

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

On GitLab an agent job assesses the project directory itself, which also holds
the run's `.fullsend` directory. The pre-script checks the mapped branch out
there, so every mapped branch must carry the same policy and mapping files as
the default branch.

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
  is checked against the mapping, instead of from github.com with `gh`.
- The code publisher is the stock `post-code.sh` from the same pinned scripts
  directory, instead of a hash-checked copy from the harness cache.
- The schema ships next to the module, and messages name `/fs-cve-triage`.

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
