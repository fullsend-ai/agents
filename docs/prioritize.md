# Prioritize Agent

![Prioritize agent icon](icons/prioritize.png)

Scores an issue using the RICE framework (Reach, Impact, Confidence, Effort) and produces scores with reasoning for project board ranking. Supports GitHub and GitLab forges. A Jira Cloud forge exists in the harness but is **dark**: it is not dispatched, does not change `/fs-prioritize` on GitHub or GitLab, and is used only when `FULLSEND_FORGE=jira`.

On GitHub, scores are written to Projects V2 custom fields and posted as a reasoning comment. On GitLab, scores are posted as a sticky issue comment. GitLab custom fields API integration is deferred — the Issues API silently ignores unknown keys, and the correct Custom Fields API requires Premium/Ultimate with runtime field ID resolution.

On Jira, when that forge is explicitly selected, scores are written to five number custom fields named `RICE Reach`, `RICE Impact`, `RICE Confidence`, `RICE Effort`, and `RICE Score`, plus a sticky comment. Rank, Priority, and other Jira fields are never written. If those RICE fields do not exist yet, the post-script fails closed.

## Setup

No additional setup is required beyond the standard fullsend configuration.

## How it helps

- Issues are ranked consistently using the same framework, reducing bias from whoever happens to see them first.
- Scoring reasoning is transparent and auditable — anyone can read why an issue was ranked the way it was.
- Project boards stay sorted by value, so humans can focus on the highest-impact work first.

## Triggers

On GitHub, the prioritize agent runs on a schedule, polling the project board for unscored or stale issues. On GitLab, it is triggered manually.

It can also be triggered manually on GitHub or GitLab with the `/fs-prioritize` command. Jira has no `/fs-prioritize` dispatch in this release.

The harness also declares a CEL `trigger:` for fullsend's harness dispatch that matches `/fs-prioritize` from a human on an issue, a PR or an MR. The scheduled path does not use it. Dispatch does not evaluate it for the built-in prioritize agent yet, so the routing above is what runs today.

## Commands

| Command | Where | Effect |
|---------|-------|--------|
| `/fs-prioritize` | Issue comment | Runs RICE scoring on the issue |

Requires write-level repository permission.

The `/fs-prioritize` command does not accept arguments. It scores the issue
using the current content, comments, and any available `customer-research`
skill data.

## Control labels

The prioritize agent does not apply or consume control labels. It reads the
issue content and produces a score. On GitHub, the project board is updated
directly via Projects V2 custom fields. On GitLab, scores are posted as
a sticky comment on the issue. On Jira (opt-in forge only), the five RICE
number fields and a sticky comment are updated; Rank and Priority are not.

## Configuration

### Skill: `customer-research`

The prioritize agent looks for a `customer-research` skill and, when available,
uses it to inform Reach and Impact scores. To provide it, create a skill directory
in your target repository at `.agents/skills/customer-research/` with a `SKILL.md` and
any helper scripts organized in a `scripts/` subdirectory. Then symlink `.claude/skills`
to `.agents/skills` so the skill is discoverable by both Fullsend and any local
agent tooling:

```
your-repo/
  .agents/skills/customer-research/
    SKILL.md
    scripts/
  .claude/skills -> ../.agents/skills
```

This gives the prioritize agent concrete data to distinguish between "one user
wants this" (Reach 0.25) and "three strategic accounts have filed support cases
about it" (Reach 2.0), instead of guessing from the issue text alone.

### Variables

| Variable | Description | Default | Valid values |
|----------|-------------|---------|--------------|
| `FULLSEND_FORGE` | Forge platform. Set automatically by the harness `forge.<platform>.env` section. | (set by harness) | `"github"`, `"gitlab"`, `"jira"` (jira is dark / not dispatched) |

The following apply **only** when `FULLSEND_FORGE=jira`. GitHub and GitLab `/fs-prioritize` ignore them. Nothing in this repo dispatches the Jira forge yet.

| Variable | Description |
|----------|-------------|
| `FULLSEND_JIRA_TOKEN` | Repository secret. The harness maps it to runner `JIRA_TOKEN` for post-script field writes and sticky comments. The sandbox never gets the real token; it receives the `jira-ro` provider's opaque placeholder. Required to actually run the Jira forge. |
| `FULLSEND_JIRA_EMAIL` | Optional. Bot-user email. When set, requests use Basic auth (email + token); when unset or empty (service account), Bearer auth with the token. The harness maps it to runner `JIRA_USER_EMAIL`; the sandbox gets `JIRA_USER_EMAIL` through `env/jira/prioritize.env`. |
| `JIRA_API_URL` | Optional. Where the post-script curl helpers and the sandboxed skills send REST calls. `fullsend run` sets it to the Atlassian API gateway for the site (`https://api.atlassian.com/ex/jira/<cloudId>`). The sandbox receives it via `env/jira/prioritize.env`; that file does not reach host-side `post-prioritize.sh`. On the host, when unset, the post-script reads `tracker.jira.api_url` from `${FULLSEND_DIR}/config.yaml`, then falls back to `JIRA_BASE_URL`. |
| `JIRA_BASE_URL` | Jira Cloud site URL (e.g. `https://<site>.atlassian.net`). Used for browse links and as the REST fallback. Derived from `ISSUE_URL` when unset. |
| `FULLSEND_DIR` | The `.fullsend` directory. The post-script passes it to `fullsend issues post-comment --fullsend-dir`, which reads `tracker.jira` from its `config.yaml`. Host-side curl also reads `tracker.jira.api_url` from that file when `JIRA_API_URL` is unset. Required for the sticky comment on Jira. |

## How the agent works

The prioritize agent fetches the issue and all its context, then evaluates it across the four RICE dimensions. It can invoke customer-research skills to gather additional signal about reach and impact. The output is a structured JSON result with per-dimension scores and written reasoning, which the post-script uses to update scores on the forge (GitHub Projects V2 fields, GitLab issue comment, or Jira RICE number fields when that forge is selected).

### Migration notes for custom harness overrides

If you use `base:` composition to override `harness/prioritize.yaml`:

- **`ISSUE_URL` replaces `GITHUB_ISSUE_URL` inside scripts**: The sandbox and
  runner env var consumed by pre/post scripts is now `ISSUE_URL` (forge-neutral).
  `GITHUB_ISSUE_URL` remains the workflow-level input for the GitHub forge; the
  harness maps it to `ISSUE_URL` via `env.runner` / `env.sandbox`. Custom
  pre/post scripts that reference `GITHUB_ISSUE_URL` directly should switch to
  `ISSUE_URL`.
- **`FULLSEND_FORGE` is required**: Pre- and post-scripts require this env var
  to select the correct forge operations. It is set automatically by the forge
  sections in the harness; if your override removes the forge sections, set it
  explicitly in `env.runner` and `env.sandbox`.
- **`ORG` and `PROJECT_NUMBER` are now optional**: These were previously
  hard-required; they are now soft-optional. When unset, the project
  board update is skipped and scores are posted as a comment only.
- **`providers`, `openshell`, `skills`, and `host_files` live in forge sections**: This
  harness defines providers, openshell profiles, skills, and the forge-specific
  env file (`env/github/prioritize.env` / `env/gitlab/prioritize.env` /
  `env/jira/prioritize.env`) under `forge.<platform>` rather than at the top
  level. The Jira section is unused unless `FULLSEND_FORGE=jira`.

### GitLab host validation

The GitLab forge operations validate `GITLAB_HOST` against
`CI_SERVER_HOST`, a GitLab CI predefined variable set automatically by
the runner. Validation fails closed when `CI_SERVER_HOST` is not set.
The GitLab profile in `profiles/fullsend-gitlab-ro.yaml` must also be
updated to allow connections to the host.

## Custom network policy

If this agent needs to reach hosts beyond the defaults, see the
[custom network policy guide](network-policy.md).

## Runtime support

Supported runtimes: **claude** (stable default), **pi** (experimental). No single-context fallback — full RICE scoring runs on both runtimes.

Effort: `high` (explicit in the harness; override per run with `fullsend run --effort` or `FULLSEND_EFFORT`, values `low`–`max`).

## Source

[`harness/prioritize.yaml`](https://github.com/fullsend-ai/agents/blob/main/harness/prioritize.yaml)
