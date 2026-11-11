# cve agent (DRAFT)

> Status: draft on a branch, not merged and not an accepted design. It
> exists to make a proposed CVE approach concrete enough to review and run.
> The ADR that states the decision is still being written and is not part
> of this branch. [The MVP test guide](cve-mvp-test.md) says how to prove
> the agent works.

## What it does

Given **one public vulnerability** and **one repository commit**, the cve agent
says whether that commit is affected. It answers in CSAF VEX terms (affected,
not affected with a justification, fixed, or under investigation) and, when the
commit is affected, writes a remediation plan. It never changes code. The
**existing code agent** implements the plan after a person adds
`ready-to-code` (or `CVE_AUTO_CODE=on` does). A vulnerability that touches
several maintained branches becomes one work item per branch; see
[Several branches](#several-branches).

```
work item (Jira tracker | Dependabot alert issue | hand-filed issue)
   │  label `cve` added, or /fs-cve from a person
   ▼
pre-cve (host)    guard R1–R3 → normalize (validated fields only) → fetch OSV + vendor VEX
   │  stages cve-finding.json + cve-evidence.json
   ▼
cve agent (sandbox, read-only)   cve-assessment skill + cve_evidence_* tools (pi) or the CLI (claude)
   │  writes agent-result.json (schema-validated)
   ▼
post-cve (host)   binding check → sticky verdict comment → cve:<status> label → [ready-to-code]
   ▼
code agent (existing) + cve-remediation skill → PR → review agent (existing)
```

## What the model sees, and what it does not

The agent is given three files and a read-only checkout:

- `cve-finding.json`: the vulnerability id, an optional package (ecosystem,
  name, range), and the target (repository, branch, commit). Every string is
  an id, an enum value, or matches a tight pattern.
- `cve-evidence.json`: public advisories the host fetched (the OSV record
  for the id and for each alias, and one CSAF VEX document from each vendor
  source the adopter listed; see [Vendor VEX sources](#vendor-vex-sources)).

- `cve-ticket.json`: the work item's own title, description and comments,
  as untrusted context, or `{"staged": false, "reason": …}` when the host
  withheld them.

The finding is the authority for the id, the package and the target. The
ticket is context: the prompt tells the agent to treat a claim in it as a
lead to verify, never as an instruction or as tool evidence, and not to
quote it.

### When the ticket's text is staged

| Target repository | Tracker | `CVE_TICKET_TEXT=auto` (default) |
|---|---|---|
| private or internal | any | staged |
| public | a public GitHub issue | staged (it is already public) |
| public | Jira, or a private GitHub repository | **not staged** |
| could not be determined | any | **not staged** |

Visibility comes from the GitHub API for a GitHub repository. For a GitLab
project it comes from the pipeline (`CI_PROJECT_VISIBILITY`), and only when
the pipeline runs in the project being assessed; a pipeline in any other
project cannot vouch for it, and the text is withheld.

`CVE_TICKET_TEXT=off` never stages it. `CVE_TICKET_TEXT=on` always does.

> **Warning.** Run this agent with ticket text on a **private** repository.
> `CVE_TICKET_TEXT=on` with a public repository and a private tracker is
> unsafe: what the agent restates from the ticket can appear in public issue
> comments, pull requests and run logs. A private repository that is later
> made public exposes the same things after the fact. Embargoed work items
> are skipped in every mode (R1, R2).

## Disclosure guard (pre-cve)

| Rule | Check | Result |
|---|---|---|
| R1 | The Jira issue has a security level, unless that exact level is listed in `CVE_JIRA_SECURITY_LEVELS` and the repository is private or internal | Run skipped |
| R2 | The work item has an embargo, confidential or private label | Run skipped |
| R3 | The id is not published in OSV | Run skipped |
| R4 | The tracker is not public and the repository is public, or visibility is unknown | Run continues without the ticket's text |

A skipped run stages nothing and reports its reason through the pre-script
output protocol. An OSV outage is a hard failure, not a skip: the guard cannot
tell "not public" from "could not check".

## Configuration

The agent adds no field to `.fullsend/config.yaml` and no repository
variable. It uses what Fullsend already has, and keeps its own settings in
its harness, as fullsend
[ADR 0080](https://github.com/fullsend-ai/fullsend/blob/main/docs/ADRs/0080-config-yaml-vs-agent-env-var-scope.md)
requires of single-agent settings.

| You want to | Where | Fleet-wide through `repos.yaml` |
|---|---|---|
| Install the agent | `agents:` entry in `config.yaml` (`fullsend agent add <url>`), covered by `allowed_remote_resources` | `defaults.config.agents` |
| Choose its runtime, model or effort | the same `agents:` entry | yes |
| Change what starts it | `trigger:` in a harness that composes `cve.yaml` with `base:`. The Jira poller reads only a harness trigger, not one on the `agents:` entry. By default a person starts it with a `/fs-cve` comment or by adding the `cve` label. Trackers a product security team files carry no `cve` label, so an adopter either comments `/fs-cve` or sets a trigger on a label those trackers do carry | register that harness in `defaults.config.agents` |
| Point it at Jira | `tracker.jira.base_url`, `project`, and `poll.query` for which trackers are polled | yes |
| Stop it | `kill_switch` | yes |
| Change `CVE_TICKET_TEXT`, `CVE_JIRA_SECURITY_LEVELS`, `CVE_BRANCHES`, `CVE_BRANCHES_FOLLOW`, `CVE_COMPONENT_LABEL_PREFIX`, `CVE_VEX_SOURCES`, `CVE_VENDOR_VEX`, `CVE_AUTO_CODE` | a harness that composes `cve.yaml` with `base:` and restates the key under `env.runner` | register that harness in `defaults.config.agents` |

A harness value wins over the runner's environment, so these are not set
from a CI workflow or a repository variable
([ADR 0081](https://github.com/fullsend-ai/fullsend/blob/main/docs/ADRs/0081-reserve-workflow-env-for-infra-plumbing.md)).

Two of the five settings are in the harness only because nothing better
exists yet. By ADR 0080's own test, a setting that means the same thing to
several agents belongs in `config.yaml`:

- **Maintained branches** (`CVE_BRANCHES`, `CVE_BRANCHES_FOLLOW`) also
  bound where the code agent may open pull requests
  (`CODE_ALLOWED_TARGET_BRANCHES`).
- **Whether a private tracker's text may be used for a public repository**
  (`CVE_TICKET_TEXT`) applies equally to triage and code
  ([fullsend#2513](https://github.com/fullsend-ai/fullsend/issues/2513)).

Both should move to `config.yaml` by a deliberate migration when core gains
the field, not by adding a second way to set them now.

## Routing: triage and code

Two changes to shared harnesses keep a vulnerability on this path:

| Harness | Change | Effect |
|---|---|---|
| `harness/triage.yaml` | trigger excludes work items labelled `cve` | Triage never reads a vulnerability tracker's text, and never promotes one to `ready-to-code` |
| `harness/code.yaml` | trigger requires `cve:affected` when the item carries `cve` or any `cve:<status>` verdict label (real trackers carry no `cve` label, so the verdict label is what marks one as assessed); an overlay adds the host checks in [Handoff to the code agent](#handoff-to-the-code-agent) | The code agent cannot start on a vulnerability without a current affected verdict, and cannot change files outside its plan |

An adopter whose trackers carry a different label restates both triggers in
a composed harness. [`docs/examples/cve-jira-tracker`](examples/cve-jira-tracker/)
holds three such harnesses, with placeholder names.

Proposed and not built: for an issue filed by hand with no label, triage
hands off by adding `cve` when its category is `security` and the issue names
exactly one CVE or GHSA id.

## Several branches

Off by default. Set `CVE_BRANCHES` in the runner environment to the
maintained branches (exact names, comma-separated) to turn it on.

```
parent issue (label `cve`, names no branch)
   │  pre-cve: R1–R3 pass → create one child per branch → skip the run
   ├─ child "CVE-…: main"         → cve run on main        → cve:fixed
   ├─ child "CVE-…: release-1.8"  → cve run on release-1.8 → cve:affected → code agent → PR to release-1.8
   └─ (release-1.9 is in CVE_BRANCHES_FOLLOW: no child)
   ▲
   └─ post-cve of every child rebuilds one sticky table on the parent
```

| Work item | `CVE_BRANCHES` | What pre-cve does |
|---|---|---|
| names no branch | unset | Assesses the checked-out branch (the single-branch case) |
| names no branch, GitHub | set | Parent: creates the children, skips the run |
| names no branch, Jira | set | Skips: it will not guess which stream a tracker is for |
| names a branch in the list | set | Checks that branch out, then assesses it |
| names a branch in `CVE_BRANCHES_FOLLOW` | set | Skips: the fix arrives through the sync |
| names any other branch, or any branch | set / unset | Skips with the reason |

A GitHub work item names its branch as `"target": {"ref": "release-1.8"}` in
its `cve-finding` block; a Jira tracker as `release_branch` in its
`cve-intake` property. The name is a request. The list is the adopter's, the
commit is resolved on the host, and the child issues are written by host code
from validated fields, so the model never chooses a branch.

Fan-out happens after the disclosure checks, so no child is ever created for
an id that is not public. `POST_CVE_DRY_RUN=1` prints what it would do
instead of doing it.

Fan-out keeps no record of its own. Each run reads the issues and finishes
whatever is missing, so a run that died part-way is completed by the next
one, and a branch added to the list later is picked up:

| What the run finds for a branch | What it does |
|---|---|
| a linked child with the expected title | nothing |
| an issue that was created but never linked | links it and adds `cve` |
| a linked child that never got the `cve` label | adds the label |
| nothing | creates the issue, links it, adds `cve` |

A new child carries a `cve-branch` label from the create call itself, which
is how an unlinked one is found again with a list call (search results lag
and are not used). An unlinked issue is adopted, and a missing label
repaired, only when a bot wrote the issue.

What this does not do: nothing re-runs a parent by itself. A fan-out that
died is completed the next time the parent is triggered, by a person or by
scheduled rediscovery of work items
([ADR 0098](https://fullsend.sh/docs/ADRs/0098-entity-first-harness-evaluation),
accepted, not yet enabled in Fullsend). A child whose run never started
shows as `pending` in the parent's table and stays there until someone
re-triggers it.

Core is converging on the same shape. The draft for
[fullsend#9260](https://github.com/fullsend-ai/fullsend/issues/9260) now
chooses tracker-first dispatch: one tracker per target, created before the
verdict is known, then an ordinary single-target run, with no multi-target
interface in the runner. Its first adapter creates Jira trackers. The child
issues here are the GitHub form of that; a Jira form needs the mapping from
product stream to repository and branch, which is not built.

### What starts a branch issue's run

On GitHub the child's run starts because a label was added. Fullsend treats
a label accepted by GitHub as its own authorization grant, including when a
bot added it ([ADR 0107](https://fullsend.sh/docs/ADRs/0107-bot-identity-resolution-for-dispatch-authorization),
rule 2). That grant exists on GitHub only.

On Jira there is no such grant, and three things follow from how the Jira
poller works:

| How the `cve` label gets onto a tracker | What the poller emits | Does a run start? |
|---|---|---|
| Set when the tracker is created | One `opened` event, with the reporter as the actor and the labels in `state.labels` | Only if the reporter is authorized and is not classified as a bot |
| Added later by a person | `label_changed` | Yes, if that person is authorized |
| Added by the account the poller uses, or by an account Jira marks as an app, or one whose display name ends in "bot" or "automation" | Dropped | No |

So a tracker that this agent's own scripts created on Jira would sit idle,
and so might a tracker filed by a security team's automation account. A
fan-out to Jira trackers is not built for that reason. It needs an
authorized way for automation to start a run, which Fullsend does not have
for Jira today.

For the fix, the adopter must also list the release branches in
`CODE_ALLOWED_TARGET_BRANCHES`; by default the code agent may target only the
default branch.

## Vendor VEX sources

Some vendors publish, for each CVE, a CSAF VEX document that states which of
their products and components are affected, fixed or not affected. For a
repository that builds on such a vendor's packages or images, that document
is strong evidence: it records backported fixes that a version comparison
would miss.

The agent reads the CSAF VEX format and knows no particular vendor. An
adopter lists its sources in the harness:

```yaml
env:
  runner:
    CVE_VEX_SOURCES: "acme=https://security.example.com/csaf/vex/{year}/{id}.json"
```

| Part | Meaning |
|---|---|
| `acme` | A name for the source: lower-case letters, digits and hyphens. The model sees it beside the publisher named inside the document |
| `{id}` | The CVE id in lower case (`cve-2025-27516`) |
| `{ID}` | The CVE id as written (`CVE-2025-27516`) |
| `{year}` | The year in the id (`2025`) |

Several entries are separated by spaces or commas, up to five. The default
is `none`: no vendor VEX is fetched, and the evidence says that no source is
configured. A URL must be `https` with no query string, fragment or
credentials, and may use no other placeholder. A malformed list stops the
run before any request.

pre-cve fetches each document on the host and stages it for the sandbox,
which has no route to the vendor. A source that has no document for the id,
or returns something that is not CSAF, is staged as a gap, not as "not
affected".

**For an organization.** Put the setting in one harness that composes
`cve.yaml`, and register that harness once in `defaults.config.agents` of
the organization's `repos.yaml`. Every repository then gets the same
sources, and the organization's own details (a feed URL, a Jira security
level name) stay in its own configuration and out of this repository.

What this does not cover: a vendor that files VEX by advisory id, not by CVE
id, has no URL a template can form. That needs a lookup step, which is not
built. Documents are fetched without credentials, so a feed behind a login
is not reachable either.

## Evaluation mode

`CVE_VENDOR_VEX=off` makes pre-cve leave every vendor VEX document out and
record `"withheld": ["vendor_vex"]` in the evidence file. Use it when scoring the
agent on closed tickets: for those, the vendor file states the answer. The
evidence tool then reports "withheld", which the agent must not read as "the
vendor has no statement".

## Files

| File | Purpose |
|---|---|
| `harness/cve.yaml` | `role: triage`, `readonly_repo`, trigger on the `cve` label or `/fs-cve` |
| `agents/cve.md` | Prompt. No `tools:` line, so pi extension tools stay visible |
| `schemas/cve-finding.schema.json` | Normalized input, the same for every source |
| `schemas/cve-result.schema.json` | VEX-aligned output |
| `scripts/pre-cve.src.sh` | Guard, normalize, fetch and stage advisories |
| `scripts/lib/cve-normalize.lib.sh` | The normalizer (Python in a heredoc, so it is bundled into `pre-cve.sh`) |
| `scripts/lib/cve-fanout.lib.sh` | Branch list, child-issue creation, the parent's table |
| `scripts/lib/cve-git.lib.sh` | Fetching a release branch, or its history, into the runner's one-commit checkout, with the run's read token when the remote asks for one |
| `scripts/lib/cve-vex.lib.sh` | The vendor VEX source list: parse, check, and form each document's URL |
| `scripts/lib/cve-receipt.lib.sh` | The verdict receipt: build, validate, write and read (GitHub comment, Jira property) |
| `scripts/pre-code-cve.src.sh`, `scripts/post-code-cve.src.sh` | Host checks around the code agent for `cve` work items |
| `scripts/cve-code-gate-test.sh` | Offline tests for those two scripts |
| `scripts/post-cve.src.sh` | Binding check, sticky comment, labels. `POST_CVE_DRY_RUN=1` prints instead of writing |
| `scripts/cve/cve-evidence.py` | Deterministic evidence CLI (`advisory`, `vendor-vex`, `resolve`); copied into the sandbox by `host_files` |
| `plugins/cve-evidence/` | Thin pi extension that exposes the CLI as three tools |
| `skills/cve-assessment/` | Decision procedure and VEX vocabulary |
| `skills/cve-remediation/` | Narrows the existing code agent for `cve` work items |
| `docs/examples/cve-dependabot-bridge.yml` | Adopter workflow: Dependabot alerts become issues with the `cve` label |
| `harness/triggertest/cve_trigger_test.go` | Trigger cases |
| `scripts/pre-cve-test.sh`, `scripts/cve/test_cve_evidence.py` | Offline tests |

`config.yaml` has one added line registering `harness/cve.yaml`, because
`fullsend run` refuses an agent that is not registered.

## Handoff to the code agent

A label says a verdict existed once. The code agent's host scripts check the
verdict itself, before and after coding. This is the control the
`cve-workflow-experiment` controller has, rebuilt on the built-in code agent.

When post-cve publishes a verdict it also records a **receipt**: the id,
repository, branch, commit, status, plan state, chosen option and the plan's
file list. On GitHub the receipt rides in the sticky comment as a hidden
marker, and only a bot-authored comment is accepted. On Jira it is the issue
property `fullsend.cve.receipt`.

An overlay at the end of `harness/code.yaml`, active when the work item has
the `cve` label, adds the `cve-remediation` skill and swaps in two scripts.
Each hands over to the ordinary pre- or post-script when it passes.

| Script | When | Refuses when |
|---|---|---|
| `pre-code-cve.sh` | Before the sandbox | No valid receipt; it is for another repository; the latest verdict is not `known_affected`; the plan is not ready, is a rebuild, or names no files; the assessed commit or branch is gone; the branch was rewritten; or, since the assessment, a file in the plan or any dependency manifest or lockfile changed |
| `post-code-cve.sh` | Before the push | The change targets a branch other than the assessed one, or touches a file the plan did not name. A plan entry ending in `/` covers that directory |

A branch that moved without touching the plan's files or a manifest is still
admitted, so a busy branch does not force a reassessment for every commit.

The receipt carries the trust of whoever can edit the bot's comment or the
issue property, which is the trust `ready-to-code` already carries. It is
used only to stop a run or to narrow it.

Because the file list is enforced, the assessment must list every file the
fix will touch, including lockfiles and the regression test. A fix that needs
another file stops, and the plan is reassessed.

## Checked

Run on 11 Nov 2026 against agents `3b40ac7` with fullsend `v0.55.0`. The
hosted run is in [Testing the cve agent MVP](cve-mvp-test.md#hosted-run-gitlab-and-jira).

| Check | Result |
|---|---|
| `bash scripts/pre-cve-test.sh` (guard, normalizer, staging, ticket-text rule, binding, branches, fan-out and its repair, parent table, withheld VEX, GitLab visibility, a one-commit checkout, the Jira security-level list, a detached checkout, the Jira API gateway, restoring the checkout, the vendor VEX source list, the component label prefix; bundled scripts, stubbed `gh`/`curl`) | 103 passed |
| `bash scripts/cve-code-gate-test.sh` (receipt, plan, staleness, Jira property, branch and file scope, a one-commit checkout, the token retry; bundled scripts beside stub successors, real git repository) | 32 passed |
| `python3 -I -m unittest discover -s scripts/cve -p 'test_*.py'` (real OSV and GHSA records, a synthetic CSAF VEX document) | 11 passed |
| `go test ./...` in `harness/triggertest` (whole suite, including the `cve` trigger, the triage exclusion and the code gate) | passed (18 new cases) |
| `fullsend lint cve --fullsend-dir . --forge github` | resolves; one warning, the same one `triage` has |
| `skillsaw --strict` (0.18.0) | passed |
| `shellcheck` on the cve scripts | no errors or warnings (info notes only) |
| `fullsend run cve --runtime dummy` | harness loads, pi plugin recognized; stopped at the OpenShell gateway, which was not running |

## Not checked

Items the [hosted run](cve-mvp-test.md#hosted-run-gitlab-and-jira) settled
have been removed from this list. It covered a Jira tracker for a private
GitLab project, on the `claude` and `pi` runtimes, and nothing else.

1. **The fix agent and the plan.** The host check that keeps a change
   inside the assessed plan is on the code harness. The fix agent, which
   acts on review findings, has no such check: in the hosted run it added a
   file the plan did not name. `harness/fix.yaml` needs the same overlay, or
   the check has to move to where every push to that branch passes.
2. The Dependabot alerts token for the bridge workflow. `GITHUB_TOKEN` has no
   Dependabot-alerts permission key, so the example uses a GitHub App token.
3. Jira tracker conventions (which label carries the CVE id, which names
   the component) with the team that files the trackers.
   The hosted run used trackers written by hand in that shape.
4. Bridge ecosystem mapping beyond `pip` → `pypi` (for example `rust` → `cargo`).
5. `resolve` covers npm, PyPI and Go. Other ecosystems report a gap. RPM
   content and container image layers are not read at all.
6. GitLab issues as the tracker. `pre-cve` skips them with a reason.
7. Several branches, against a real forge. The offline tests use a stubbed
   `gh`. Unconfirmed: that the pre-script's token may create issues; that the
   sub-issue endpoints behave as stubbed (`sub_issues`, `parent`); that a
   label added by that token starts the child's run; that an issue may be
   created with a label that does not exist yet (`cve-branch`); and that the
   token retry in `cve-git.lib.sh` is accepted by a real private GitHub
   remote. Fetching a release branch's whole history for the code gate has
   not been timed on a large repository.
8. Closing a child issue when its pull request merges into a release
   branch. GitHub's closing keywords work only on the default branch.
9. That the sandbox cannot fetch the withheld vendor file by itself. The
   design relies on the sandbox having no egress to advisory hosts.
10. A public repository with a private tracker, on a hosted runner. The
    ticket-text rule reads `CI_PROJECT_VISIBILITY` and is tested with stubs;
    the hosted project was private, where the text is staged.
11. Jira Cloud's newer API returns rich-text objects, not strings, for a
    description. The pre-script uses the older API version and falls back
    to raw JSON.
12. A GitHub repository, hosted. `scripts/harness-jira-test.sh` was not run
    here (it needs `yq`).
13. For a Jira-first adopter: a product security team's trackers carry no
    `cve-intake` property, so nothing maps a tracker's component and stream
    to a repository and a branch yet. The hosted trackers carried the
    property, written by hand.
14. A trigger can read labels and nothing else about a work item, and a
    child harness replaces a trigger whole. An adopter whose trackers carry
    their own label therefore restates the triage and code triggers
    ([example](examples/cve-jira-tracker/)), and has to re-read them when the
    stock triggers change. A label name the harness could be given would
    remove both copies.
15. Whether a tracker filed by an automation account starts a run on Jira.
    The poller drops events from its own account, from accounts Jira marks
    as an app, and from accounts whose display name ends in "bot" or
    "automation". If the trackers are filed by such an
    account, a person has to start each run.
16. The effect of Fullsend's actor-attributed data boundary
    ([ADR 0133](https://fullsend.sh/docs/ADRs/0133-actor-attributed-data-security-boundary),
    target state) on a child issue. A child is written entirely by a bot.
    The pre-script reads it on the host and the model sees only the
    validated finding, but if Fullsend comes to deny a run whose work item
    has no record from an authorized actor, a child's run would be denied.
17. A model provider's safeguard refusing the session. It happened once in
    the hosted run and the validation loop's second iteration succeeded. A
    second refusal would end the run with no verdict, and nothing tells the
    tracker why.
18. Moving the runner's checkout to the assessed branch. post-cve restores
    it, but between the two scripts the run's own `.fullsend` directory is
    the release branch's. A branch carried in the dispatch record, or a
    separate working tree for the sandbox, would remove the need.
19. More than one vendor VEX source, and any source but one, against real
    documents. The tests use a synthetic CSAF VEX document, and the hosted
    run configured a single source. Vendors differ in how they name products
    and in document size, and a vendor that files by advisory id cannot be
    reached by a URL template at all.
