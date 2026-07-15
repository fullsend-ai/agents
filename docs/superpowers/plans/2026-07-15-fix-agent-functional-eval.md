# Fix Agent Functional Eval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `eval/fix/` with one human `/fs-fix` case that asserts the fix agent pushes a new commit on an existing PR touching `calc.py`.

**Architecture:** Mirror `eval/code`. Reuse `setup-fixture.sh` PR fixtures. Extend `run-fullsend.sh` for fix-specific env (`HUMAN_INSTRUCTION`, `PRE_AGENT_HEAD`, empty `REVIEW_BODY_FILE`, checkout PR head). Enrich `capture-fixture.sh` PR capture with `head_sha` / `files` / `pre_agent_head`. Judges: `new_commit` + `expected_files` + budgets.

**Tech Stack:** agent-eval-harness, bash, `gh`, `jq`, `fullsend run fix`, OpenShell (CI).

**Spec:** `docs/superpowers/specs/2026-07-15-fix-agent-functional-eval-design.md`

## Global Constraints

- Human trigger only: `TRIGGER_SOURCE=eval-human` (must not end in `[bot]`)
- `HUMAN_INSTRUCTION` exact text from spec (single line — no newlines; `emit_env` rejects `\n`)
- Do not post a live `/fs-fix` comment in v1
- Shared script changes must stay additive for triage/review
- `GITHUB_WORKSPACE` override already limited to `code|fix` — keep that
- Land as a new PR on `fullsend-ai/agents` (separate from #177 unless explicitly combining)
- Adam prefers manual `git commit` / `git push` unless he grants temporary permission — plan commit steps are for the implementing agent when authorized

## File map

| Path | Responsibility |
|---|---|
| `eval/fix/eval.yaml` | Fix eval config + judges |
| `eval/fix/cases/001-human-fs-fix-add/input.yaml` | PR fixture (buggy calc on PR branch) |
| `eval/fix/cases/001-human-fs-fix-add/annotations.yaml` | expected_files, budgets |
| `eval/fix/cases/001-human-fs-fix-add/repo/` | Base `main` content (README only) |
| `eval/scripts/run-fullsend.sh` | Fix env + PR-head checkout + `PRE_AGENT_HEAD` |
| `eval/scripts/capture-fixture.sh` | PR `head_sha`, `files`, `pre_agent_head` |
| `docs/superpowers/specs/2026-07-15-fix-agent-functional-eval-design.md` | Already written |

---

### Task 1: Enrich PR capture for fix judges

**Files:**
- Modify: `eval/scripts/capture-fixture.sh` (pull_request branch)

**Interfaces:**
- Consumes: existing `FIXTURE_NUMBER`, `EPHEMERAL_REPO`, `fetch_pr_files` helper
- Produces: `fixture-state.json` fields `head_sha`, `head_ref`, `files`, `files_fetch_failed`, `pre_agent_head` (from env if set), plus existing review fields

- [ ] **Step 1: Extend the `pull_request)` case**

After fetching `pr_json` / comments / reviews, also capture head SHA and files. Replace the `pull_request)` branch body so the final `jq` includes the new fields. Keep existing keys for review judges.

```bash
  pull_request)
    pr_json=$(gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" \
      --json state,labels,assignees,milestone,title,mergeable,reviewDecision,headRefOid,headRefName)
    comments_json=$(gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" --json comments \
      | jq '[.comments[] | {author: .author.login, body: .body, created_at: .createdAt}]')
    reviews_json=$(gh pr view "$FIXTURE_NUMBER" --repo "$EPHEMERAL_REPO" --json reviews \
      | jq '[.reviews[] | {author: .author.login, state: .state, body: .body}]')

    files='[]'
    files_fetch_failed=false
    if files_json=$(fetch_pr_files "$FIXTURE_NUMBER"); then
      files="$files_json"
    else
      echo "WARNING: gh pr view failed for PR #${FIXTURE_NUMBER}; marking files_fetch_failed" >&2
      files='null'
      files_fetch_failed=true
    fi

    # Optional: runner exported PRE_AGENT_HEAD into the hook env via forward-propagation
    # if we write it to .hook-outputs — for v1 read from process env if present.
    pre_agent_head="${PRE_AGENT_HEAD:-}"

    jq -n \
      --arg fixture_type "pull_request" \
      --arg fixture_url "$FIXTURE_URL" \
      --argjson pr "$pr_json" \
      --argjson comments "$comments_json" \
      --argjson reviews "$reviews_json" \
      --argjson files "$files" \
      --argjson files_fetch_failed "$files_fetch_failed" \
      --arg pre_agent_head "$pre_agent_head" \
      '{
        fixture_type: $fixture_type,
        fixture_url: $fixture_url,
        state: $pr.state,
        title: $pr.title,
        labels: [($pr.labels // [])[] | .name],
        assignees: [($pr.assignees // [])[] | .login],
        milestone: ($pr.milestone.title // null),
        mergeable: $pr.mergeable,
        review_decision: $pr.reviewDecision,
        comments: $comments,
        reviews: $reviews,
        head_sha: $pr.headRefOid,
        head_ref: $pr.headRefName,
        files: $files,
        files_fetch_failed: $files_fetch_failed,
        pre_agent_head: (if $pre_agent_head == "" then null else $pre_agent_head end)
      }' > "$STATE_FILE"
    ;;
```

Note: `files_fetch_failed` must be a JSON boolean — use `--argjson files_fetch_failed true/false` (bash `true`/`false` without quotes in the variable assignment above as `true`/`false` then `--argjson`).

If `files` is the string `null`, use `--argjson files null` — set `files='null'` only when failed; when success use the JSON array from `fetch_pr_files`.

- [ ] **Step 2: Syntax-check**

Run: `bash -n eval/scripts/capture-fixture.sh`  
Expected: no output, exit 0

- [ ] **Step 3: Commit (when authorized)**

```bash
git add eval/scripts/capture-fixture.sh
git commit -s -m "fix(eval): capture PR head SHA and files for fix judges"
```

---

### Task 2: Teach `run-fullsend.sh` to drive the fix agent

**Files:**
- Modify: `eval/scripts/run-fullsend.sh`

**Interfaces:**
- Consumes: `AGENT`, `FIXTURE_TYPE=pull_request`, cloned `TARGET_DIR`
- Produces: env file with fix vars; `PRE_AGENT_HEAD` exported for after_each; PR branch checked out in `TARGET_DIR`

- [ ] **Step 1: After clone, check out the PR head when fixture is a pull request**

Insert after the `git -C "$TARGET_DIR" config credential.helper` lines:

```bash
# Fix (and any PR-driven agent) must run on the PR branch, not main.
if [[ "$FIXTURE_TYPE" == "pull_request" ]]; then
  git -C "$TARGET_DIR" fetch origin "pull/${FIXTURE_NUMBER}/head:eval-pr-head"
  git -C "$TARGET_DIR" checkout eval-pr-head
fi
PRE_AGENT_HEAD="$(git -C "$TARGET_DIR" rev-parse HEAD)"
export PRE_AGENT_HEAD
```

- [ ] **Step 2: Persist `PRE_AGENT_HEAD` for after_each**

The harness forwards hook outputs, not arbitrary runner exports. Write into the case workspace hook-outputs merge path the runner can use — simplest reliable approach used by this repo: append to `$OUTPUT_DIR/../.hook-outputs.yaml` is wrong (setup already wrote it).

Instead: write `PRE_AGENT_HEAD` into the env file **and** a small sidecar the capture script can read:

```bash
# After PRE_AGENT_HEAD is known, before fullsend run:
mkdir -p "$OUTPUT_DIR"
printf '%s\n' "$PRE_AGENT_HEAD" > "${OUTPUT_DIR}/pre-agent-head.txt"
```

Update capture (Task 1) to prefer:

```bash
pre_agent_head="${PRE_AGENT_HEAD:-}"
if [[ -z "$pre_agent_head" && -f "${OUTPUT_DIR}/pre-agent-head.txt" ]]; then
  pre_agent_head=$(cat "${OUTPUT_DIR}/pre-agent-head.txt")
fi
```

(`OUTPUT_DIR` in capture is `$CASE_WORKSPACE/output` — same tree.)

- [ ] **Step 3: Emit fix-specific env when `AGENT=fix`**

Inside the `{ ... } > "$ENV_FILE"` block, after the `code|fix)` shared block and the `pull_request)` fixture case, add:

```bash
  if [[ "$AGENT" == "fix" ]]; then
    REVIEW_BODY_FILE="$(mktemp)"
    : > "$REVIEW_BODY_FILE"
    # cleanup REVIEW_BODY_FILE in trap — extend cleanup()
    emit_env "TRIGGER_SOURCE" "eval-human"
    # Exact instruction from the design spec (single line).
    emit_env "HUMAN_INSTRUCTION" "calc.py's add() returns a - b instead of a + b. Change it to return a + b so the existing tests in tests/test_calc.py pass. Do not refactor beyond that fix."
    emit_env "FIX_ITERATION" "1"
    emit_env "TARGET_BRANCH" "main"
    emit_env "PRE_AGENT_HEAD" "${PRE_AGENT_HEAD}"
    emit_env "REVIEW_BODY_FILE" "${REVIEW_BODY_FILE}"
  fi
```

Extend `cleanup()`:

```bash
cleanup() {
  [[ -n "${ENV_FILE:-}" ]] && rm -f "$ENV_FILE"
  [[ -n "${REVIEW_BODY_FILE:-}" && -f "${REVIEW_BODY_FILE:-}" ]] && rm -f "$REVIEW_BODY_FILE"
  [[ -n "${EVAL_GH_WORKSPACE:-}" && -d "${EVAL_GH_WORKSPACE:-}" ]] && rm -rf "$EVAL_GH_WORKSPACE"
}
```

Declare `REVIEW_BODY_FILE=""` near the top (before trap) so `set -u` is safe.

- [ ] **Step 4: Syntax-check**

Run: `bash -n eval/scripts/run-fullsend.sh`  
Expected: exit 0

- [ ] **Step 5: Commit (when authorized)**

```bash
git add eval/scripts/run-fullsend.sh eval/scripts/capture-fixture.sh
git commit -s -m "fix(eval): supply fix-agent env and checkout PR head for functional runs"
```

---

### Task 3: Add `eval/fix` case + config

**Files:**
- Create: `eval/fix/eval.yaml`
- Create: `eval/fix/cases/001-human-fs-fix-add/input.yaml`
- Create: `eval/fix/cases/001-human-fs-fix-add/annotations.yaml`
- Create: `eval/fix/cases/001-human-fs-fix-add/repo/README.md`

**Interfaces:**
- Consumes: shared hooks/runner from Tasks 1–2
- Produces: lint-clean fix eval selected by `select-eval-agents.sh`

- [ ] **Step 1: Create base repo README**

`eval/fix/cases/001-human-fs-fix-add/repo/README.md`:

```markdown
# tiny-calc (fix eval)

Base branch is intentionally empty of product code. The PR under test adds a buggy calculator.
```

- [ ] **Step 2: Create `input.yaml` (PR fixture with buggy calc)**

`eval/fix/cases/001-human-fs-fix-add/input.yaml`:

```yaml
forge: github
fixture:
  type: pull_request
  title: "feat: add basic calculator"
  body: |
    Adds a tiny calculator module with tests.

    Note: add() currently appears wrong in review — please fix via /fs-fix if needed.
  base: main
  files:
    - path: calc.py
      content: |
        # Tiny calculator — intentional off-by-operator bug for the fix eval.


        def add(a: int, b: int) -> int:
            """Return the sum of a and b."""
            return a - b  # BUG: should be a + b
    - path: tests/test_calc.py
      content: |
        """Tests for calc module."""

        from calc import add


        def test_add() -> None:
            assert add(2, 3) == 5


        def test_add_negative() -> None:
            assert add(-1, -2) == -3
```

- [ ] **Step 3: Create `annotations.yaml`**

```yaml
state: open

expected_files:
  - calc.py

labels:
  forbidden: []

max_turns: 80
max_cost_usd: 8.00

fix_expectations: |
  Human-triggered fix: HUMAN_INSTRUCTION tells the agent that add() subtracts
  instead of adds. Success is a new commit on the existing PR branch that
  touches calc.py (post-fix push). PRE_AGENT_HEAD is the fixture commit SHA.
```

- [ ] **Step 4: Create `eval/fix/eval.yaml`**

```yaml
name: fix-eval
description: >
  Functional test of the fullsend fix agent pipeline (pre → sandbox → post)
  for a human /fs-fix trigger on an existing PR. Validates the post-script
  pushes a new commit that touches the expected files.

skill: fix

execution:
  mode: case
  timeout: 1800  # fix harness timeout_minutes is 25; leave headroom
  parallelism: 1
  env:
    EVAL_ORG: $EVAL_ORG
    GH_TOKEN: $GH_TOKEN
    FULLSEND_DIR: $FULLSEND_DIR
    EVAL_TIMEOUT: "1800"
    GOOGLE_APPLICATION_CREDENTIALS: $GOOGLE_APPLICATION_CREDENTIALS
    ANTHROPIC_VERTEX_PROJECT_ID: $ANTHROPIC_VERTEX_PROJECT_ID
    GOOGLE_CLOUD_PROJECT: $GOOGLE_CLOUD_PROJECT
    CLOUD_ML_REGION: $CLOUD_ML_REGION

hooks:
  before_each:
    - command: "setup-fixture.sh"
      timeout: 120
      description: "Create ephemeral repo and PR fixture"

  after_each:
    - command: "capture-fixture.sh"
      timeout: 60
      description: "Capture PR head/files for judges"
    - command: "teardown-fixture.sh"
      timeout: 30
      on_failure: continue
      description: "Delete ephemeral repo"

runner:
  type: cli
  command:
    - "run-fullsend.sh"
    - "{agent}"
    - "{workspace}"
    - "{output_dir}"
  env:
    FULLSEND_DIR: $FULLSEND_DIR
    GH_TOKEN: $GH_TOKEN
    EVAL_TIMEOUT: "1800"
    GOOGLE_APPLICATION_CREDENTIALS: $GOOGLE_APPLICATION_CREDENTIALS
    ANTHROPIC_VERTEX_PROJECT_ID: $ANTHROPIC_VERTEX_PROJECT_ID
    GOOGLE_CLOUD_PROJECT: $GOOGLE_CLOUD_PROJECT
    CLOUD_ML_REGION: $CLOUD_ML_REGION

models:
  skill: claude-opus-4-6
  judge: claude-opus-4-6

dataset:
  path: cases
  schema: |
    Each case directory contains:
    - input.yaml: PR fixture (base repo + PR files with the bug).
    - annotations.yaml: Expected files and budgets.
    - repo/: Base branch contents pushed to main before the PR.

outputs:
  - path: output
    schema: |
      fixture-state.json: Captured PR state including head_sha, files,
      and pre_agent_head for new_commit / expected_files judges.

judges:
  - name: new_commit
    description: Post-script must push at least one new commit on the PR head
    check: |
      import json
      state = json.loads(outputs["files"]["output/fixture-state.json"])
      head = state.get("head_sha")
      if not head:
          return False, "head_sha missing from fixture-state.json"
      baseline = state.get("pre_agent_head")
      if not baseline:
          # Fallback: annotations may declare fixture_head_sha after a dry run
          baseline = outputs.get("annotations", {}).get("fixture_head_sha")
      if not baseline:
          return False, "pre_agent_head missing — cannot prove a new commit"
      if str(head) == str(baseline):
          return False, f"PR head unchanged ({head}) — fix post-script did not push"
      return True, f"New commit on PR: {baseline} -> {head}"

  - name: expected_files
    description: PR must touch files listed in annotations.expected_files
    check: |
      import json
      state = json.loads(outputs["files"]["output/fixture-state.json"])
      expected = outputs.get("annotations", {}).get("expected_files") or []
      if not expected:
          return True, "No expected_files declared"
      if state.get("files_fetch_failed"):
          return False, "Could not fetch changed files for PR"
      changed = set(state.get("files") or [])
      missing = [p for p in expected if p not in changed]
      if missing:
          return False, f"Expected files missing from PR: {missing} (changed: {sorted(changed)})"
      return True, f"All expected files present: {expected}"

  - name: forbidden_labels
    description: Labels listed in annotations.yaml forbidden list must NOT be present
    check: |
      import json
      state = json.loads(outputs["files"]["output/fixture-state.json"])
      actual = [l.lower() for l in state.get("labels", [])]
      forbidden = outputs.get("annotations", {}).get("labels", {}).get("forbidden", [])
      if not forbidden:
          return True, "No forbidden labels specified"
      present = [l for l in forbidden if l.lower() in actual]
      if present:
          return False, f"Forbidden labels present: {present} (actual: {actual})"
      return True, f"No forbidden labels found (checked: {forbidden})"

  - name: max_turns
    description: Agent must complete within the declared turn budget
    check: |
      import json
      raw = outputs["files"].get("output/metrics.json")
      if not raw:
          return False, "metrics.json not found"
      metrics = json.loads(raw)
      actual = metrics.get("num_turns")
      if actual is None:
          return False, "num_turns not present in metrics.json"
      limit = outputs.get("annotations", {}).get("max_turns")
      if limit is None:
          return False, "max_turns not declared in annotations.yaml"
      if int(actual) > int(limit):
          return False, f"Exceeded max_turns: {actual} > {limit}"
      return True, f"Turns OK: {actual} <= {limit}"

  - name: max_cost
    description: Agent must complete within the declared cost budget
    check: |
      import json
      raw = outputs["files"].get("output/metrics.json")
      if not raw:
          return False, "metrics.json not found"
      metrics = json.loads(raw)
      actual = metrics.get("total_cost_usd")
      if actual is None:
          return False, "total_cost_usd not present in metrics.json"
      limit = outputs.get("annotations", {}).get("max_cost_usd")
      if limit is None:
          return False, "max_cost_usd not declared in annotations.yaml"
      if float(actual) > float(limit):
          return False, f"Exceeded max_cost_usd: {actual} > {limit}"
      return True, f"Cost OK: {actual} <= {limit}"

thresholds:
  new_commit:
    min_pass_rate: 1.0
  expected_files:
    min_pass_rate: 1.0
  forbidden_labels:
    min_pass_rate: 1.0
  max_turns:
    min_pass_rate: 1.0
  max_cost:
    min_pass_rate: 1.0
```

- [ ] **Step 5: Lint**

Run: `./eval/lint-cases.sh fix`  
Expected: `OK: all cases pass lint checks`

- [ ] **Step 6: Confirm CI selection**

Run:

```bash
printf '%s\n' 'eval/fix/eval.yaml' | .github/scripts/select-eval-agents.sh --repo-root .
```

Expected: prints `fix`

- [ ] **Step 7: Commit (when authorized)**

```bash
git add eval/fix docs/superpowers/specs/2026-07-15-fix-agent-functional-eval-design.md
git commit -s -m "test(eval): add fix agent human /fs-fix functional eval"
```

---

### Task 4: Open PR and verify CI

**Files:** none (git/gh only)

- [ ] **Step 1: Push branch and open PR** (when authorized)

```bash
git push -u origin HEAD
gh pr create --title "test(eval): add fix agent human /fs-fix functional eval" --body "$(cat <<'EOF'
## Summary
- Add `eval/fix/` with `001-human-fs-fix-add` (existing PR + concrete HUMAN_INSTRUCTION)
- Extend shared eval scripts for fix env, PR-head checkout, and PR head/file capture

Closes #<file authorizing issue if created>

## Test plan
- [ ] `./eval/lint-cases.sh fix`
- [ ] Functional-tests (fix) green
- [ ] Artifact shows new_commit + expected_files pass

EOF
)"
```

- [ ] **Step 2: Monitor `functional-tests (fix)`**

Watch halfsend for `eval-001-human-fs-fix-add-*` repo/PR; confirm post-fix pushes a second commit; judges pass.

- [ ] **Step 3: Update PR description with proof** (CI links + fixture-state excerpt) like #177.

---

## Spec coverage self-check

| Spec requirement | Task |
|---|---|
| Human `/fs-fix` via env, not live comment | Task 2 |
| Concrete HUMAN_INSTRUCTION | Task 2 / Task 3 annotations |
| Minimal tiny-calc PR fixture | Task 3 |
| `new_commit` + `expected_files` | Task 1 + Task 3 judges |
| Empty REVIEW_BODY_FILE | Task 2 |
| PRE_AGENT_HEAD baseline | Task 2 + Task 1 |
| Shared scripts additive | Tasks 1–2 |
| CI auto-select fix | Task 3 step 6 |
| Out of scope bot case / live comment | Not implemented |

## Placeholder scan

None intentional. Instruction string is fixed verbatim from the design spec.
