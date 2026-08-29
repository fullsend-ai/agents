# Code Agent

![Code agent icon](icons/coder.png)

Implementation specialist that reads triaged issues, implements fixes or features following repository conventions, runs tests and linters, and commits to a local feature branch.

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
| `CODE_ALLOWED_TARGET_BRANCHES` | Restricts which branches the code agent can target when pushing. The post-code script reads it from the runner when present and validates the agent's chosen target branch before pushing. It is never injected into the sandbox. | Repo default branch (auto-detected via forge API; falls back to `main`) | Comma-separated branch names (e.g. `main,develop`) or `*` for any branch |
| `FULLSEND_FORGE` | Forge platform. Set automatically by the harness overlay `env` section (matched via `when: 'runtime.forge == "<platform>"'`). | (set by harness) | `"github"`, `"gitlab"` |
| `FULLSEND_TRACKER` | Source tracker for the work item (matches triage convention). When set to `"jira"`, the code agent reads issue context from `/sandbox/workspace/.issue-context.json` (prepared by the Jira pre-script) instead of calling forge APIs. Set by the Jira-source overlay in `harness/code.yaml`. | (unset — forge-native) | `"jira"` |
| `ISSUE_NUMBER` | Numeric source issue identifier used when the source tracker is the target forge. It is optional for external-tracker runs because that work-item key is not a target-forge issue number. | (set by forge-native workflows) | Positive integer |
| `CODE_AUTO_MERGE` | Set to `"true"` to enable auto-merge on PRs/MRs created by the code agent. On GitHub, uses `gh pr merge --auto`; on GitLab, uses `merge_when_pipeline_succeeds`. Requires branch protection with required reviews or status checks on the target branch. Read directly from the runner environment (not declared in `env.runner`). | `""` (disabled) | `"true"` to enable |
| `CODE_AUTO_MERGE_METHOD` | Merge method for auto-merge: `"squash"`, `"rebase"`, or `"merge"`. When unset, auto-detected from the repo's allowed merge methods (prefers squash). Omitted automatically when the target branch uses a merge queue. Ignored unless `CODE_AUTO_MERGE` is `"true"`. | Auto-detected (prefers squash) | `"squash"`, `"rebase"`, `"merge"` |

## How the agent works

The code agent follows a three-phase pipeline: pre-script, sandbox execution, post-script.

1. **Pre-script** validates inputs on the runner before sandbox creation. It also checks for open PRs linked to the issue.
2. **Sandbox** — the agent reads the issue, explores the codebase, writes code, runs tests and linters, and commits locally. It has restricted network access (enforced by OpenShell).
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
policy ([`policies/base.yaml`](../policies/base.yaml)) and network
profiles ([`profiles/`](../profiles/)):

| Requirement | Detail |
|-------------|--------|
| **Base image** | Extend from `ghcr.io/fullsend-ai/fullsend-code:latest` to inherit the agent runtime, pre-installed tools, and security scanning binaries. |
| **User/group** | The sandbox runs as `sandbox:sandbox`. Installed tools must be executable by this user. |
| **Filesystem layout** | The working directory is `/sandbox/workspace`. Read-write access is limited to `/sandbox` and `/tmp`. System paths (`/usr`, `/lib`, `/etc`) are read-only at runtime — install packages at build time, not in an entrypoint. |
| **Network access** | The sandbox restricts outbound network to specific hosts and binaries (Vertex AI, forge API, package registries). Arbitrary HTTP access is blocked. Tools that phone home at startup may fail. |
| **Required binaries** | `git`, `scan-secrets`, `pre-commit` must remain on `PATH`. On GitHub, `gh` is also required; on GitLab, `curl` is used instead. Do not remove or shadow them. |

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
CI runners:

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

## Multi-forge support

The code agent supports both GitHub and GitLab, and can also consume
work items from Jira. The harness uses `overlays:` with CEL `when:`
expressions to configure platform-specific policies, skills, and env
vars. Key differences from single-forge setup:

- **`FULLSEND_FORGE`** is required. Set automatically by the matching
  forge overlay's `env` section (`"github"` or `"gitlab"`).
- **`ISSUE_URL`** replaces `GITHUB_ISSUE_URL` in scripts. The
  per-forge env file (`env/github/code.env` or `env/gitlab/code.env`)
  maps the platform-specific variable to `ISSUE_URL`.
- **Jira-source overlay** — when the work item originates from Jira
  (`event.source.system == "jira"`), a dedicated overlay fetches the
  issue via `fullsend issues get --tracker jira` on the runner and
  copies the context into the sandbox. Jira credentials stay on the
  runner. The Jira overlay composes with the target-forge overlay
  (GitHub or GitLab) via merge-all-matching.
- **External work-item identity** — when the source tracker differs from the
  target forge, the code agent derives the key from `FULLSEND_WORK_ITEM_URL`.
  Branch names and PR text use that key and link the source URL; they do not
  invent a numeric target-forge issue reference. Target-forge issue comments
  and assignee lookup are skipped when no such issue exists.
- **Policy** is `policies/base.yaml` for all forges. Network access is
  provided by profiles (`fullsend-gitlab-code` for GitLab). Custom
  harnesses using `base:` composition should override at the forge level
  if needed.
- **GitLab uses `curl`** instead of `gh` for API access. The GitLab
  profile (`fullsend-gitlab-code`) allows `curl` for GitLab API
  endpoints only.
- **GitLab host validation** — `forge_validate_issue_url` validates
  the host against `CI_SERVER_HOST`, a GitLab CI predefined variable
  set automatically by the runner. Validation fails closed when
  `CI_SERVER_HOST` is not set. The GitLab profile in
  `profiles/fullsend-gitlab-code.yaml` must also be updated.

## Custom network policy

If this agent needs to reach hosts beyond the defaults, see the
[custom network policy guide](network-policy.md).

## Runtime support

Supported runtimes: **claude** (stable default), **pi** (experimental). No single-context fallback — full multi-step implementation runs on both runtimes.

Effort: `high` (explicit in the harness; override per run with `fullsend run --effort` or `FULLSEND_EFFORT`, values `low`–`max`).

## Source

[`harness/code.yaml`](../harness/code.yaml)
