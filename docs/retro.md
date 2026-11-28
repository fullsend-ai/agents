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

The retro agent runs automatically when a PR is closed (merged or not), including after a merge. On GitLab, the equivalent merge-request close event triggers it as well. The Jira integration below changes where the retro's proposals are filed, not where the retrospective starts: for a PR/MR-close or `/fs-retro` run the agent still traces the forge workflow. For example, with `FULLSEND_TRACKER=jira`, closing a PR or MR starts the retrospective, its validated proposals are filed in the configured Jira project, and the summary comment is posted back to that PR or MR — once dispatch supplies Jira credentials to forge-originated runs ([Jira integration](#jira-integration) covers what happens until then).

A retro can also start from a Jira issue for a manually dispatched run: pass the issue URL (`https://<site>.atlassian.net/browse/<issue-key>`) as `ORIGINATING_URL` with `FULLSEND_TRACKER=jira`. The host pre-script fetches the issue and its comments (the sandbox has no Atlassian route or Jira credential), the agent reads them from `RETRO_JIRA_CONTEXT` and traces the forge side of the workflow, and the retrospective summary is posted back to the Jira issue with `fullsend issues post-comment --tracker jira`. Jira events are still not dispatched or polled: [Jira-originated runs](#jira-originated-runs) covers the requirements and the current limits.

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
| `RETRO_JIRA_CONTEXT_FILE` | Host path the pre-script writes the originating Jira issue context to; `harness/retro.yaml` mounts exactly this path into the sandbox. Set it in the environment `fullsend run` starts in (see [Jira-originated runs](#jira-originated-runs)). | none (required for a Jira-originated run) | Absolute host path |
| `RETRO_JIRA_CONTEXT_MAX_BYTES` | Byte cap for the context file; oldest comments are dropped first and `comments_truncated` is set. | `262144` | Positive integer |
| `RETRO_JIRA_CONTEXT_MAX_PAGES` | Maximum comment pages fetched for the context file; the page cap drops the newest comments. | `10` | Positive integer |
| `RETRO_JIRA_CONTEXT_COMMENT_CHARS` | Per-comment character cap in the context file; a clipped body ends in `…(truncated)`. | `4000` | Positive integer |
| `RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS` | Description character cap in the context file; sets `issue.description_truncated` when it applies. | `20000` | Positive integer |

REST reads (create metadata, issue edit metadata, duplicate search, label updates) are routed the same way as the `fullsend` CLI, as described in [Jira REST routing](#jira-rest-routing).

### Jira integration

Retro can deliver findings and improvement proposals to Jira Cloud instead of GitHub/GitLab; the summary comment still goes to the originating PR/MR:

- **Jira issue creation:** When `FULLSEND_TRACKER=jira`, retro files validated proposals into an operator-configured Jira Cloud project (`RETRO_JIRA_PROJECT`). Model proposals do not select arbitrary Jira projects.
- **Dedup search against forge:** The agent's duplicate search (`related_issues`) searches existing issues on the originating forge. Numeric references in the proposal receipt are rendered as full forge issue URLs, and proposals record their intended `Target repository`.
- **Configurable output modes:** `RETRO_MODE` supports `all` (default: creates Jira issues and posts summary comment), `summary_only` (posts summary comment with proposals listed without creating issues), or `issues_only` (creates issues without posting summary; exits non-zero if proposals fail or are skipped).
- **Idempotency & retry protection:** Before filing an issue in Jira, retro checks for an existing issue in `RETRO_JIRA_PROJECT` with an identical summary, and it skips any summary it already filed earlier in the same run, because the search index lags behind writes. Reruns that produce different titles can still create duplicates. Issues that already exist are reported under `### Already filed (existing issue)` in the summary comment, not under `### Proposals filed`.
- **Traceability:** Created Jira issues preserve the originating GitHub/GitLab PR URL in the body footer, and the retro summary comment links back to all created Jira issues.
- **Body size:** The `fullsend` CLI rejects a Jira body over 32 KiB before converting the Markdown, so an oversized proposal body is truncated at a character boundary, marked as truncated, and keeps the originating-URL footer. The issue is still filed; the full text remains on the originating PR/MR.
- **Title size:** Jira Cloud rejects a summary over 255 characters or containing a line break, and the retro result schema permits both, so a Jira-bound proposal title is normalized once — whitespace (including CR/LF) collapsed to single spaces, trimmed, and cut to 255 characters on a code-point boundary — before the duplicate check, the in-run dedupe set and the create. Dedupe therefore compares the summary Jira stores rather than the raw model output.
- **Comment size:** The same 32 KiB limit applies to the summary comment posted back to a Jira-originated issue, and it is measured in bytes. An oversized summary is truncated on a character boundary under that cap (leaving room for the CLI's marker neutralization) and marked as truncated.
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

### Jira-originated runs

A retro can analyze a Jira work item instead of a PR/MR or forge issue. This
is reached by a manually dispatched `fullsend run` that passes the issue URL
as `ORIGINATING_URL`; automatic Jira dispatch is not implemented.

The sandbox has no route to Atlassian and no Jira credential, so the split is:

- **Host (`pre-retro.sh`)** validates the URL against `JIRA_BASE_URL`, fetches
  the issue and every comment (oldest first) through the Jira REST API with the
  runner's credentials, and writes `RETRO_JIRA_CONTEXT_FILE`. That variable is
  required for this run: the harness declares it as the `host_files` src it
  mounts, so the path written here and the path mounted are one setting. The
  harness mounts it into the sandbox as `/sandbox/workspace/jira-origin.json`,
  read by the agent as `RETRO_JIRA_CONTEXT`. A stale file at that path is
  removed at the start of every run, forge-originated ones included. The fetch
  fails the run when it cannot read the issue: a retrospective must not analyze
  a work item it cannot see.
- **Sandbox** reads `RETRO_JIRA_CONTEXT` (key, browse URL, summary,
  description, status, labels, parent and links, plus comments oldest first)
  and traces the agent side on the forge, using the same GitHub/GitLab
  recipes as a forge-originated run.
- **Host (`post-retro.sh`)** files validated proposals in
  `RETRO_JIRA_PROJECT` and posts the summary back to the originating issue
  with `fullsend issues post-comment --tracker jira`.

Requirements: `FULLSEND_TRACKER=jira`, the Jira variables from the
[overlay](#jira-integration), `FULLSEND_DIR`, `RETRO_JIRA_CONTEXT_FILE` (an
absolute host path, exported for the run), and a forge whose token lets the
agent read the run logs — the harness still declares `GH_TOKEN`
(`GITLAB_TOKEN` on GitLab) in `env.runner`, so export it for the run to start.

Set `RETRO_JIRA_CONTEXT_FILE` in the environment `fullsend run` starts in — its
job, shell or CI environment — not only in the overlay's `env.runner`.
fullsend expands the `${VAR}` in a `host_files` src from its own environment,
so a value that only reaches the pre-script would leave the mount unset. A
literal absolute path in the harness is not an option: fullsend refuses one
(`base host_files[N].src must be a relative path`) when the harness is loaded
from a URL or composed with `base:`, which is how this agent is consumed.

Use a path that is unique per run, because a reused runner shares it across
concurrent retros. `pre-retro` removes any file at the path when it starts and
`post-retro` removes it when the run ends, so a fixed path lets one run delete
another's context file between its pre-script and the harness upload. For
example, in the job or shell environment:

```bash
export RETRO_JIRA_CONTEXT_FILE="${RUNNER_TEMP}/jira-origin-${GITHUB_RUN_ID}.json"
```

The context file is capped so a long issue cannot exhaust the agent's context:
`RETRO_JIRA_CONTEXT_MAX_BYTES` (default `262144`) drops the oldest comments
first and sets `comments_truncated`; `RETRO_JIRA_CONTEXT_COMMENT_CHARS`
(default `4000`) and `RETRO_JIRA_CONTEXT_DESCRIPTION_CHARS` (default `20000`)
truncate individual bodies and set `description_truncated`; and
`RETRO_JIRA_CONTEXT_MAX_PAGES` (default `10`) bounds comment pagination, which
also sets `comments_truncated` — comments are requested oldest first, so a page
cap drops the newest ones. The agent is told to report those truncations in its
summary rather than treat the text as complete.

### Jira REST routing

Retro routes its own REST reads and label writes exactly as the `fullsend` CLI routes Jira calls:

- `tracker.jira.api_url` in `FULLSEND_DIR`'s config is the Atlassian gateway base. It defaults to `https://api.atlassian.com`.
- The cloud ID is discovered from the site at `tracker.jira.base_url` (`<site>/_edge/tenant_info`); the lookup carries no credentials.
- Every REST call goes to `<api_url>/ex/jira/<cloudId>/rest/api/3/...`.

No `JIRA_API_URL` environment variable is read. When `tracker.jira.base_url` is set it must equal `JIRA_BASE_URL`, so reads and CLI writes cannot be split across tenants. The configuration is read from `FULLSEND_DIR`, the same directory the CLI reads, and an overlay that sets `tracker` replaces the preset's `tracker` block as a whole.

For a PR/MR-close run, fullsend must also hand the Jira credentials to the
runner: the overlay maps them from `FULLSEND_JIRA_TOKEN` and
`FULLSEND_JIRA_EMAIL` (or the client credentials). That is the gap for
forge-originated runs: for a github or gitlab event, dispatch passes no Jira
credentials and unsets `FULLSEND_JIRA_TOKEN`, `FULLSEND_JIRA_EMAIL` and the
client credentials, so the mapping has nothing to resolve.
[fullsend-ai/fullsend#2267](https://github.com/fullsend-ai/fullsend/issues/2267)
is the request to add Jira support to this agent, which this implementation
satisfies; it is not the credential gap, which needs a dispatch change that no
issue tracks yet.

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
filing as unverified until dispatch passes those credentials and this path has
run once against a test repository.

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

Supported runtimes: **claude** (stable default), **pi** (experimental), **codex** (experimental). On pi, sub-agents run with the agent model, see [Fullsend pi docs](https://fullsend.sh/docs/runtimes/pi) on how to define a different model for sub-agents.

On codex, retro's sub-agents run as [native Codex children](https://fullsend.sh/docs/runtimes/codex#sub-agents), at most four at once, when both of these hold:

- harness security is on (`security.enabled`, the default);
- Codex resolves the parent model to [collaboration V1 or V2](https://fullsend.sh/docs/runtimes/codex#sub-agents) at its pinned version.

Even then, they do not in these cases:

- the parent model is a `gateway/` model;
- the parent is on V2 and a child model selects V2.

In every other case, the parent does the sub-agents' work itself, in one context.

Retro passes no `model`: every child runs on the run-level child model ([child models](https://fullsend.sh/docs/runtimes/codex#child-models)). The GitHub fleet workflows do not pass `FULLSEND_CODEX_SUBAGENT_MODEL`, so on that path set the run-level child model with `subagents.default` on the agent's `agents:` entry.

Retro has run this way only locally, not through the fleet workflows:

- On a V1 parent, once on macOS ([fullsend #6970](https://github.com/fullsend-ai/fullsend/issues/6970#issuecomment-6606379606)) and once on Fedora ([fullsend #6970](https://github.com/fullsend-ai/fullsend/issues/6970#issuecomment-6609114516)). In the Fedora run the parent passed `agent_type: "explore"` to all five children, where `agents/retro.md` says to pass none, so they ran the `explore` role's instructions instead of the `default` role's. The same parent sent overlapping waits to one child, fetched the PR's comments, reviews and files itself instead of in a child, and had the duplicate-search child judge overlap, which the retro-analysis skill leaves to the parent ([fullsend #9657](https://github.com/fullsend-ai/fullsend/issues/9657)).
- On a V2 parent, once on macOS ([fullsend #9085](https://github.com/fullsend-ai/fullsend/issues/9085#issuecomment-6920231259)).

Effort: `high` (explicit in the harness; override per run with `fullsend run --effort` or `FULLSEND_EFFORT`, values `low`–`max`).

## Source

[`harness/retro.yaml`](https://github.com/fullsend-ai/agents/blob/main/harness/retro.yaml)
