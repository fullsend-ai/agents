---
description: How the fullsend prioritize agent scores GitHub issues with the RICE framework and produces ranked, reasoned priority scores.
---

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

The harness also declares a CEL `trigger:` for fullsend's harness dispatch that matches `/fs-prioritize` from a human on an issue, a PR or an MR. The scheduled path does not use it. Dispatch does not evaluate it for the built-in prioritize agent yet, so the routing above is what runs today.

## Commands

| Command | Where | Effect |
|---------|-------|--------|
| `/fs-prioritize` | Issue comment | Runs RICE scoring on the issue |

Requires write-level repository permission.

The `/fs-prioritize` command does not accept arguments. It scores the issue
using the current content, comments, and any available `customer-research`
skill data.

Project board configuration is optional for on-demand runs. Without a project
number, the agent still posts the RICE score and reasoning comment but skips
the project board update.

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

### Scheduled scoring

The prioritize agent can be triggered automatically by a scheduler workflow
that polls a GitHub Project board for unscored issues. This scheduler
is **not managed by fullsend** — it is bespoke org-level automation that you
create manually in a repository of your choice.

#### Prerequisites

- A GitHub Projects (v2) board with numeric **RICE Reach**, **RICE Impact**,
  **RICE Confidence**, **RICE Effort**, and **RICE Score** fields — the
  scoring run resolves all five and fails if any is missing. Run
  `scripts/setup-prioritize.sh` to create them if they do not
  exist. The script is not installed into target repos; find it in the
  fullsend source tree at
  `internal/scaffold/fullsend-repo/scripts/setup-prioritize.sh`.
- `prioritize.yml` installed in every target repo (handled by `repos install`).
- The scheduler passes `project_number` to each target repo's
  `prioritize.yml` thin caller via `workflow_dispatch` input. If the input
  is not provided, the thin caller falls back to
  `vars.FULLSEND_PROJECT_NUMBER` (repo or org-level variable).
- The following variables and secrets set on the repo that hosts the scheduler:

| Variable / Secret | Type | Required | Description |
|-------------------|------|----------|-------------|
| `FULLSEND_PRIORITIZE_CLIENT_ID` | Variable | Yes | Client ID of the GitHub App with project board and issue read access (`organization_projects: read`, `issues: read`) |
| `FULLSEND_PRIORITIZE_APP_PRIVATE_KEY` | Secret | Yes | Private key for the prioritize GitHub App |
| `FULLSEND_FULLSEND_CLIENT_ID` | Variable | Yes | Client ID of the GitHub App with cross-repo dispatch access (`actions: write`) |
| `FULLSEND_FULLSEND_APP_PRIVATE_KEY` | Secret | Yes | Private key for the fullsend GitHub App |

> **Note:** This example mints tokens directly from GitHub App private keys
> stored as secrets on the scheduler repo. It only works for self-owned Apps
> whose private keys you hold — orgs using fullsend's shared hosted Apps
> (where keys live only with the central mint,
> [ADR 0029](https://github.com/fullsend-ai/fullsend/blob/main/docs/ADRs/0029-central-token-mint-secretless-fullsend.md))
> cannot follow this guide as-is and need a scheduler variant that requests
> tokens from the mint. Minting directly also grants each token the App's full
> installation permissions instead of the minimum the mint enforces; the
> `permission-*` inputs on the token steps below narrow the scope.

#### Example workflow

Create this as `.github/workflows/prioritize-scheduler.yml` in your
`{org}/.fullsend` repo. Replace `<your-project-number>`, `<your-repos>`,
and `<your-runner>` with your org-specific values.

The scheduler uses two GitHub App tokens, kept separate for
least-privilege: the **prioritize** app has only project board and issue
read access (`organization_projects: read`, `issues: read`) and the
**fullsend** app has cross-repo
workflow dispatch (`actions: write`). Combining them into a single app
would give every per-repo prioritize run more permissions than it needs.
See the
[Role Permissions Matrix](https://fullsend.sh/docs/guides/infrastructure/infrastructure-reference#role-permissions-matrix)
for the full permission breakdown.

All operational configuration (project number, target repos,
thresholds) is self-contained in the workflow file via `||` fallback
expressions — the only repository variables and secrets needed are the
GitHub App credentials listed in Prerequisites above. Input descriptions
document the defaults; the `||` fallbacks in the `env` block and the
`repositories` field are the single source of truth (input `default`
values only apply to `workflow_dispatch`, not `schedule` triggers).

```yaml
---
name: Prioritize Scheduler

on:
  schedule:
    - cron: '*/10 * * * *'
  workflow_dispatch:
    inputs:
      project_number:
        description: "GitHub Project number to poll (default: <your-project-number>)"
        required: false
        type: string
      repos:
        description: "Comma-separated repo names to dispatch to (default: <your-repos>)"
        required: false
        type: string
      workflow:
        description: "Workflow filename to dispatch on target repos (default: prioritize.yml)"
        required: false
        type: string
      stale_threshold:
        description: "Re-score issues whose RICE score is older than this (default: 7d)"
        required: false
        type: string
      wip_limit:
        description: "Max number of prioritize jobs to dispatch (default: 5)"
        required: false
        type: number

concurrency:
  group: fullsend-prioritize-scheduler
  cancel-in-progress: false

jobs:
  dispatch:
    name: Find and dispatch issues for RICE scoring
    runs-on: <your-runner>
    timeout-minutes: 5
    permissions:
      contents: read

    steps:
      - name: Checkout repository
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0

      - name: Generate prioritize token (project board access)
        id: prioritize-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          client-id: ${{ vars.FULLSEND_PRIORITIZE_CLIENT_ID }}
          private-key: ${{ secrets.FULLSEND_PRIORITIZE_APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          permission-organization-projects: read
          permission-issues: read

      - name: Generate fullsend token (cross-repo dispatch)
        id: dispatch-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          client-id: ${{ vars.FULLSEND_FULLSEND_CLIENT_ID }}
          private-key: ${{ secrets.FULLSEND_FULLSEND_APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: ${{ inputs.repos || '<your-repos>' }}
          permission-actions: write

      - name: Find issues and dispatch prioritize runs
        env:
          GH_TOKEN: ${{ steps.prioritize-token.outputs.token }}
          DISPATCH_TOKEN: ${{ steps.dispatch-token.outputs.token }}
          ORG: ${{ github.repository_owner }}
          REPOS: ${{ inputs.repos || '<your-repos>' }}
          PROJECT_NUMBER: ${{ inputs.project_number || '<your-project-number>' }}
          STALE_THRESHOLD: ${{ inputs.stale_threshold || '7d' }}
          WORKFLOW: ${{ inputs.workflow || 'prioritize.yml' }}
          WIP_LIMIT: ${{ inputs.wip_limit || '5' }}
        run: |
          set -euo pipefail

          # Parse stale threshold into seconds
          parse_threshold() {
            local val="${1%[dh]}"
            local unit="${1: -1}"
            if [[ -z "${val}" || ! "${val}" =~ ^[1-9][0-9]*$ ]]; then
              echo "ERROR: invalid threshold '${1}' (use Nd or Nh, e.g. 7d)" >&2; exit 1
            fi
            case "${unit}" in
              d) echo $(( val * 86400 )) ;;
              h) echo $(( val * 3600 )) ;;
              *) echo "ERROR: unsupported threshold unit '${unit}' (use Nd or Nh)" >&2; exit 1 ;;
            esac
          }
          THRESHOLD_SECONDS=$(parse_threshold "${STALE_THRESHOLD}")

          # The scheduler only reads the board; the dispatched scoring run
          # writes the score with its own token.
          SCORE_FIELD="RICE Score"  # must match the field the scoring run writes

          # Comma-separated repo names -> JSON array
          REPOS_JSON=$(echo "${REPOS}" | jq -R 'split(",") | map(gsub("^ +| +$"; ""))')

          # Fetch project metadata
          PROJECT_ID=$(gh project view "${PROJECT_NUMBER}" \
            --owner "${ORG}" --format json | jq -r '.id')

          if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
            echo "ERROR: Failed to fetch project ${PROJECT_NUMBER}."
            exit 1
          fi

          # Validate the score field exists (field-list defaults to 30 fields).
          if ! gh project field-list "${PROJECT_NUMBER}" \
            --owner "${ORG}" --format json --limit 100 \
            | jq -e --arg sf "${SCORE_FIELD}" \
              '[.fields[] | select(.name == $sf)] | length > 0' > /dev/null; then
            echo "ERROR: '${SCORE_FIELD}' field not found on project."
            echo "Run scripts/setup-prioritize.sh to create it."
            exit 1
          fi

          # Paginate through all project items (100 per page).
          ALL_ITEMS="[]"
          CURSOR=""
          while true; do
            CURSOR_ARG=""
            if [[ -n "${CURSOR}" ]]; then
              CURSOR_ARG="-f cursor=${CURSOR}"
            fi
            PAGE=$(gh api graphql -f query='
              query($projectId: ID!, $scoreField: String!, $cursor: String) {
                node(id: $projectId) {
                  ... on ProjectV2 {
                    items(first: 100, after: $cursor) {
                      pageInfo { hasNextPage endCursor }
                      nodes {
                        # Fetch the score field by name — fieldValues(first: N)
                        # could miss it on boards with many fields.
                        fieldValueByName(name: $scoreField) {
                          ... on ProjectV2ItemFieldNumberValue {
                            updatedAt
                          }
                        }
                        content { ... on Issue { url number state } }
                      }
                    }
                  }
                }
              }' -f projectId="${PROJECT_ID}" -f scoreField="${SCORE_FIELD}" ${CURSOR_ARG})

            ALL_ITEMS=$(echo "${ALL_ITEMS}" | jq \
              --argjson page "$(echo "${PAGE}" \
                | jq '[.data.node.items.nodes[]]')" \
              '. + $page')

            HAS_NEXT=$(echo "${PAGE}" \
              | jq -r '.data.node.items.pageInfo.hasNextPage')
            if [[ "${HAS_NEXT}" != "true" ]]; then
              break
            fi
            CURSOR=$(echo "${PAGE}" \
              | jq -r '.data.node.items.pageInfo.endCursor')
          done

          # Find unscored open issues. Only issues in the configured org and
          # target repos can be dispatched, so filter them out here — before
          # WIP_LIMIT is applied — so undispatchable items don't occupy slots
          # and starve eligible issues.
          UNSCORED=$(echo "${ALL_ITEMS}" | jq -r \
            --arg org "${ORG}" \
            --argjson repos "${REPOS_JSON}" '
            [.[]
             | select(.content.state == "OPEN")
             | select(.content.url != null)
             | select(.content.url as $u
                      | [$repos[] as $r
                        | $u | startswith("https://github.com/" + $org + "/" + $r + "/issues/")]
                      | any)
             | select(.fieldValueByName == null)
             | {url: .content.url, number: .content.number}
            ]')

          # Find issues with stale scores. Checked on every poll so a steady
          # stream of new issues doesn't starve re-scoring.
          NOW_EPOCH=$(date +%s)
          STALE=$(echo "${ALL_ITEMS}" | jq -r \
            --arg org "${ORG}" \
            --argjson repos "${REPOS_JSON}" \
            --argjson threshold "${THRESHOLD_SECONDS}" \
            --argjson now "${NOW_EPOCH}" '
            [.[]
             | select(.content.state == "OPEN")
             | select(.content.url != null)
             | select(.content.url as $u
                      | [$repos[] as $r
                        | $u | startswith("https://github.com/" + $org + "/" + $r + "/issues/")]
                      | any)
             | {
                 url: .content.url,
                 number: .content.number,
                 updatedAt: .fieldValueByName.updatedAt
               }
             | select(.updatedAt != null)
             | select(($now - (.updatedAt | fromdateiso8601)) > $threshold)
            ]
            | sort_by(.updatedAt)')

          UNSCORED_COUNT=$(echo "${UNSCORED}" | jq 'length')
          STALE_COUNT=$(echo "${STALE}" | jq 'length')
          if [[ $((UNSCORED_COUNT + STALE_COUNT)) -eq 0 ]]; then
            echo "No unscored or stale issues found. Nothing to do."
            exit 0
          fi
          echo "Found ${UNSCORED_COUNT} unscored and ${STALE_COUNT} stale issue(s) to dispatch."

          # Dispatch up to WIP_LIMIT issues per poll, alternating between
          # unscored and stale (oldest-first) so neither queue starves the
          # other while the backlog is large.
          CANDIDATES=$(echo "${UNSCORED}" | jq \
            --argjson stale "${STALE}" --argjson limit "${WIP_LIMIT}" \
            '([.[:$limit], $stale[:$limit]]) | transpose | flatten | map(select(. != null)) | .[:$limit]')

          DISPATCHED=0
          FAILED=0

          for row in $(echo "${CANDIDATES}" | jq -c '.[]'); do
            ISSUE_URL=$(echo "${row}" | jq -r '.url')
            ISSUE_NUMBER=$(echo "${row}" | jq -r '.number')
            SOURCE_REPO="${ISSUE_URL#https://github.com/}"
            SOURCE_REPO="${SOURCE_REPO%%/issues/*}"

            # Skip repos with an active scoring run — re-dispatching an issue
            # whose run is still in progress would cancel it (the target
            # workflow cancels in-progress runs for the same issue) before it
            # writes the score. The API does not expose which issue a run was
            # dispatched for, so this skips the whole repo; on single-repo
            # boards that serializes scoring to roughly one issue per run
            # duration. The check fails closed: if the run list cannot be
            # fetched, the script exits rather than dispatching blindly.
            ACTIVE_RUNS=$(GH_TOKEN="${DISPATCH_TOKEN}" gh run list \
              --repo "${SOURCE_REPO}" --workflow "${WORKFLOW}" \
              --json status \
              --jq '[.[] | select(.status == "queued" or .status == "in_progress")] | length')
            if [[ "${ACTIVE_RUNS}" -gt 0 ]]; then
              echo "Skipping ${SOURCE_REPO}#${ISSUE_NUMBER} — scoring run already active."
              continue
            fi

            EVENT_PAYLOAD=$(jq -n \
              --arg url "${ISSUE_URL}" \
              --argjson number "${ISSUE_NUMBER}" \
              '{issue: {html_url: $url, number: $number}}')

            echo "Dispatching prioritize for ${SOURCE_REPO}#${ISSUE_NUMBER}..."

            if GH_TOKEN="${DISPATCH_TOKEN}" gh workflow run "${WORKFLOW}" \
              --repo "${SOURCE_REPO}" \
              -f event_type="schedule" \
              -f source_repo="${SOURCE_REPO}" \
              -f event_payload="${EVENT_PAYLOAD}" \
              -f project_number="${PROJECT_NUMBER}"; then
              DISPATCHED=$((DISPATCHED + 1))
            else
              echo "::warning::Failed to dispatch for ${ISSUE_URL}"
              FAILED=$((FAILED + 1))
            fi
          done

          echo "Dispatched ${DISPATCHED} prioritize run(s), ${FAILED} failed."
```

The scheduler dispatches `prioritize.yml` to `${SOURCE_REPO}` (the repo that
owns the issue), not to the scheduler's own repo. The `repos` input (passed
to `create-github-app-token` via the `repositories` field) must list every
target repo so the generated token has sufficient scope for cross-repo
dispatch.

On every poll, the scheduler also selects **stale scores** — issues whose
RICE Score field was last updated longer ago than
`stale_threshold` (default: 7 days). Stale issues are re-dispatched for
re-scoring, sorted oldest-first. Up to `wip_limit` issues are dispatched
per poll, alternating between unscored and stale so neither queue
starves the other.


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
- **`providers`, `openshell`, `skills`, and `host_files` live in forge sections**: This
  harness defines providers, openshell profiles, skills, and the forge-specific
  env file (`env/github/prioritize.env` / `env/gitlab/prioritize.env`) under
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

[`harness/prioritize.yaml`](https://github.com/fullsend-ai/agents/blob/main/harness/prioritize.yaml)
