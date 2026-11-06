# CLAUDE.md

Project rules and instructions live in [AGENTS.md](AGENTS.md). Read that file now — it is the single source of truth for all agent-facing guidance in this repo.

## Build and validation

### Script bundling

Shell scripts under `scripts/` use a source/bundle architecture. The
`.src.sh` files are the editable sources; the corresponding `.sh` files
are generated artifacts produced by the bundler. After modifying any
`.src.sh` file (or any `scripts/lib/*.lib.sh` library), rebuild the
bundles:

```bash
make script-build
```

Both the source `.src.sh` and its generated `.sh` counterpart must be
staged and committed together. The `check-bundle` pre-commit hook
verifies that committed bundles match the output of `make script-build`
and will reject stale bundles.

### Pre-commit

Before committing, run pre-commit on all files and fix every violation:

```bash
pre-commit run --all-files
```

This includes info-level shellcheck warnings — the repo's shellcheck
configuration only excludes SC1091, SC2001, and SC2016 (see
`.pre-commit-config.yaml`). All other codes, including SC2030, SC2031,
SC2034, and SC2153, are blocking.

If shellcheck flags a variable name clash (e.g., SC2153 for
`PR_NUMBER` vs `pr_number`), add a targeted disable comment above the
flagged line rather than renaming the variable:

```bash
# shellcheck disable=SC2153
```

### Tests

Run the full test suite with:

```bash
make test
```
