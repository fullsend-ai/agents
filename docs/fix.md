# Fix Agent

![Fix agent icon](icons/coder.png)

Review-feedback specialist that reads review comments on open PRs, implements targeted fixes, runs tests and linters, and commits the result.

## How it helps

- Review feedback is addressed quickly — often before the reviewer checks back.
- Fixes are scoped to exactly what the review requested, reducing churn.
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

`/fs-fix-stop` adds the `fullsend-no-fix` label to the PR, preventing any
further automatic fix runs. Manual `/fs-fix` commands still work.
Remove the label or use `/fs-fix` to re-engage.

## What the agent acts on

**When triggered by a review:** the agent reads the review body, the PR diff,
and the full repository checkout.

**When triggered by `/fs-fix`:** the agent reads your instruction text, the PR
diff, the full repository checkout, and any prior review. When a human
instruction is present, it takes precedence over the review body.

### What the agent does not read

This is worth being explicit about, because the fix agent's scope is narrower
than you might expect:

- **Inline PR review comments.** The agent reads the consolidated review body,
  not individual line-level comments. If you need the agent to act on a
  specific inline comment, copy the relevant text into a `/fs-fix` instruction.
- **Other PR comments.** General discussion comments on the PR are not part of
  the agent's input. Only the review body and the `/fs-fix` instruction are
  read.
- **CI logs and check status.** The fix agent does not read GitHub Actions logs,
  check run output, or merge readiness indicators. It addresses review
  feedback, not CI failures. (The [code agent](code.md) handles CI failures
  during implementation.)
- **Issue body.** The fix agent does not read the linked issue. It operates
  purely on the PR and review context.

### Links and URLs in instructions

The `/fs-fix` instruction text can contain URLs. Whether the agent can use them
depends on where the URL points:

| URL type | Works? | Why |
|----------|--------|-----|
| Same-repo issue or PR (`#123` or full GitHub URL) | Yes | Resolved via the GitHub API |
| Same-repo file or commit | Yes | Same mechanism |
| Cross-repo GitHub URL | No | Access is scoped to the target repo only |
| GitHub Gist | No | Not accessible from the agent environment |
| External URL (docs, pastebins, etc.) | No | External HTTP access is blocked |

GitHub may auto-shorten same-repo URLs in rendered comments (e.g.,
`https://github.com/org/repo/issues/2` becomes `#2`), but the full URL is
preserved either way.

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

## Control labels

| Label | Meaning |
|-------|---------|
| `fullsend-no-fix` | Prevents automatic fix runs on this PR. Applied by `/fs-fix-stop`. Manual `/fs-fix` commands are unaffected. |
| `needs-human` | The fix agent is approaching its iteration cap and needs human direction. Applied automatically when an automatic fix iteration reaches the warning threshold. |

## Configuration

See [Customizing with AGENTS.md](https://fullsend.sh/docs/guides/user/customizing-with-agents-md) and
[Customizing with Skills](https://fullsend.sh/docs/guides/user/customizing-with-skills).

### Variables

None.

## How the agent works

The fix agent follows a similar pipeline to the [code agent](code.md), with an additional validation step:

1. **Pre-script** validates inputs and checks the iteration cap (preventing infinite fix loops).
2. **Sandbox** — the agent reads each review finding, implements targeted fixes, and verifies them against tests and linters.
3. **Validation loop** — the output is checked against a schema, with up to 2 retry iterations if the output is malformed.
4. **Post-script** pushes the commit and posts a summary comment on the PR.

### Input details

**Bot-triggered** (review agent requests changes):

| Input | Source | How it gets there |
|-------|--------|-------------------|
| Review body | Latest `CHANGES_REQUESTED` review from the review bot | Pre-fetched on the runner before the sandbox starts, injected as `review-body.txt` |
| PR diff | `gh pr diff` inside the sandbox | Agent calls this to understand what code changed |
| Repository checkout | Full repo at PR HEAD | Checked out on the runner, mounted into the sandbox |
| Repo conventions | `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md` | Read from the checkout inside the sandbox |

**Human-triggered** (`/fs-fix [instruction]`):

| Input | Source | How it gets there |
|-------|--------|-------------------|
| Human instruction | Free text after `/fs-fix` in the comment | Extracted by the workflow, passed as `HUMAN_INSTRUCTION` env var (up to 10,000 bytes) |
| PR diff | `gh pr diff` inside the sandbox | Same as bot-triggered |
| Repository checkout | Full repo at PR HEAD | Same as bot-triggered |
| Repo conventions | `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md` | Same as bot-triggered |
| Review body (if any) | Prior review bot `CHANGES_REQUESTED` review | Still injected as `review-body.txt`, but human instruction takes precedence |

## Source

[`harness/fix.yaml`](../harness/fix.yaml)
