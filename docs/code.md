# Code Agent

![Code agent icon](icons/coder.png)

Implementation specialist that reads triaged GitHub issues, implements fixes or features following repository conventions, runs tests and linters, and commits to a local feature branch.

## How it helps

- Triaged issues can go from "ready" to "PR open" without human involvement.
- Implementation follows repo conventions because the agent reads existing code, tests, and linter configs before writing.
- The agent cannot push arbitrary code — all changes are gated before reaching the repository.

## Triggers

The code agent runs automatically when the `ready-to-code` label is applied to an issue.

It can also be triggered manually with the `/fs-code` command.

## Commands

| Command | Where | Effect |
|---------|-------|--------|
| `/fs-code` | Issue comment | Triggers the code agent on the issue |

Requires write-level repository permission (admin, maintain, or write).

The `/fs-code` command accepts an optional `--force` flag. It can only be used
on issues (not PRs).

## Control labels

| Label | Meaning |
|-------|---------|
| `ready-to-code` | Triggers the code agent. Applied by the [triage](triage.md) agent for low-risk categories (bug, documentation, performance), or manually by a human for feature work after prioritization. |
| `ready-for-review` | Applied after a PR is pushed. In per-repo installs, triggers the [review agent](review.md) when applied to a PR. Also marks workflow state for humans and the [retro agent](retro.md). |

## Configuration

See [Customizing with AGENTS.md](https://fullsend.sh/docs/guides/user/customizing-with-agents-md) and
[Customizing with Skills](https://fullsend.sh/docs/guides/user/customizing-with-skills).

### Variables

None.

## How the agent works

The code agent follows a three-phase pipeline: pre-script, sandbox execution, post-script.

1. **Pre-script** validates inputs on the runner before sandbox creation. It also checks for open PRs linked to the issue.
2. **Sandbox** — the agent reads the issue, explores the codebase, writes code, runs tests and linters, and commits locally. It has no network access (enforced by OpenShell).
3. **Post-script** runs on the runner: it performs protected path checks, secret scanning, pre-commit checks, pushes the branch, creates the PR, and best-effort assigns the PR to a human owner (latest `/fs-code` invoker, else issue assignee, else issue author).

This separation ensures the agent never has direct write access to the repository.

## Source

[`harness/code.yaml`](../harness/code.yaml)
