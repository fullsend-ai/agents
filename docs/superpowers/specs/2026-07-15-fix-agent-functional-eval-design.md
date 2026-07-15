# Fix agent functional eval design

**Date:** 2026-07-15  
**Repo:** [fullsend-ai/agents](https://github.com/fullsend-ai/agents)  
**Status:** Draft — pending user review  
**Related:** code eval in PR [#177](https://github.com/fullsend-ai/agents/pull/177) / issue [#180](https://github.com/fullsend-ai/agents/issues/180)

## Goal

Add `eval/fix/` — a functional test that runs the real fix agent pipeline (`pre → sandbox → post`) against an **existing PR**, simulating a **human `/fs-fix`** trigger with a **concrete instruction** that names the bug to fix. Success is a **new commit** on the PR branch that touches the expected file(s).

This does **not** exercise GitHub Actions comment → workflow dispatch. Like `eval/code`, it calls `fullsend run fix` with the env the workflow would have set after parsing `/fs-fix …`.

## Decisions (locked)

| Topic | Choice |
|---|---|
| Trigger mode | Human only (`TRIGGER_SOURCE` not ending in `[bot]`) |
| Fixture | Minimal tiny-calc: PR introduces buggy `add()` |
| Instruction | Specific statement (not vague “solve this problem”) — see below |
| Proof | Structural: new HEAD commit + `expected_files` |
| Approach | Mirror code eval (shared hooks/runner; new `eval/fix/`) |

## Case: `001-human-fs-fix-add`

### Repo layout

- **`main`:** minimal README only (or empty stub) so the bug lives on the PR branch.
- **PR branch** (via `setup-fixture.sh` `fixture.type: pull_request` + `files:`):
  - `calc.py` — `add()` returns `a - b` (bug)
  - `tests/test_calc.py` — asserts `add(2,3)==5` and a negative case (fail until fixed)

Same spirit as `eval/code/cases/001-fix-add`, but the broken code is already on an open PR rather than an issue to implement from scratch.

### Human instruction

Exact string passed as `HUMAN_INSTRUCTION` (what the workflow extracts after `/fs-fix`):

```text
calc.py's add() returns a - b instead of a + b. Change it to return a + b so the existing tests in tests/test_calc.py pass. Do not refactor beyond that fix.
```

Rationale: the agent must follow an explicit human directive (human mode), not invent scope from a review body. Vague “solve this problem” is too underspecified for a reliable first case.

`TRIGGER_SOURCE` example: `eval-human` (any non-`[bot]` username).

### Required env for `fullsend run fix`

Set by `run-fullsend.sh` when `AGENT=fix` (in addition to existing PR fixture vars):

| Var | Value |
|---|---|
| `PR_NUMBER` / `REPO_FULL_NAME` / `GITHUB_PR_URL` | From fixture (already for `pull_request`) |
| `TRIGGER_SOURCE` | `eval-human` |
| `HUMAN_INSTRUCTION` | Statement above |
| `FIX_ITERATION` | `1` |
| `TARGET_BRANCH` | `main` |
| `PRE_AGENT_HEAD` | SHA of PR head **before** the agent runs (fixture commit) |
| `REVIEW_BODY_FILE` | Path to a temp **empty** (or whitespace-only) file — harness `host_files` requires `${REVIEW_BODY_FILE}`; human mode treats `HUMAN_INSTRUCTION` as primary |
| `PUSH_TOKEN_SOURCE` | `eval` (same as code) |
| `GITHUB_WORKSPACE` | Eval temp parent with `target-repo/` (same as code/fix layout) |
| `GIT_BOT_EMAIL` | Eval bot noreply (same as code) |

Clone the ephemeral PR branch into `…/target-repo` so post-fix pushes onto the existing head (not a new branch).

### Capture + judges

Extend `capture-fixture.sh` for `pull_request` fixtures used by fix (keep review judges compatible):

- Existing: state, labels, comments, reviews  
- **Add:** `head_sha`, `commits` (recent, with SHAs), per-PR `files` (reuse issue-PR fetch helper), optional `pre_agent_head` echoed from hook/env if present  

Judges in `eval/fix/eval.yaml`:

| Judge | Pass when |
|---|---|
| `new_commit` | Captured `head_sha` ≠ `PRE_AGENT_HEAD` / annotations `pre_commit` / fixture baseline |
| `expected_files` | Changed files on the PR include `calc.py` (and fail clearly if `files_fetch_failed`) |
| `forbidden_labels` | Lint-required |
| `max_turns` / `max_cost` | Lint-required; budgets similar to code (tune after baseline) |

Thresholds: all `min_pass_rate: 1.0` for the first case.

### Timeouts

- Harness `timeout_minutes: 25` → eval `execution.timeout` ~ 1800–2100s  
- `EVAL_TIMEOUT` aligned in runner env  

### Out of scope (v1)

- Bot/review-triggered fix case (synthetic review body)  
- Literally posting `/fs-fix …` as a PR comment (optional B-lite later for live halfsend visibility)  
- Full Actions comment → dispatch E2E  
- Content/string judges or running pytest in after_each  

## Shared script impact

| File | Change |
|---|---|
| `eval/scripts/run-fullsend.sh` | `AGENT=fix` branch: write empty review-body file; emit fix env; record `PRE_AGENT_HEAD` from cloned PR HEAD before `fullsend run` |
| `eval/scripts/capture-fixture.sh` | Enrich `pull_request` capture with head SHA / commits / files |
| `eval/fix/**` | New (eval.yaml + one case) |

Triage/review must remain unaffected: fix-only env only when `AGENT=fix`; PR capture fields are additive.

## CI

`select-eval-agents.sh` already selects agents with `eval/<agent>/eval.yaml` when those paths change → `fix` runs automatically on PRs that touch `eval/fix/` or `harness/fix.yaml`.

## Success criteria

1. `./eval/lint-cases.sh fix` passes  
2. Functional-tests (`fix`) creates ephemeral PR, runs fix with the concrete instruction, post-script pushes a new commit  
3. Judges: `new_commit` + `expected_files` pass at 1.0  
4. Artifact shows `HUMAN_INSTRUCTION` preview in pre-fix output and a post-fix push to the existing PR branch  

## Open questions

None blocking v1. Optional follow-up: post the `/fs-fix <instruction>` comment on the ephemeral PR for observability only (not used as the trigger).
