# Code Agent

![Code agent icon](icons/coder.png)

Implementation specialist that reads triaged GitHub issues, implements fixes or features following repository conventions, runs tests and linters, and commits to a local feature branch.

## How it helps

- Triaged issues can go from "ready" to "PR open" without human involvement.
- Implementation follows repo conventions because the agent reads existing code, tests, and linter configs before writing.
- The agent cannot push arbitrary code — all changes are gated before reaching the repository.

## Triggers

The code agent is triggered when the `ready-to-code` label is applied to an issue, or via the `/fs-code` command.

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
| `ready-to-code` | Triggers the code agent. Applied by the [triage](triage.md) agent for low-risk categories (bug, documentation, performance), or manually by a human for feature work after prioritization. Not applied when the triage result sets `requires_workflow_changes`, since the code agent cannot modify workflow files. |
| `ready-for-review` | Applied by the code agent after pushing a PR. In per-repo installs, triggers the [review agent](review.md) when applied to a PR. Also marks workflow state for humans and the [retro agent](retro.md). |

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

## Custom sandbox image

The code agent runs inside a sandbox container built from the universal
`ghcr.io/fullsend-ai/fullsend-code:latest` image. This image ships common
build tools (Go, Python, Node 22, npm, pip, git, pre-commit, gitleaks,
shellcheck, jq) but cannot cover every project's toolchain. If your
project requires tools that are not pre-installed — for example a
different Node version, pnpm, Rust, or project-specific CLI tools — you
need a custom image.

### When you need a custom image

- The project's contributing guide requires a tool that is not in the
  universal image (e.g., Node 24, pnpm, Bazel, Rust toolchain).
- Tests or linters depend on system packages not present in the sandbox.
- The agent logs show it cannot run the project's test or lint command
  because a required binary is missing.

### Image requirements

A custom image must satisfy the constraints enforced by the sandbox
policy ([`policies/code.yaml`](../policies/code.yaml)):

| Requirement | Detail |
|-------------|--------|
| **Base image** | Extend from `ghcr.io/fullsend-ai/fullsend-code:latest` to inherit the agent runtime, pre-installed tools, and security scanning binaries. |
| **User/group** | The sandbox runs as `sandbox:sandbox`. Installed tools must be executable by this user. |
| **Filesystem layout** | The working directory is `/sandbox/workspace`. Read-write access is limited to `/sandbox` and `/tmp`. System paths (`/usr`, `/lib`, `/etc`) are read-only at runtime — install packages at build time, not in an entrypoint. |
| **Network access** | The sandbox restricts outbound network to specific hosts and binaries (Vertex AI, GitHub API, package registries). Arbitrary HTTP access is blocked. Tools that phone home at startup may fail. |
| **Required binaries** | `git`, `gh`, `scan-secrets`, `pre-commit` must remain on `PATH`. Do not remove or shadow them. |

### How to build

Create a `Dockerfile` in your project repository that extends the base
image and adds project-specific tooling:

```dockerfile
FROM ghcr.io/fullsend-ai/fullsend-code:latest

# Example: install Node 24 and pnpm
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g pnpm

# Example: install a Rust toolchain
# RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
#     sh -s -- -y --default-toolchain stable
# ENV PATH="/root/.cargo/bin:${PATH}"
```

Build and push the image to a container registry accessible from your
GitHub Actions runners:

```bash
docker build -t ghcr.io/<org>/<repo>-code:latest .
docker push ghcr.io/<org>/<repo>-code:latest
```

### How to configure

Override the `image` field in your repository's `harness/code.yaml` to
point to the custom image:

```yaml
image: ghcr.io/<org>/<repo>-code:latest
```

The same field exists in `harness/fix.yaml` (the [fix agent](fix.md)
shares the sandbox image). Update both if your project uses the fix
agent.

## Source

[`harness/code.yaml`](../harness/code.yaml)
