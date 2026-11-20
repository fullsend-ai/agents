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

The retro agent runs automatically when a PR is closed (merged or not), including after a merge. On GitLab, the equivalent merge-request close event triggers it as well. The Jira integration below changes where the retro's proposals are filed; it does not change the trigger. For example, with `FULLSEND_TRACKER=jira`, closing a PR or MR starts the retrospective and its validated proposals are filed in the configured Jira project — once dispatch supplies Jira credentials to forge-originated runs, which is tracked in [fullsend-ai/fullsend#2267](https://github.com/fullsend-ai/fullsend/issues/2267) and still open ([Jira integration](#jira-integration) covers what happens until then). Jira-originated runs are not dispatched or polled at all: only a local `fullsend run` started by hand can pass a Jira issue URL (`https://<site>.atlassian.net/browse/PROJ-123`) as `ORIGINATING_URL`. In that case, the retrospective summary comment is posted directly back to the Jira issue via `fullsend issues post-comment --tracker jira`; the script needs no forge credentials, but the harness still declares `GH_TOKEN` (`GITLAB_TOKEN` on GitLab) in `env.runner`, so that variable must be exported for the run to start.

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
| `FULLSEND_TRACKER` | Target tracker for proposals. Defaults to `FULLSEND_FORGE`. | (matches `FULLSEND_FORGE`) | `"jira"`, or the same value as `FULLSEND_FORGE` (cross-forge filing is not supported) |
| `RETRO_MODE` | Output mode. `all` creates issues and posts summary; `summary_only` disables issue creation and lists proposals in the summary; `issues_only` files issues without posting a summary. | `"all"` | `"all"`, `"summary_only"`, `"issues_only"` |
| `RETRO_JIRA_PROJECT` | Jira project key where proposal issues are filed when `FULLSEND_TRACKER=jira`. | none (required for Jira issue creation) | Jira project key (e.g. `"PROJ"`) |
| `RETRO_JIRA_ISSUE_TYPE` | Issue type name for created Jira issues. | `"Task"` | e.g. `"Task"`, `"Improvement"` |
| `RETRO_JIRA_LABELS` | Comma-separated Jira labels retro applies to created issues. Set empty to create issues without labels. | `"ready-for-triage"` | Label names of 1–64 characters from letters, digits, `.`, `_`, and `-` |
| `JIRA_BASE_URL` | Jira Cloud base URL (`https://<site>.atlassian.net`). Required when `FULLSEND_TRACKER=jira` (except forge summary-only runs). | none | Jira Cloud URL (`https://<site>.atlassian.net`) |
| `JIRA_TOKEN` | Jira API token. Required when `FULLSEND_TRACKER=jira` (except forge summary-only runs), unless using OAuth client credentials. | none | Secret string |
| `FULLSEND_JIRA_CLIENT_ID` / `FULLSEND_JIRA_CLIENT_SECRET` | OAuth client credentials alternative to `JIRA_TOKEN`. The access token they mint is sent through the Atlassian API gateway (`tracker.jira.api_url`). | none | Secret credentials |
| `FULLSEND_DIR` | The `.fullsend` directory itself (the directory that holds `config.yaml`), used for CLI issue operations and the `tracker.jira` policy. Required when `FULLSEND_TRACKER=jira` (except forge summary-only runs). | none | Directory path |
| `JIRA_USER_EMAIL` | Bot-user email. When set, uses Basic auth with email and token; when unset or empty, uses Bearer auth. | none | Email address |
| `RETRO_JIRA_MAX_PAGES` | Maximum pages fetched per paginated Jira read. | `50` | Positive integer |

REST reads (create metadata, issue edit metadata, duplicate search, label updates) are routed the same way as the `fullsend` CLI, as described in [Jira REST routing](#jira-rest-routing).

### Jira integration

Retro can deliver findings and improvement proposals to Jira Cloud instead of (or in addition to) GitHub/GitLab:

- **Jira issue creation:** When `FULLSEND_TRACKER=jira`, retro files validated proposals into an operator-configured Jira Cloud project (`RETRO_JIRA_PROJECT`). Model proposals do not select arbitrary Jira projects.
- **Dedup search against forge:** The agent's duplicate search (`related_issues`) searches existing issues on the originating forge. Numeric references in the proposal receipt are rendered as full forge issue URLs, and proposals record their intended `Target repository`.
- **Configurable output modes:** `RETRO_MODE` supports `all` (default: creates Jira issues and posts summary comment), `summary_only` (posts summary comment with proposals listed without creating issues), or `issues_only` (creates issues without posting summary; exits non-zero if proposals fail or are skipped).
- **Idempotency & retry protection:** Before filing an issue in Jira, retro checks for an existing issue in `RETRO_JIRA_PROJECT` with an identical summary; reruns that produce different titles can still create duplicates.
- **Traceability:** Created Jira issues preserve the originating GitHub/GitLab PR URL in the body footer, and the retro summary comment links back to all created Jira issues.
- **Body size:** The `fullsend` CLI rejects a Jira body over 32 KiB before converting the Markdown, so an oversized proposal body is truncated at a character boundary, marked as truncated, and keeps the originating-URL footer. The issue is still filed; the full text remains on the originating PR/MR.
- **Preflight validation:** Checks Jira create metadata (`createmeta`) before creating issues. Fails with a warning and reports uncreated proposals in the summary if the issue type is missing or requires fields retro does not provide.
- **Labels:** Applied by an issue update after creation, which Jira validates against the issue's edit screen. An issue type whose edit screen has no Labels field gets no labels and a warning; the issue is still filed.

To have retrospectives triggered by PR/MR close file their proposals in Jira, set `FULLSEND_TRACKER=jira` and the Jira variables in the runner env by extending the harness with `base:` composition. This configures the destination, not the event trigger; the repo must have the standard retro harness dispatch enabled (the dispatch mechanism that routes PR close events and `/fs-retro` comments to this harness). PR close triggers retro whether merged or not, and `/fs-retro` remains available for manual runs. A Jira issue URL as `ORIGINATING_URL` is supported only for a manually dispatched run; automatic Jira issue polling/dispatch is not implemented.

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
    # Fullsend exposes the Jira credentials to the runner as FULLSEND_JIRA_*.
    JIRA_TOKEN: ${FULLSEND_JIRA_TOKEN}
    # Instead of JIRA_TOKEN, configure both client credentials:
    # FULLSEND_JIRA_CLIENT_ID: ${FULLSEND_JIRA_CLIENT_ID}
    # FULLSEND_JIRA_CLIENT_SECRET: ${FULLSEND_JIRA_CLIENT_SECRET}
    # Bot user only. Omit for a service account token (Bearer auth).
    JIRA_USER_EMAIL: ${FULLSEND_JIRA_EMAIL}
    FULLSEND_DIR: ${FULLSEND_DIR}
```

### Jira REST routing

Retro routes its own REST reads and label writes exactly as the `fullsend` CLI routes Jira calls:

- `tracker.jira.api_url` in `FULLSEND_DIR`'s config is the Atlassian gateway base. It defaults to `https://api.atlassian.com`.
- The cloud ID is discovered from the site at `tracker.jira.base_url` (`<site>/_edge/tenant_info`); the lookup carries no credentials.
- Every REST call goes to `<api_url>/ex/jira/<cloudId>/rest/api/3/...`.

No `JIRA_API_URL` environment variable is read. When `tracker.jira.base_url` is set it must equal `JIRA_BASE_URL`, so reads and CLI writes cannot be split across tenants. The configuration is read from `FULLSEND_DIR`, the same directory the CLI reads, and an overlay that sets `tracker` replaces the preset's `tracker` block as a whole.

For a PR/MR-close run, fullsend must also hand the Jira credentials to the
runner: the overlay maps them from `FULLSEND_JIRA_TOKEN` and
`FULLSEND_JIRA_EMAIL` (or the client credentials). Passing Jira credentials
to forge-originated runs that target Jira is tracked in
[fullsend-ai/fullsend#2267](https://github.com/fullsend-ai/fullsend/issues/2267),
which is still open: for a github or gitlab event, dispatch passes no Jira
credentials and unsets `FULLSEND_JIRA_TOKEN`, `FULLSEND_JIRA_EMAIL` and the
client credentials.

So this overlay does not work for PR/MR-close or `/fs-retro` runs yet, and it
does not fail the way a missing credential usually would. fullsend validates
every `${VAR}` in `env.runner` against the host environment before any
pre-script runs, so an unset `FULLSEND_JIRA_TOKEN` (or an unset
`FULLSEND_JIRA_CLIENT_ID`/`FULLSEND_JIRA_CLIENT_SECRET` pair) aborts the whole
run with `FULLSEND_JIRA_TOKEN is not set (referenced by
env.runner[JIRA_TOKEN])`. No retro runs at all, so that run produces neither
Jira issues nor a forge summary. `${JIRA_BASE_URL}` resolves only when the
repository sets the `JIRA_BASE_URL` variable that dispatch forwards; otherwise
set the site URL literally in the overlay, since `action.yml` does not export
it. Jira-originated runs are not reached by dispatch at all: no route hands
retro a Jira event, a Jira URL or Jira credentials, and the harness still
declares `GH_TOKEN` (`GITLAB_TOKEN` on GitLab) in `env.runner`, so fullsend
requires a forge token before the pre-script runs. Treat forge-originated Jira
filing as unverified until
fullsend-ai/fullsend#2267 lands and this path has run once against a test
repository.

Cross-project issue creation in Jira is governed by `tracker.jira.allowed_targets.projects` in `config.yaml`. The `tracker.jira` configuration in `config.yaml` (under `FULLSEND_DIR`) is required by the `fullsend` CLI for Jira issue operations; `RETRO_JIRA_PROJECT` must match `tracker.jira.project` or one of the allowed targets (case-insensitively). The configured primary project is always permitted; explicit allowed targets add other projects. When `allowed_targets.projects` is omitted, only the configured primary project is permitted. An explicit empty list (`projects: []`) therefore permits the primary project but no other projects. Missing config or a missing primary project denies issue creation.

### Issue filing allowlist

Cross-repo issue creation is governed by `tracker.<provider>.allowed_targets`
in `config.yaml` — the same allowlist used by the [triage agent](triage.md)
for prerequisite issues. The post-script honors the targets of the
`tracker` provider block that matches `FULLSEND_TRACKER` (falling back to
`FULLSEND_FORGE`): `tracker.github.allowed_targets.orgs` and `repos` on GitHub,
`tracker.gitlab.allowed_targets.groups` and `repos` on GitLab (a group
also covers its subgroups' projects), or `tracker.jira.allowed_targets.projects`
on Jira. A `tracker` mapping for another provider, or one with more than one
provider block, grants no cross-repo targets (the post-script logs a warning
naming the providers it found). For a Jira tracker, the configured primary
project is still permitted, because it is not a cross-project grant. The former
`create_issues.allow_targets` key is no longer read and logs a
warning if present; move `orgs` and `repos` to
`tracker.github.allowed_targets`, `repos` to
`tracker.gitlab.allowed_targets` (with `groups` for group-wide access), or
`projects` to `tracker.jira.allowed_targets`. Proposals targeting repos or
projects outside the allowlist are skipped with a warning and surfaced in the
summary comment so they can be filed manually.

For a Jira tracker the policy is read from `FULLSEND_DIR`'s config, the same
file the `fullsend` CLI reads, so the destination that passes this gate is the
destination the CLI honors. The primary project and the target policy are
taken from the merged `tracker` block only; a base-layer project is never
re-added when the overlay replaces `tracker`.

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
