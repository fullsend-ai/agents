# Prioritize Agent

![Prioritize agent icon](icons/prioritize.png)

Scores an issue using the RICE framework (Reach, Impact, Confidence, Effort) and produces scores with reasoning for project board ranking. Supports both GitHub and GitLab forges.

On GitHub, scores are written to Projects V2 custom fields and posted as a reasoning comment. On GitLab, scores are posted as a sticky issue comment. GitLab custom fields API integration is deferred — the Issues API silently ignores unknown keys, and the correct Custom Fields API requires Premium/Ultimate with runtime field ID resolution.

## Setup

No additional setup is required beyond the standard fullsend configuration.

## How it helps

- Issues are ranked consistently using the same framework, reducing bias from whoever happens to see them first.
- Scoring reasoning is transparent and auditable — anyone can read why an issue was ranked the way it was.
- Project boards stay sorted by value, so humans can focus on the highest-impact work first.

## Triggers

On GitHub, the prioritize agent runs on a schedule, polling the project board for unscored or stale issues. On GitLab, it is triggered manually.

It can also be triggered manually on either forge with the `/fs-prioritize` command.

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
a sticky comment on the issue.

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
| `FULLSEND_FORGE` | Forge platform. Set automatically by the harness `forge.<platform>.env` section. | (set by harness) | `"github"`, `"gitlab"` |

## How the agent works

The prioritize agent fetches the issue and all its context, then evaluates it across the four RICE dimensions. It can invoke customer-research skills to gather additional signal about reach and impact. The output is a structured JSON result with per-dimension scores and written reasoning, which the post-script uses to update scores on the forge (GitHub Projects V2 fields or GitLab issue comment).

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
- **`policy`, `skills`, and `host_files` live in forge sections**: This
  harness defines policy, skills, and the forge-specific env file
  (`env/github/prioritize.env` / `env/gitlab/prioritize.env`) under
  `forge.<platform>` rather than at the top level.

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

[`harness/prioritize.yaml`](../harness/prioritize.yaml)
