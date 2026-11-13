# Retro Agent

![Retro agent icon](icons/retro.png)

Performs retrospectives on agent workflows — analyzes what happened, identifies improvement opportunities, and proposes changes as issues.

## Setup

No additional setup is required beyond the standard fullsend configuration.

## How it helps

- Every workflow gets a post-mortem, not just the ones that failed badly enough for someone to notice.
- Improvement proposals are filed as issues with context, so they enter the normal triage/prioritize pipeline.
- Patterns across multiple retros surface systemic issues (e.g., a skill that consistently underperforms).

## Triggers

The retro agent runs automatically when a PR is closed (merged or not), including after a merge. On GitLab, the equivalent merge-request close event triggers it as well. The Jira integration below changes where the retro's proposals are filed; it does not change the trigger. For example, with `FULLSEND_TRACKER=jira`, closing a PR or MR starts the retrospective and its validated proposals are filed in the configured Jira project.

It can also be triggered manually with the `/fs-retro` command.

The harness also declares a CEL `trigger:` for fullsend's harness dispatch that selects the same events on GitHub: a PR closed (merged or not), or a `/fs-retro` comment from a human on an issue or PR. Dispatch does not evaluate it for the built-in retro agent yet, so the routing above is what runs today.

## Commands

| Command | Where | Effect |
|---------|-------|--------|
| `/fs-retro` | PR or issue comment | Triggers a retrospective analysis |

Requires write-level repository permission (admin, maintain, or write).

The `/fs-retro` command accepts optional free-text instructions after the
command. The text is passed to the agent as high-signal direction about what
to focus on:

- `/fs-retro` — general retrospective on the workflow
- `/fs-retro figure out why the review agent approved this and make sure it never happens again`
- `/fs-retro the code agent spent 30 minutes on a 2-line fix, what went wrong`

## Control labels

| Label | Meaning |
|-------|---------|
| `ready-for-triage` | Applied to proposal issues so they enter the [triage](triage.md) pipeline automatically. |

## Configuration

See [Customizing with AGENTS.md](https://fullsend.sh/docs/guides/user/customizing-with-agents-md) and
[Customizing with Skills](https://fullsend.sh/docs/guides/user/customizing-with-skills).

### Variables

| Variable | Description | Default | Valid values |
|----------|-------------|---------|--------------|
| `FULLSEND_FORGE` | Forge platform. Set automatically by the harness `forge.<platform>.env` section. | (set by harness) | `"github"`, `"gitlab"` |
| `FULLSEND_TRACKER` | Target tracker for proposals. Defaults to `FULLSEND_FORGE`. | (matches `FULLSEND_FORGE`) | `"github"`, `"gitlab"`, `"jira"` |
| `RETRO_MODE` | Output mode. `all` creates issues and posts summary; `summary_only` disables issue creation and lists proposals in the summary; `issues_only` files issues without posting a summary. | `"all"` | `"all"`, `"summary_only"`, `"issues_only"` |
| `RETRO_JIRA_PROJECT` | Jira project key where proposal issues are filed when `FULLSEND_TRACKER=jira`. | none (required for Jira issue creation) | Jira project key (e.g. `"PROJ"`) |
| `RETRO_JIRA_ISSUE_TYPE` | Issue type name for created Jira issues. | `"Task"` | e.g. `"Task"`, `"Improvement"` |
| `RETRO_JIRA_LABELS` | Comma-separated allowlist of labels that retro may apply to created Jira issues. | `"ready-for-triage"` | Alphanumeric label names |
| `JIRA_BASE_URL` | Jira Cloud base URL (`https://<site>.atlassian.net`). Required when `FULLSEND_TRACKER=jira` (except forge summary-only runs). | none | Jira Cloud URL (`https://<site>.atlassian.net`) |
| `JIRA_TOKEN` | Jira API token. Required when `FULLSEND_TRACKER=jira` (except forge summary-only runs). | none | Secret string |
| `FULLSEND_DIR` | Directory containing `.fullsend/config.yaml` for CLI issue operations. Required when `FULLSEND_TRACKER=jira` (except forge summary-only runs). | none | Directory path |
| `JIRA_USER_EMAIL` | Bot-user email. When set, uses Basic auth with email and token; when unset or empty, uses Bearer auth. | none | Email address |
| `JIRA_API_URL` | REST API gateway base URL. | `JIRA_BASE_URL` | Valid HTTPS URL |
| `RETRO_JIRA_MAX_PAGES` | Maximum pages fetched per paginated Jira read. | `50` | Positive integer |

### Jira integration

Retro can deliver findings and improvement proposals to Jira Cloud instead of (or in addition to) GitHub/GitLab:

- **Jira issue creation:** When `FULLSEND_TRACKER=jira`, retro files validated proposals into an operator-configured Jira Cloud project (`RETRO_JIRA_PROJECT`). Model proposals do not select arbitrary Jira projects.
- **Dedup search against forge:** The agent's duplicate search (`related_issues`) searches existing issues on the originating forge. Numeric references in the proposal receipt are rendered as full forge issue URLs, and proposals record their intended `Target repository`.
- **Configurable output modes:** `RETRO_MODE` supports `all` (default: creates Jira issues and posts summary comment), `summary_only` (posts summary comment with proposals listed without creating issues), or `issues_only` (creates issues without posting summary; exits non-zero if proposals fail or are skipped).
- **Idempotency & retry protection:** Before filing an issue in Jira, retro checks for an existing issue in `RETRO_JIRA_PROJECT` with an identical summary; reruns that produce different titles can still create duplicates.
- **Traceability:** Created Jira issues preserve the originating GitHub/GitLab PR URL in the body footer, and the retro summary comment links back to all created Jira issues.
- **Preflight validation:** Checks Jira create metadata (`createmeta`) before creating issues. Fails with a warning and reports uncreated proposals in the summary if the issue type is missing or requires fields retro does not provide.

To have retrospectives triggered by PR/MR close file their proposals in Jira, set `FULLSEND_TRACKER=jira` and the Jira variables in the runner env by extending the harness with `base:` composition. This configures the destination, not the event trigger; the standard retro dispatch must also be enabled for the repo. PR/MR close triggers retro whether merged or not, and `/fs-retro` remains available for manual runs.

```yaml
# .fullsend/retro.yaml
base: https://raw.githubusercontent.com/fullsend-ai/agents/<SHA>/harness/retro.yaml#sha256=<sha256sum>
env:
  runner:
    FULLSEND_TRACKER: jira
    RETRO_JIRA_PROJECT: PROJ
    RETRO_JIRA_ISSUE_TYPE: Task
    RETRO_MODE: all
    JIRA_BASE_URL: ${JIRA_BASE_URL}
    JIRA_TOKEN: ${JIRA_TOKEN}
    # Bot user only. Omit for a service account token (Bearer auth).
    JIRA_USER_EMAIL: ${JIRA_USER_EMAIL}
    FULLSEND_DIR: ${FULLSEND_DIR}
```

Cross-project issue creation in Jira can also be restricted via `tracker.jira.allowed_targets.projects` in `config.yaml`. The `tracker.jira` configuration in `config.yaml` (under `FULLSEND_DIR`) is required by the `fullsend` CLI for Jira issue operations; ensure the configured primary project or allowed targets match `RETRO_JIRA_PROJECT`. When `tracker.jira.allowed_targets.projects` is omitted, the allowlist check is advisory and permits issue creation into the operator-configured `RETRO_JIRA_PROJECT`. Setting an explicit empty list (`projects: []`) revokes all Jira issue creation.

### Issue filing allowlist

Cross-repo issue creation is governed by `tracker.<provider>.allowed_targets`
in `config.yaml` — the same allowlist used by the [triage agent](triage.md)
for prerequisite issues. The post-script honors the targets of the
`tracker` provider block that matches `FULLSEND_TRACKER` (falling back to
`FULLSEND_FORGE`): `tracker.github.allowed_targets.orgs` and `repos` on GitHub,
`tracker.gitlab.allowed_targets.groups` and `repos` on GitLab (a group
also covers its subgroups' projects), or `tracker.jira.allowed_targets.projects`
on Jira. A `tracker` mapping for another provider, or one with more than one
provider block, grants no cross-repo/cross-project targets (the post-script
logs a warning naming the providers it found). The former
`create_issues.allow_targets` key is no longer read and logs a
warning if present; move `orgs` and `repos` to
`tracker.github.allowed_targets`, `repos` to
`tracker.gitlab.allowed_targets` (with `groups` for group-wide access), or
`projects` to `tracker.jira.allowed_targets`. Proposals targeting repos or
projects outside the allowlist are skipped with a warning and surfaced in the
summary comment so they can be filed manually.

A configuration preset (`config.base.yaml`, beside `config.yaml`) is
composed beneath the overlay with fullsend's whole-object `tracker` merge:
an overlay without `tracker` (or with a null or bare `tracker:`) inherits
the base's targets, and an overlay that sets `tracker` (including an
explicit empty target policy) replaces them. A null or bare `tracker:` that
inherits base targets prints a warning; to revoke them, set an explicit empty
`allowed_targets` instead. If either file cannot be parsed, cross-repo issue
creation is disabled with a warning.

The originating repo (where the PR that triggered the retro lives) is
always implicitly allowed.

## Multi-forge support

The retro agent supports both GitHub and GitLab. The harness
`forge.<platform>` sections configure platform-specific policies,
skills, env vars, and providers. Key differences from single-forge
setup:

- **`FULLSEND_FORGE`** is required. Set automatically by the harness
  `forge.<platform>.env` section (`"github"` or `"gitlab"`).
- **Policy** is `policies/base.yaml` for all forges. Network access is
  provided by profiles (`fullsend-gitlab-ro` for GitLab).
- **GitLab uses `curl`** instead of `gh` for API access. The GitLab
  profile (`fullsend-gitlab-ro`) allows `curl` for GitLab API
  endpoints only.
- **GitLab host validation** — `forge_validate_originating_url`
  validates the host against `CI_SERVER_HOST`, a GitLab CI predefined
  variable set automatically by the runner. Validation fails closed
  when `CI_SERVER_HOST` is not set. The GitLab profile in
  `profiles/fullsend-gitlab-ro.yaml` must also be updated.

## How the agent works

The retro agent reconstructs the full workflow graph — [triage](triage.md), [code](code.md), [review](review.md), [fix](fix.md), and human interactions — by fetching issue and PR timelines, agent run logs, and review threads.

1. **Pre-script** gathers metadata about the originating PR or issue.
2. **Sandbox** — the agent reads the full workflow history, identifies patterns (wasted cycles, missed context, repeated failures), and writes structured proposals. It uses the retro-analysis and finding-agent-runs skills. The agent cannot write files or edit code in the target repo.
3. **Validation loop** — output is checked against a schema, with up to 2 retries.
4. **Post-script** creates issues from the agent's proposals. Proposals whose titles match evidence-for patterns (e.g. "Evidence for #1234: ...") are filtered out and folded into the summary comment as evidence notes instead of being filed as issues.

When triggered via `/fs-retro`, the human's comment is passed to the agent as high-signal direction about what to focus on.

## Custom network policy

If this agent needs to reach hosts beyond the defaults, see the
[custom network policy guide](network-policy.md).

## Runtime support

Supported runtimes: **claude** (stable default), **pi** (experimental). On pi, sub-agents run with the agent model, see [Fullsend pi docs](https://fullsend.sh/docs/runtimes/pi) on how to define a different model for sub-agents.

**Codex** is not a supported runtime for retro yet. Retro dispatches native Codex children only when the runtime note lists registered sub-agent roles, which depends on [fullsend #6970](https://github.com/fullsend-ai/fullsend/issues/6970); this section changes after a live retro run on Codex is linked here. Retro passes no `model`: the runner binds each child's model from `agents[].subagents`, or its run-level default.

Effort: `high` (explicit in the harness; override per run with `fullsend run --effort` or `FULLSEND_EFFORT`, values `low`–`max`).

## Source

[`harness/retro.yaml`](https://github.com/fullsend-ai/agents/blob/main/harness/retro.yaml)
