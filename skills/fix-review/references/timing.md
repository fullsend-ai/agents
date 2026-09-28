# Time budget — commands and thresholds

Referenced from `SKILL.md`'s "Time budget" section and step 7b.

If the `TIMEOUT_SECONDS` environment variable is set, use it to manage time.

Capture the start time at the very beginning:

```bash
AGENT_START=$(date +%s)
```

Before starting pre-commit (7b), before the direct-execution fallback
inside 7b, before each retry iteration (7c), and before commit (8),
check remaining time **only if `TIMEOUT_SECONDS` is set**:

```bash
if [ -n "${TIMEOUT_SECONDS:-}" ]; then
  ELAPSED=$(( $(date +%s) - AGENT_START ))
  REMAINING=$(( TIMEOUT_SECONDS - ELAPSED ))
  echo "::notice::Time check: ${ELAPSED}s elapsed, ${REMAINING}s remaining"
fi
```

Thresholds (fractions of budget, except the fallback floor, which is
a flat 300s — what it guards costs the same whatever the budget is):
- **Before 7b (pre-commit):** < 10% remaining → skip pre-commit
- **Before the direct-execution fallback in 7b:** < 300s remaining →
  skip the fallback (its `pip install` steps risk a hard timeout),
  proceed to 7c and disclose the skip in the commit message
- **Before retry in 7c:** < 20% remaining → commit with disclosure
- **Before 8 (commit):** < 8% remaining → skip gitlint validation

## 7b fallback time recheck

Run this **only** when the `pre-commit run` in step 7b failed on
infrastructure (could not fetch hook repositories, or died before
executing any hook) — not after a pass, not after real hook errors. The
10% gate measured the fast path; the fallback `pip install`s each hook
at its pinned `rev` and can outrun a thin margin, timing out with no
commit at all. Re-check against a flat 300s floor (absolute, because
the cost does not scale with the budget):

```bash
RUN_FALLBACK=1
if [ -n "${TIMEOUT_SECONDS:-}" ] && [ -n "${AGENT_START:-}" ]; then
  REMAINING=$(( TIMEOUT_SECONDS - ($(date +%s) - AGENT_START) ))
  if [ "$REMAINING" -lt 300 ]; then
    RUN_FALLBACK=0; echo "::warning::Direct-execution fallback skipped: ${REMAINING}s remaining < 300s floor"
  else
    echo "::notice::Fallback time check: ${REMAINING}s remaining >= 300s floor — proceeding"
  fi
else
  echo "::notice::Fallback time check skipped: TIMEOUT_SECONDS or AGENT_START unset — no floor applied"
fi
```

Guard both variables (an unset `AGENT_START` reads as 0 and would
always skip) and print on every path.

If `RUN_FALLBACK` is `0`: skip the fallback — `repo: local` hooks
included, since a local `entry` can fetch too and 7c's lint still runs —
treat 7b as finished, and put this in the commit message:

> Note: pre-commit hooks were not run. `pre-commit` could not
> complete (infrastructure failure), and the remaining time budget
> was below the floor for running the hooks directly.

Skipping consumes no run but closes 7b for this iteration.

If `1`, run the fallback as described in step 7b.
