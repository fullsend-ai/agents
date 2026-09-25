# Fix Agent

![Fix agent icon](icons/coder.png)

Review-feedback specialist that reads review comments on open PRs, implements targeted fixes, runs tests and linters, and commits the result.

## Setup

No additional setup is required beyond the standard fullsend configuration.

## How it helps

- Review feedback is addressed quickly — often before the reviewer checks back.
- Fixes are scoped to exactly what the review requested, reducing churn.
- Project CI failures caused by the PR are diagnosed and, when in scope, fixed in the same run.
- The iteration cap prevents the fix and [review](review.md) agents from looping indefinitely.

## Triggers

The fix agent runs automatically when the [review agent](review.md) submits a
"changes requested" review on a same-repo PR (fork PRs are blocked).

It can also be triggered manually with the `/fs-fix` command.

## Commands

| Command | Where | Effect |
|---------|-------|--------|
| `/fs-fix` | PR comment | Triggers the fix agent on the PR |
| `/fs-fix-stop` | PR comment | Disables the fix agent for this PR |

Requires write-level repository permission (admin, maintain, or write).

The `/fs-fix` command accepts optional free-text instructions after the
command. The text gives you direct control over what to fix:

- `/fs-fix` — fix whatever the [review agent](review.md) flagged
- `/fs-fix you forgot to update the docs here`
- `/fs-fix the error handling in processItem needs to distinguish between retryable and fatal errors`
- `/fs-fix address the concern raised in #42` — same-repo references work
  ([details](#links-and-urls-in-instructions))
- `/fs-fix rebase` / `/fs-fix rebase onto main` — rebase the PR onto its
  target branch ([details](#rebasing-a-stale-pr))
- `/fs-fix fix merge conflicts` — rebase onto the target and resolve conflicts
- `/fs-fix squash` / `/fs-fix squash these commits` — squash the whole PR
  into a single commit
  ([details](#squashing-or-redoing-fix-agent-commits))
- `/fs-fix redo from scratch` / `/fs-fix start over` — discard the
  contiguous fix-agent commits at HEAD and redo that work
  ([details](#squashing-or-redoing-fix-agent-commits))

`/fs-fix-stop` adds the `fullsend-no-fix` label to the PR, preventing any
further automatic fix runs. Manual `/fs-fix` commands still work.
Remove the label or use `/fs-fix` to re-engage.

## Control labels

| Label | Meaning |
|-------|---------|
| `fullsend-no-fix` | Prevents automatic fix runs on this PR. Applied by `/fs-fix-stop`. Manual `/fs-fix` commands are unaffected. |
| `needs-human` | The fix agent is approaching its iteration cap and needs human direction. Applied automatically when an automatic fix iteration reaches the warning threshold. |

## Configuration

See [Customizing with AGENTS.md](https://fullsend.sh/docs/guides/user/customizing-with-agents-md) and
[Customizing with Skills](https://fullsend.sh/docs/guides/user/customizing-with-skills).

### Variables

| Variable | Default | Effect |
|----------|---------|--------|
| `FULLSEND_FORGE` | `github` | Selects the forge platform (`github` or `gitlab`). Set automatically by the harness `forge` block. |

### Skill: `fix-review`

The fix agent uses the `fix-review` skill for its procedure, including project-CI inspection. Forge-specific recipes live in `skills/fix-review/github` and `skills/fix-review/gitlab`.

To cover a CI system other than GitHub Actions or GitLab CI, add a skill in `.agents/skills/` whose description names that system (or log inspection) and include it in your harness `skills:` array via `base:` composition. During CI inspection the agent only uses skills already injected for the run through that harness `skills:`/`base:` composition — it does not scan or load `SKILL.md` files from the PR's own working-tree checkout.

## How the agent works

The fix agent follows a similar pipeline to the [code agent](code.md), with an additional validation step:

1. **Pre-script** validates inputs and checks the iteration cap (preventing infinite fix loops).
2. **Sandbox** — the agent enumerates every review finding, inspects project CI, implements targeted fixes, and verifies them against tests and linters. Each finding gets a `fix`, `disagree`, or `defer` action.
3. **Validation loop** — the output is checked against a schema and against the `[category]` tags in the raw review body, with up to 2 retry iterations if the output is malformed or omits a finding.
4. **Post-script** pushes the commit and posts a summary comment on the PR.

A finding cannot be dropped silently. The validation loop re-reads the review body the agent received and rejects output whose `actions` do not cover every structured finding tag. A human `/fs-fix` instruction that narrows scope (for example `rebase`) still records the other findings as `defer`.

### Signed-off-by trailers

Same behaviour as the [code agent](code.md#signed-off-by-trailers): a trailer
the agent added is removed and the run continues, instead of being discarded.

This matters more on a fix run, because the commits being scanned are not
always the agent's. When the agent rebases, the scan widens to everything on
the PR branch since it diverged from the target — which on a human's PR
includes the human's own commits. Only commits the **agent authored** are
rewritten, so a contributor's DCO sign-off survives with its SHA intact; the
rebase is what makes this necessary, since it leaves the bot as committer on a
commit the human wrote.

The strip is recorded on the PR summary comment:

```text
_Removed a Signed-off-by trailer from 1 agent commit._
```

### Rebasing a stale PR

When a PR falls behind its target branch, comment `/fs-fix rebase` (or
`/fs-fix rebase onto main`, `/fs-fix fix merge conflicts`). The agent
rebases the PR branch onto the target; the post-script force-pushes with
`--force-with-lease`.

The agent rebases only when a human `/fs-fix` instruction asks for a rebase
or for resolving merge conflicts with the target. Automatic review-triggered
fixes do not rebase. An already-up-to-date branch is a no-op.

The agent does not push. History rewrite is local; the post-script is what
updates the remote PR branch.

### Squashing or redoing fix-agent commits

When a PR is ready to land as one commit, comment `/fs-fix squash` (or
`/fs-fix squash these commits`) to collapse the **whole PR** — not just
the fix agent's own commits — into a single commit. Comment
`/fs-fix redo from scratch` (or `/fs-fix start over`) to discard the
contiguous fix-agent commits at HEAD and redo that narrower slice of
work. The post-script force-pushes with `--force-with-lease`.

These two requests have different scopes:

- **Squash** targets the entire PR, from where it forked off the target
  branch through HEAD, regardless of who authored each commit along the
  way. The end result is one commit. When a plain `git reset --soft` and
  recommit isn't practical — most often because a squash was combined
  with a rebase and replaying several original commits onto the new base
  produces too many conflicts to resolve cleanly commit-by-commit — the
  agent may fall back to a "manual squash": reset to the merge base and
  re-implement the PR's net effect directly as a single commit, then
  re-verify it with tests and linters like any other fix. The commit
  message is written to describe everything that ended up in the PR, not
  just its original goal — including changes made along the way in
  response to review feedback.
- **Redo/reset** only discards and re-implements the contiguous suffix of
  commits the fix agent itself authored. Human-authored commits and the
  original code-agent commits below that suffix are preserved untouched.

If the redo/reset range cannot be determined — HEAD is not a fix-agent
commit, or ownership is mixed in a way that is ambiguous — the agent
fails closed and explains the blocker rather than rewriting. If squash
and redo are requested together, the agent also fails closed rather than
guessing which was meant.

Automatic review-triggered fixes do not squash or reset. Without an
explicit human request, the agent continues to append commits.

The agent does not push. History rewrite is local; the post-script is what
updates the remote PR branch.

### Input details

**Bot-triggered** (review agent requests changes):

| Input | Source | How it gets there |
|-------|--------|-------------------|
| Review body | Latest `CHANGES_REQUESTED` review from the review bot | Pre-fetched on the runner before the sandbox starts, injected as `review-body.txt` |
| PR diff | Forge-specific skill (GitHub: `gh pr diff`, GitLab: MR changes API) | Agent calls this to understand what code changed |
| Project CI | Forge-specific skill (GitHub: `gh pr checks` / `gh run view`, GitLab: MR pipelines API) | Agent inspects project jobs, excluding Fullsend dispatch |
| Repository checkout | Full repo at PR HEAD | Checked out on the runner, mounted into the sandbox |
| Repo conventions | `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md` | Read from the checkout inside the sandbox |

**Human-triggered** (`/fs-fix [instruction]`):

| Input | Source | How it gets there |
|-------|--------|-------------------|
| Human instruction | Free text after `/fs-fix` in the comment | Extracted by the workflow, passed as `HUMAN_INSTRUCTION` env var (up to 10,000 bytes) |
| PR diff | Forge-specific skill | Same as bot-triggered |
| Project CI | Forge-specific skill | Same as bot-triggered |
| Repository checkout | Full repo at PR HEAD | Same as bot-triggered |
| Repo conventions | `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md` | Same as bot-triggered |
| Review body (if any) | Prior review bot `CHANGES_REQUESTED` review | Still injected as `review-body.txt`, but human instruction takes precedence |

## Custom sandbox image

The fix agent shares the [code agent's sandbox image](code.md#custom-sandbox-image).
If your project uses a custom image, update the `image:` field in both
`harness/code.yaml` and `harness/fix.yaml`.

## What the agent acts on

**When triggered by a review:** the agent reads the review body, the PR diff,
project CI, and the full repository checkout.

**When triggered by `/fs-fix`:** the agent reads your instruction text, the PR
diff, project CI, the full repository checkout, and any prior review. When a
human instruction is present, it takes precedence over the review body.

### Project CI

The agent inspects the PR's project CI jobs during context gathering. It reads
available job logs and artifacts, classifies each failure, and reports the
diagnosis in the PR summary.

- **PR-caused failures** that fall within authorized scope are fixed in the
  same run. A narrow `/fs-fix` instruction (for example `rebase` or a single
  file edit) does not authorize extra CI-driven edits; the diagnosis is still
  reported.
- **Flaky or transient infrastructure failures** produce a recommendation that
  you rerun the affected jobs. The agent does not rerun jobs itself.
- **Unrelated failures** produce guidance to file an issue with the responsible
  owner. The agent does not change unrelated code to make those jobs pass.
- **Fullsend agent/dispatch workflows** (the `fullsend` shim, `notify-agent-sync`,
  and their `dispatch-*` jobs) are excluded. They are orchestration
  infrastructure, not project CI.

### What the agent does not read

This is worth being explicit about, because the fix agent's scope is narrower
than you might expect:

- **Inline PR review comments.** The agent reads the consolidated review body,
  not individual line-level comments. If you need the agent to act on a
  specific inline comment, copy the relevant text into a `/fs-fix` instruction.
- **Other PR comments.** General discussion comments on the PR are not part of
  the agent's input. Only the review body and the `/fs-fix` instruction are
  read.
- **Issue body.** The fix agent does not read the linked issue. It operates
  purely on the PR, review, and project-CI context.

### Links and URLs in instructions

The `/fs-fix` instruction text can contain URLs. Whether the agent can use them
depends on where the URL points:

| URL type | Works? | Why |
|----------|--------|-----|
| Same-repo issue or PR/MR (`#123` or full URL) | Yes | Resolved via the forge API (GitHub or GitLab) |
| Same-repo file or commit | Yes | Same mechanism |
| Cross-repo URL | No | Access is scoped to the target repo only |
| GitHub Gist | No | Not accessible from the agent environment |
| External URL (docs, pastebins, etc.) | No | External HTTP access is blocked |

GitHub may auto-shorten same-repo URLs in rendered comments (e.g.,
`https://github.com/org/repo/issues/2` becomes `#2`). GitLab does not
auto-shorten URLs but the full URL is preserved either way.

**If you need the agent to act on external context**, paste the relevant
content directly into the `/fs-fix` comment rather than linking to it. The
instruction supports multi-line text (up to 10,000 bytes).

### Iteration limits

The fix agent enforces iteration caps to prevent infinite review-fix loops:

- **Automatic:** up to 5 iterations per PR (configurable).
- **Manual (`/fs-fix`):** up to 10 total iterations per PR (configurable), shared
  across automatic and manual triggers.
- When an automatic run is approaching its cap, the agent applies the
  `needs-human` label.
- Each `/fs-fix` comment cancels any in-flight fix run for the same PR and
  starts a new one.

## Multi-forge support

The fix agent supports both GitHub and GitLab. The harness `forge` block
selects the platform at runtime via `FULLSEND_FORGE`. On GitHub, the agent
uses `gh` for API access; on GitLab, it uses `curl` against the REST API.
Scripts dispatch forge-specific operations through `fix-ops.lib.sh`, and
forge-specific skills provide the appropriate CLI recipes.

### GitLab-specific variables

| Variable | Description |
|----------|-------------|
| `PR_URL` | Full HTTPS URL of the merge request. Used to derive `GITLAB_HOST` and validate `REPO_FULL_NAME`. |
| `GITLAB_TOKEN` | Personal or project access token with `api` scope. |

### GitLab host validation

`gitlab-fix-ops.lib.sh` validates `GITLAB_HOST` against `CI_SERVER_HOST`,
a GitLab CI predefined variable set automatically by the runner. Validation
fails closed when `CI_SERVER_HOST` is not set. The GitLab profile in
`profiles/fullsend-gitlab-code.yaml` must also be updated to allow
connections to the host.

## Custom network policy

If this agent needs to reach hosts beyond the defaults, see the
[custom network policy guide](network-policy.md).

## Runtime support

Supported runtimes: **claude** (stable default), **pi** (experimental). No single-context fallback — full multi-step fix runs on both runtimes.

Effort: `high` (explicit in the harness; override per run with `fullsend run --effort` or `FULLSEND_EFFORT`, values `low`–`max`).

## Source

[`harness/fix.yaml`](https://github.com/fullsend-ai/agents/blob/main/harness/fix.yaml)
