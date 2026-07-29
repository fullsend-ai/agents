# Overriding Harness Configuration

Each agent in this repository has a harness configuration file in
`harness/<agent>.yaml`. These files define the agent's model, sandbox
image, policies, scripts, and skills. They are upstream defaults — do
not edit them directly.

To customize an agent's harness configuration for your project, create
an override file in your repository's `.fullsend/` directory.

## How it works

1. Create `.fullsend/<agent>.yaml` in your repository.
2. Set the `base:` field to the upstream harness via a SHA-pinned URL.
3. Add override fields (e.g., `image:`) alongside `base:` in the same
   file.
4. Register the agent source in `.fullsend/config.yaml`.

### Override file

```yaml
# .fullsend/<agent>.yaml
base: https://raw.githubusercontent.com/fullsend-ai/agents/<SHA>/harness/<agent>.yaml#sha256=<sha256sum>
image: ghcr.io/<org>/<repo>-<agent>:latest
```

The `base:` URL must point to a specific commit SHA in this repository,
with a `sha256` fragment for integrity verification. Override fields
are merged on top of the base configuration — you only need to specify
the fields you want to change.

To get the SHA and hash for an agent's harness file:

```bash
SHA=$(curl -s https://api.github.com/repos/fullsend-ai/agents/commits/main | jq -r '.sha')
HASH=$(curl -sL "https://raw.githubusercontent.com/fullsend-ai/agents/${SHA}/harness/<agent>.yaml" | sha256sum | awk '{print $1}')
echo "https://raw.githubusercontent.com/fullsend-ai/agents/${SHA}/harness/<agent>.yaml#sha256=${HASH}"
```

Replace `<agent>` with the agent name (e.g., `code`, `fix`, `review`,
`triage`, `retro`, `prioritize`, `scribe`).

### Config registration

Register the override in your `.fullsend/config.yaml`:

```yaml
# .fullsend/config.yaml
agents:
  - name: <agent>
    source: <agent>.yaml
```

The `source` path is relative to the `.fullsend/` directory.

## Available harness files

| Agent | Harness file | Common overrides |
|-------|-------------|------------------|
| [Code](code.md) | `harness/code.yaml` | `image` ([custom sandbox](code.md#custom-sandbox-image)) |
| [Fix](fix.md) | `harness/fix.yaml` | `image` (shares sandbox with code) |
| [Review](review.md) | `harness/review.yaml` | — |
| [Triage](triage.md) | `harness/triage.yaml` | — |
| [Retro](retro.md) | `harness/retro.yaml` | — |
| [Prioritize](prioritize.md) | `harness/prioritize.yaml` | — |
| [Scribe](scribe.md) | `harness/scribe.yaml` | — |

For the most common use case — providing a custom sandbox image for the
code and fix agents — see [Custom sandbox image](code.md#custom-sandbox-image).
