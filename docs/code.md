# Code Agent

<img src="icons/coder.png" alt="Code agent icon" width="80">

Implementation specialist that reads triaged GitHub issues, implements fixes or features following repository conventions, runs tests and linters, and commits to a local feature branch.

## How the agent works

The code agent follows a three-phase pipeline: pre-script, sandbox execution, post-script.

1. **Pre-script** validates inputs on the runner before sandbox creation.
2. **Sandbox** — the agent reads the issue, explores the codebase, writes code, runs tests and linters, and commits locally. It has no network access to push or create PRs (enforced by `disallowedTools`).
3. **Post-script** runs on the runner with elevated permissions: it performs protected-path checks, secret scanning, pushes the branch, and creates the PR.

This separation ensures the agent never has direct write access to the repository.

## How it helps

- Triaged issues can go from "ready" to "PR open" without human involvement.
- Implementation follows repo conventions because the agent reads existing code, tests, and linter configs before writing.
- The sandboxed execution model means a misbehaving agent cannot push arbitrary code — the post-script gates everything.

## Commands

| Command | Where | Effect |
|---------|-------|--------|
| `/fs-code` | Issue comment | Triggers the code agent on the issue |

The `/fs-code` command does not accept arguments. It can only be used on issues
(not PRs). The code agent is also triggered automatically when the
`ready-to-code` label is applied to an issue.

## Control labels

| Label | Meaning |
|-------|---------|
| `ready-to-code` | Triggers the code agent. Applied by the [triage](triage.md) post-script for low-risk categories (bug, documentation, performance), or manually by a human for feature work after prioritization. |

## Configuration and extension

Detailed harness-level customization is coming soon. Today, the best way to
influence how the code agent behaves on your repository is by adding
instructions and skills to the repo itself. See
[Customizing Agents with Skills](../guides/user/customizing-with-skills.md).

## Source

[`internal/scaffold/fullsend-repo/harness/code.yaml`](../../internal/scaffold/fullsend-repo/harness/code.yaml)
