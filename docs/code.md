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

| Variable | Description | Default | Valid values |
|----------|-------------|---------|--------------|
| `CODE_ALLOWED_TARGET_BRANCHES` | Restricts which branches the code agent can target when pushing. The post-code script validates the agent's chosen target branch against this variable before pushing. Set via `runner_env` in `harness/code.yaml` (never injected into the sandbox). | Repo default branch (auto-detected via GitHub API; falls back to `main`) | Comma-separated branch names (e.g. `main,develop`) or `*` for any branch |

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

A custom image must work within the constraints enforced by the sandbox
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

Create a custom harness for the code agent at `.fullsend/code.yaml`
overriding the image with your's:

```yaml
# .fullsend/code.yaml
base: https://raw.githubusercontent.com/fullsend-ai/agents/<SHA>/harness/code.yaml#sha256=<sha256sum>
image: ghcr.io/<org>/<repo>-code:latest
```

To get the `<SHA>` and `<sha256sum>` values use:

```bash
SHA=$(curl -s https://api.github.com/repos/fullsend-ai/agents/commits/main | jq -r '.sha')
HASH=$(curl -sL "https://raw.githubusercontent.com/fullsend-ai/agents/${SHA}/harness/code.yaml" | sha256sum | awk '{print $1}')
echo "https://raw.githubusercontent.com/fullsend-ai/agents/${SHA}/harness/code.yaml#sha256=${HASH}"
```

And then reference that harness in your `.fullsend/config.yaml`:

```yaml
# .fullsend/config.yaml

agents:
  - name: code
    source: code.yaml
```

The same field exists in `harness/fix.yaml` (the [fix agent](fix.md)
shares the sandbox image). Update both if your project uses the fix
agent.

## Source

[`harness/code.yaml`](../harness/code.yaml)
