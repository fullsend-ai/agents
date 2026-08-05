# Code Agent

![Code agent icon](icons/coder.png)

Implementation specialist that reads triaged GitHub issues, implements fixes or features following repository conventions, runs tests and linters, and commits to a local feature branch.

## Setup

No additional setup is required beyond the standard fullsend configuration.

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
| `CODE_ALLOWED_TARGET_BRANCHES` | Restricts which branches the code agent can target when pushing. The post-code script validates the agent's chosen target branch against this variable before pushing. Set via `env.runner` in `harness/code.yaml` (never injected into the sandbox). | Repo default branch (auto-detected via GitHub API; falls back to `main`) | Comma-separated branch names (e.g. `main,develop`) or `*` for any branch |

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

### PR assignee resolution

The post-script assigns a human owner to each PR it creates. When no human candidate is found,
the PR is unassigned. The idea behind this is that the assignee takes care of the PR as it cares
about its contents.

The precedence is as follows:

1. `/fs-code` invoker.
2. First assignee of the issue.
3. Issue author.

**Note**: bots are filtered (`*[bot]`, `app/*`, `dependabot`). The resolution logic lives in
[`scripts/lib/pr-assignee.lib.sh`](../scripts/lib/pr-assignee.lib.sh).

## Custom network policy

The code and [fix](fix.md) agents run inside an OpenShell sandbox that
restricts outbound network access. The sandbox policy controls two
things:

- **Endpoints** — which hosts (and ports) a process can connect to.
- **Binaries** — which executables are allowed to use each endpoint.

A request is allowed only when both the destination host and the calling
binary match an entry in the policy. This means even if a host is
whitelisted, only the listed binaries can reach it — `curl`, for
example, is intentionally excluded to prevent raw HTTP access with
the injected GitHub token.

### Default allowlist

The default policy is defined in
[`policies/code.yaml`](../policies/code.yaml). It grants access to
Vertex AI, the GitHub API, package registries (npm, PyPI, Go modules),
and gitleaks releases. All endpoints use port 443 (HTTPS). See the
policy file for the full list of allowed hosts and binaries.

### When you need a custom policy

Some packages require network access to hosts not in the default
allowlist during installation or build — for example, a native addon
that downloads source from a host outside the default list, or a
package manager plugin that reaches an additional registry. When this
happens, the agent logs show a connection error (such as
`ECONNREFUSED` or `ETIMEDOUT`) during the install or build step.

### How to configure

Create a custom policy file in your repository that extends the
default policy with additional endpoints. The file follows the same
YAML structure as [`policies/code.yaml`](../policies/code.yaml).

**Step 1 — Create the policy file.** Copy
[`policies/code.yaml`](../policies/code.yaml) and add your endpoints
to the `network_policies` section. Remove any default entries your
project does not need (e.g., Go registry entries for a Node-only
project). Then append a new policy block for the additional host:

```yaml
# .fullsend/policies/code.yaml
---
version: 1

filesystem_policy:
  # ... (keep the defaults from policies/code.yaml)
landlock:
  # ...
process:
  # ...

network_policies:
  # Keep the default policies your project needs (vertex_ai,
  # github_api, gitleaks_releases, package_registries).
  # See policies/code.yaml for the full structure.
  vertex_ai:
    # ...
  github_api:
    # ...
  package_registries:
    # ...

  # ── Your additions ────────────────────────────────────────
  custom_hosts:
    name: custom-hosts
    endpoints:
      - host: "example.com"
        port: 443
        protocol: rest
        enforcement: enforce
        access: read-only
    binaries:
      - path: "**/node"
      - path: "**/npm"
```

**Step 2 — Reference the policy in your custom harness.** Add the
`policy:` field to your `.fullsend/code.yaml`:

```yaml
# .fullsend/code.yaml
base: https://raw.githubusercontent.com/fullsend-ai/agents/<SHA>/harness/code.yaml#sha256=<sha256sum>
policy: policies/code.yaml
```

If you already have a custom harness (e.g., for a
[custom sandbox image](#custom-sandbox-image)), add the `policy:` field
alongside the existing `image:` field.

**Step 3 — Update the fix agent harness (if used).** The
[fix agent](fix.md) uses its own policy file
([`policies/fix.yaml`](../policies/fix.yaml)) with similar but not
identical defaults. If your project uses the fix agent and needs the
same custom hosts, create a corresponding override and reference it
in `.fullsend/fix.yaml`.

### Troubleshooting

When a package install fails due to a blocked host, look for connection
errors in the agent logs. Common patterns:

- `ECONNREFUSED` or `ETIMEDOUT` on a host that is not in the policy
- `npm ERR! network` followed by a hostname
- `pip` or `go get` failures referencing an external download URL

To identify which host to add:

1. Find the failing command in the agent log output.
2. Look for the hostname in the error message (e.g.,
   `codeload.github.com`).
3. Add the host to your custom policy under an appropriate
   `network_policies` entry with the binaries that need access.

When adding endpoints, use `access: read-only` unless the endpoint
requires write access. Keep the `enforcement: enforce` and
`protocol: rest` fields. Use `port: 443` for HTTPS endpoints.

## Source

[`harness/code.yaml`](../harness/code.yaml)
