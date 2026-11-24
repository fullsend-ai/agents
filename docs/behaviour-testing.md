# Behaviour testing

The live behaviour suite runs only against the fullsend `dev` preview driver.
It never uses the durable stage mint.

## When each suite runs

Pull requests get the behaviour scenarios from the `behaviour-github-emulator`
check (see [On the GitHub emulator](#on-the-github-emulator)), which needs no
secrets. The live `behaviour` suite (`behaviour-tests.yml`) takes a dev pool
organization, real models and real App installations, so it runs only on the events below:

| Event | Live `behaviour` suite |
|---|---|
| Pull request (same repository or fork) | Skipped. The trigger stays, so the check still reports, as skipped |
| `/ok-to-test <sha>` | Not run. `Functional Tests` runs as before |
| `/ok-to-test <sha> live` | Runs on that sha and reports the check `behaviour-live` |
| Merge queue, push to `main`, `workflow_dispatch` | Runs |

`behaviour` and `behaviour-live` are not required checks. The required checks
(`script-test`, `test`, `commit-lint`, `skillsaw` and
`behaviour-github-emulator`) keep reporting on pull requests.

## Run the live suite on a pull request

Use this when a pull request needs the live suite before it reaches the merge
queue: for example, a change to a scenario that needs a real model, such as
`review/custom-persona.feature`, or to the live suite's own setup.

You need write access (Write role or above) to the repository. Otherwise, ask
someone who has it: a comment from anyone else does not start the run.

1. Review the latest push to the pull request.
2. Comment on the pull request:

   ```text
   /ok-to-test <full 40-character sha of the latest push> live
   ```

3. Wait for the `behaviour-live` check on that commit. `Functional Tests` also
   runs and reports `functional-tests-complete`, as for a plain
   `/ok-to-test <sha>`.

`live` passes the same gate as `/ok-to-test <sha>`:

- the commenter has write, maintain or admin access;
- the comment is read from the API by id, and the command is on its first
  line;
- the pull request head must be the named sha, so a later push needs a new
  comment;
- the workflow and the gate come from the default branch.

`live` is lowercase and is the only word allowed after the sha.

## Local checks

The suite is build-tagged and imports fullsend's live runner. The CI workflow
prepares a temporary module file that points at the exact fullsend checkout
before running it. Because the shared package still exposes internal test-only
module edges to Go's dependency loader, local checks should use the same
temporary modfile setup:

```bash
fullsend_checkout=/path/to/fullsend
modfile="$(mktemp --suffix=.mod)"
sumfile="${modfile%.mod}.sum"
cp go.mod "$modfile"
: > "$sumfile"
go mod edit -modfile="$modfile" \
  -replace="github.com/fullsend-ai/fullsend=${fullsend_checkout}"
go mod edit -modfile="$modfile" \
  -replace="github.com/fullsend-ai/fullsend/internal/mintcore=${fullsend_checkout}/internal/mintcore"
go mod tidy -modfile="$modfile"
FULLSEND_CHECKOUT="$fullsend_checkout" \
  go test -mod=readonly -modfile="$modfile" -tags behaviour -run '^$' \
  -exec "$PWD/scripts/run-behaviour-test-exec.sh" ./behaviour
```

The live command is:

```bash
make behaviour-test
```

When `FULLSEND_CHECKOUT` is set, the test process runs from that checked-out
fullsend source tree. This is required for vendoring when the suite is run from
the agents module.

The CI workflow generates a temporary config preset and passes it as
`BEHAVIOUR_CONFIG_PRESET`. Fullsend installs that document as
`.fullsend/config.base.yaml`, then composes the normal per-repository overlay.
Each agent source is pinned with a SHA-256 URL fragment to the merge group
head, the pushed or dispatched commit, or the sha a `/ok-to-test <sha> live` comment
authorized, and the preset allow-lists that source repository.

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
for org in halfsend-{01..22}; do
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

## On the GitHub emulator

The `behaviour-github-emulator` workflow runs this suite against the
[GitHub emulator](https://github.com/fullsend-ai/github-emulator), on hosted
VMs. Every pull request runs it, forks included, with no repository secrets
and no `/ok-to-test`.

- The job builds fullsend `main` and reads the emulator pin from that
  checkout, so both repositories run the same emulator release. A dispatch
  input can name another fullsend revision.
- The job splits the suite into the shards listed in `behaviour/shards.txt`.
  Each line reads `<shard> <workers> <runners> <feature[:line]>...`, with
  feature paths relative to `behaviour/`. Each shard sets `BEHAVIOUR_FEATURES`
  to its space-separated godog paths, for example `features/fix.feature` or
  `features/triage.feature:3`. When `BEHAVIOUR_FEATURES` is unset or empty,
  the suite runs every feature.
- A feature that is not listed in `behaviour/shards.txt` does not run on the
  emulator, so it does not run on pull requests. No test checks that every
  feature is listed, so add each new feature to a shard. The exception is a scenario that needs a real model, such as
  `review/custom-persona.feature`, which runs only in the live suite; the
  comment at the top of `shards.txt` says why.
- The live suite (`behaviour-tests.yml`) runs in the merge queue, on push to
  `main`, on `workflow_dispatch`, and on a pull request after
  `/ok-to-test <sha> live` (see [When each suite runs](#when-each-suite-runs)).
  It is the only place scenarios that need a real model run: today, the
  custom-persona scenario behind the `review-skill-overrides` capability.

If the check fails, see
[When the check fails](https://github.com/fullsend-ai/fullsend/blob/main/docs/guides/dev/behaviour-testing.md#when-the-check-fails)
in fullsend's behaviour testing guide. In this repository, each shard uploads
its logs as the artifact `behaviour-github-emulator-logs-<shard>`, and the
shard names come from `behaviour/shards.txt`.

To run the same job locally, follow
[Running against a GitHub emulator](https://github.com/fullsend-ai/fullsend/blob/main/docs/guides/dev/behaviour-testing.md#running-against-a-github-emulator)
in fullsend's behaviour testing guide, with
`BT_SUITE=agents AGENTS_DIR=<this checkout>`.
