# Skillsaw self-check

Referenced from `SKILL.md` step 7c.

When the diff touches a skillsaw-linted path — `agents/`, `skills/`,
`commands/`, or top-level `AGENTS.md`/`CLAUDE.md` — and the repo has
skillsaw (`.skillsaw.yaml`, or a `make lint` target that runs it), run
it locally **before** finalizing the commit. Do not leave a
context-budget warning for CI, review, or a human `/fs-fix` to catch.

```bash
# Prefer the repo Makefile target (pins the version from .skillsaw.yaml):
make lint

# If there is no Makefile target, pin to the version in .skillsaw.yaml:
uvx skillsaw@<pinned-version> --strict
```

`--strict` makes warnings fail, matching this repo's CI (`lint.yml`).

A **context-budget** warning (for example, "Estimated N tokens exceeds
skill warn limit of 3,000") is a required fix, the same as a test
failure. Other skillsaw findings on files you changed are also required
fixes. Do not regenerate the baseline for violations you introduced.

## Remediation

When trimming to satisfy the budget:

1. Prefer **moving or cutting newly-added content** (the text this
   iteration introduced) over condensing pre-existing unrelated prose.
   Moving new detail into a `references/` file is the durable pattern
   (see [timing.md](timing.md)).
2. Do **not** re-condense wording that was already reviewed and
   reverted earlier in this PR. Check `git log` and `git diff` against
   earlier commits on the branch so a reverted trim does not reappear.
3. Do not weaken, skip, or baseline a new context-budget warning.

If `make lint` / skillsaw cannot run (missing tool, network), disclose
that in the commit message; do not treat "could not run" as a pass.
