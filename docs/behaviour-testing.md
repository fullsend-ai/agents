# Behaviour testing

The live behaviour suite runs only against the fullsend `dev` preview driver.
It never uses the durable stage mint.

## Local checks

The suite is build-tagged and imports fullsend's live runner. The CI workflow
prepares a temporary module file that points at the exact fullsend checkout
before running it. With that same setup, a credential-free compile is:

```bash
go test -tags behaviour -run '^$' -exec ./scripts/run-behaviour-test-exec.sh ./behaviour
```

The live command is:

```bash
make behaviour-test
```

When `FULLSEND_CHECKOUT` is set, the test process runs from that checked-out
fullsend source tree. This is required for vendoring when the suite is run from
the agents module.

## CI credentials

The `dev` GitHub Environment on `fullsend-ai/agents` must contain these
agent-specific secrets:

```text
AGENTS_BT_E2E_GCP_WIF_PROVIDER
AGENTS_BT_E2E_GCP_SERVICE_ACCOUNT
AGENTS_BT_E2E_GCP_PROJECT_ID
AGENTS_BT_CLOUDFLARE_ACCOUNT_ID
AGENTS_BT_CLOUDFLARE_API_TOKEN
AGENTS_BT_FULLSEND_PEM
AGENTS_BT_TRIAGE_PEM
AGENTS_BT_CODER_PEM
AGENTS_BT_REVIEW_PEM
AGENTS_BT_RETRO_PEM
AGENTS_BT_PRIORITIZE_PEM
AGENTS_BT_ACTOR_WRITE_PAT
AGENTS_BT_ACTOR_TRIAGE_PAT
AGENTS_BT_ACTOR_OUTSIDER_PAT
```

These are deliberately separate from existing fullsend `TEST_*`, Cloudflare,
GCP, PEM, and PAT credentials. Do not rotate or overwrite an existing value.
Private keys and PATs should be newly created alongside existing credentials;
the workflow maps the new names to the environment variable names consumed by
the shared fullsend driver.

## Dev pool authorization

The cross-org e2e role must authorize the agents repository in every dev pool
organization while retaining the existing fullsend caller:

```bash
# Run from an exact fullsend checkout with the operator credentials required
# by the fullsend admin command.
for org in halfsend-{01..12}; do
  go run ./cmd/fullsend admin foreign allow \
    --org "$org" \
    --role e2e \
    --caller fullsend-ai/agents
done
```

Verify each organization with:

```bash
go run ./cmd/fullsend admin foreign list --org halfsend-01
```

The test Apps and actor permissions must also be present on the dev pool
organizations. Stage organization permissions are intentionally out of scope.
