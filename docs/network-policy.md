# Custom network policy

The [code](code.md) and [fix](fix.md) agents run inside an OpenShell
sandbox that restricts outbound network access. The sandbox policy
controls two things:

- **Endpoints** — which hosts (and ports) a process can connect to.
- **Binaries** — which executables are allowed to use each endpoint.

A request is allowed only when both the destination host and the calling
binary match an entry in the policy. This means even if a host is
whitelisted, only the listed binaries can reach it — `curl`, for
example, is intentionally excluded to prevent raw HTTP access with
the injected GitHub token.

## Default allowlist

The default policy is defined in
[`policies/code.yaml`](../policies/code.yaml). It grants access to
Vertex AI, the GitHub API, package registries (npm, PyPI, Go modules),
and gitleaks releases. All endpoints use port 443 (HTTPS). See the
policy file for the full list of allowed hosts and binaries.

## When you need a custom policy

Some packages require network access to hosts not in the default
allowlist during installation or build — for example, a native addon
that downloads source from a host outside the default list, or a
package manager plugin that reaches an additional registry. When this
happens, the agent logs show a connection error (such as
`ECONNREFUSED` or `ETIMEDOUT`) during the install or build step.

## How to configure

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
[custom sandbox image](code.md#custom-sandbox-image)), add the `policy:`
field alongside the existing `image:` field.

**Step 3 — Update the fix agent harness (if used).** The
[fix agent](fix.md) uses its own policy file
([`policies/fix.yaml`](../policies/fix.yaml)) with similar but not
identical defaults. If your project uses the fix agent and needs the
same custom hosts, create a corresponding override and reference it
in `.fullsend/fix.yaml`.

## Troubleshooting

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
