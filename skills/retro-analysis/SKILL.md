---
name: retro-analysis
description: >
  Use when performing a retrospective on an agent workflow. Teaches how to
  trace workflow runs, explore context with subagents, and write structured
  improvement proposals.
---

# Retro Analysis

## Tracing the workflow graph

Given the originating PR or issue, reconstruct what agents ran and in what order. Use the forge-specific retro-analysis skill for CLI recipes (GitHub or GitLab).

### Setup

```bash
ORG=$(echo "$REPO_FULL_NAME" | cut -d/ -f1)
DISPATCH_REPO="${ORG}/.fullsend"
```

### From an issue

1. Find triage dispatches triggered by commands or label responses.
2. Find the corresponding agent runs in the dispatch repo.
3. If the issue reached `ready-to-code`, find code dispatches.

### From a PR

1. The PR branch follows `agent/{issue}-{slug}`. Extract the issue number to trace the full history.
2. Find review dispatches.
3. Find fix dispatches (if review requested changes).

## Exploration strategy

You have a large amount of context to cover. Use subagents to avoid overflowing your main context window.

### Discovering the agents repo

Agent definitions, skills, harness configs, and scripts are resolved at
runtime from a separate repo — not from `fullsend-ai/fullsend`. The
workflow run log identifies this repo. Extract it during exploration
using your forge-specific skill's CLI recipes.

Look for log lines matching these patterns:
- `Fetching agent <name> from <owner>/<repo>@<ref>`
- `Agent <name> resolved from <owner>/<repo>@<ref>`

Store the discovered repo (e.g., `fullsend-ai/agents`) for use in
proposal localization. If the log does not contain these lines, note
the discovery failure in your summary and target agent-layer proposals
to `fullsend-ai/fullsend` only if you have independent evidence the
change belongs there. Otherwise, target the source repo
(`$REPO_FULL_NAME`) and note in the proposal that the agents repo
could not be discovered.

### Dispatch subagents for each investigation thread

- **Workflow tracer:** "Find all agent workflow runs related to issue/PR #N. List each run with its stage, status, conclusion, and timestamp."
- **Trace reader:** "Download and read the reasoning trace for run <RUN_ID>. Summarize what decisions the agent made and why."
- **Comment analyzer:** "Read all comments on PR #N. Categorize them: agent review comments, human review comments, CI results, human interventions."
- **Pattern searcher:** "Search the last 10 retro agent issues in <REPO>. List any recurring themes or prior proposals related to <TOPIC>."
- **Harness inspector:** "Read the harness config at harness/<AGENT>.yaml and the agent definition at agents/<AGENT>.md in the agents repo. Summarize the agent's configuration and constraints."

### Keep your main context for synthesis

After subagents return their findings, use your main context to:
1. Reconstruct the timeline
2. Identify where things could have gone better
3. Form hypotheses about root causes
4. Decide what changes to propose and where

## Test flakiness

Retro runs are well-positioned to detect test flakiness — the same test
failing then passing across re-runs of the same commit with no relevant
diff in between. When you spot this pattern, propose **resilience** fixes,
not retry-budget increases.

### Detection signal

A test is likely flaky when:

- It fails in one workflow run and passes in a subsequent run on the
  same commit.
- There is no code change between the two runs that could explain the
  different outcome.
- The failure message points to a timeout, connection error, race
  condition, or non-deterministic ordering.

### What to propose

Apply this ordering — prefer the first option that fits:

1. **Production-code resilience.** If the flaky test exercises a real
   dependency (network call, external service, subprocess, database
   connection), propose a retry-with-exponential-backoff handler in the
   *production* code path. This is a reliability gap that would
   eventually surface at runtime, not just in CI.
2. **Test-fixture resilience.** If the flakiness is purely a
   test-harness artifact (waiting for a service to start, racing a
   background process, port allocation collision), propose a
   backoff/retry helper in the fixture or setup step — not in the
   assertion itself.

### What not to propose

Do not propose retry-budget approaches:

- Bumping `MAX_RETRIES` or equivalent retry-count settings
- Adding CI rerun triggers or automatic workflow re-dispatch
- Wrapping individual assertions in retry loops

These hide the symptom without addressing the underlying cause. They
conflict with the "don't commit broken code" stance in the code and fix
agent definitions.

If you are unsure whether a failure is a genuine flake or a real bug,
say so explicitly in your proposal and recommend investigation before
applying either fix category.

## Before proposing: check for existing issues

**This step is mandatory and leaves a receipt.** For each proposal, search for existing issues covering it and record the search in the proposal's `related_issues` field. A proposal whose receipt is missing or records fewer than two distinct search phrases is **not filed** — post-retro skips it and folds it into the summary comment. Without this check, repeated retro runs produce duplicate issues that waste human triage time.

Dispatch a subagent to run your forge-specific skill's search commands, **two passes with different keys**:

1. **Fix-keyed** — keywords from the proposed change, in the proposal's `target_repo`.
2. **Root-cause-keyed** — keywords for the affected subsystem or failure mechanism, independent of how the proposal frames the fix. A root-cause fix and a symptom workaround describe the same problem in different words; only this pass catches that. **Search this pass across every repo the localization rules can route a proposal to** — platform (`fullsend-ai/fullsend`), the discovered agents repo, and the source repo — because a symptom fix and its root cause can land in different layers. Scope to those named repos, never an org/group-wide search (it reaches private and unrelated sibling repos). See your forge skill for the exact multi-repo query.

The subagent must return each candidate's **repo**, number, title, state, **and body** (or a substantial excerpt of the problem statement and proposed change) — judging overlap from titles alone misses differently-worded duplicates, and the repo is needed to record a cross-repo match as `owner/repo#N` rather than a bare `#N`.

**Evaluation criteria** (apply these yourself, not the subagent):

- An existing issue covers the proposal if it describes the **same root problem, even if the symptoms or wording differ** — the same rule triage applies when closing duplicates. When in doubt, treat it as covered.
- **Skip the proposal** if an open issue proposes the same or substantially overlapping change; reference it in your summary instead.
- **Closed issues — keyed on close reason, not a flat window:**
  - *duplicate* (any age): follow the chain to the canonical. Prefer the **structured duplicate link** the forge records for a native "close as duplicate" (GitHub `Issue.duplicateOf` via GraphQL; GitLab `_links.closed_as_duplicate_of`) — it is not in the candidate's text. Only when that link is absent, fall back to the candidate's own body and comments for a "duplicate of #X" reference (the duplicate points to the canonical, not the reverse — a search for issues that merely mention the candidate's number will not find it). Fetch the canonical directly, following further duplicate links if it is itself closed as a duplicate, and note its repo — the canonical may live in another layer. Skip and reference the canonical if it is open.
  - *not planned*: skip if closed within 30 days — a maintainer already rejected it.
  - *completed with a merged fix*: if the symptom **recurred after the merge**, keep the proposal as a regression referencing the old issue and fix PR; otherwise skip.
  - *completed without a real fix*: keep the proposal, reference the old issue.
- **Include the proposal** only if no existing issue covers it, or it meaningfully refines an existing one.

**Record the receipt.** `related_issues` holds the search phrases run and the candidates considered. Record a candidate as a bare integer when it is in the proposal's `target_repo`, or as the fully-qualified `owner/repo#N` string when it is not — a bare `#N` renders as a link into `target_repo` and would point at the wrong issue. It is small in practice — searches usually return zero relevant candidates.

**Do not file "evidence for" issues.** When your analysis produces evidence that supports or corroborates an existing open issue, put it in your `summary` field — not in a new proposal. Do not title proposals "Evidence for #XXXX" or use any other framing that makes a duplicate look like a new issue. The summary is posted as a comment on the originating PR or issue, which preserves the data point. Filing evidence as a separate proposal creates noise that compounds across retro runs.

When skipping, note the duplicate in your `summary` field — include the issue number and what specific evidence this retro found, so the human understands what was filtered and why. Keep evidence notes concise — one sentence per existing issue with the issue number and a brief description of the new evidence. The summary field has a schema length limit; prioritize the most impactful evidence if space is constrained.

## Localization guidance

When deciding where a proposed change belongs, distinguish three layers:

1. **Platform tooling** (fullsend CLI, reusable workflows, sandbox) →
   target `fullsend-ai/fullsend`.
2. **Agent definitions, skills, harness configs, scripts** → target the
   agents repo discovered from the workflow run log (see "Discovering
   the agents repo" above). These files are resolved at runtime from a
   separate repo — not from `fullsend-ai/fullsend`.
3. **Repo-specific** fixes (test commands, linter config) → target the
   source repo (`$REPO_FULL_NAME`).

Do not push repo-specific details upstream. Do not conflate platform
tooling with agent-layer artifacts — they live in different repos.

### Recognizing intentional repo-local customizations

Not every difference between a repo's setup and the platform scaffold
is a problem to solve. Repos may intentionally maintain:

- **Local script forks** — modified copies of platform scripts
  (e.g., a custom `post-code.sh`) to handle repo-specific needs
- **Custom tooling** — scripts or tools that replace or supplement
  platform defaults (e.g., a custom commit-signing helper)
- **Non-default configurations** — deliberate choices to diverge from
  scaffold defaults

Treat these as intentional decisions by the repo owner. Do not propose
upstreaming a capability to the platform based on a single repo's local
customization. A local fork is evidence of a local need, not evidence
of a platform gap.

**When to propose upstreaming:** Only propose that a local customization
be upstreamed when there is evidence that multiple independent repos
need the same capability. A single repo's local fork does not meet that
threshold.

**Bugs in customized workflows are still valid findings.** If a repo's
local script fork contains a bug or regression in the workflow itself
(not in its divergence from the platform), that is a valid finding —
propose the fix in the source repo, not as an upstream platform change.

<!-- TODO(#833): Remove this restriction once per-repo customization is
     stable. Depends on: #195, #179, #419, PR #792, PR #799. -->

**Avoid targeting `*/.fullsend` repos.** The per-repo customization model
for `.fullsend` repos is not yet defined. Issues filed there are hard for
users to discover and act on. Instead:

- Route platform tooling improvements to `fullsend-ai/fullsend`.
- Route agent-layer improvements (agent definitions, skills, harness
  configs, scripts) to the agents repo from the run log.
- Route repo-specific fixes to the source repo.
- Only target a `.fullsend` repo when the change is genuinely org-level
  configuration with no alternative location. If you do, you **must**
  include explicit justification in the `proposed_change` field explaining
  why `.fullsend` is the only viable target.

## Output format

Write a single JSON file to `$FULLSEND_OUTPUT_DIR/agent-result.json` with this structure:

```json
{
  "summary": "Markdown summary for the originating PR/issue comment.",
  "proposals": [
    {
      "target_repo": "owner/repo-name",
      "title": "Concise proposal title",
      "what_happened": "Timeline with links...",
      "what_could_go_better": "Assessment with uncertainty...",
      "proposed_change": "Specific change description...",
      "validation_criteria": "How to verify the improvement...",
      "related_issues": {
        "searched": ["fix keywords...", "subsystem or root-cause keywords..."],
        "found": [1234, "owner/other-repo#56"],
        "note": "One line per candidate: why it does not cover this proposal, or how this proposal refines it."
      }
    }
  ]
}
```

**Schema is strict.** The top-level object allows ONLY `summary` and `proposals` — no additional properties. Each proposal object allows ONLY the seven fields shown above. The harness validates against `$FULLSEND_OUTPUT_SCHEMA` with `"additionalProperties": false` at both levels. Do not add fields like `timeline`, `metadata`, `workflow_quality`, or `originating_url`.

After writing the file, validate it before exiting:

```bash
fullsend-check-output "$FULLSEND_OUTPUT_DIR/agent-result.json"
```

If validation fails, read the error output, fix the JSON file, and
re-run the check. If it still fails after 3 attempts, write the best
JSON you have and exit.

### Writing good proposals

- **what_happened:** Tell the story chronologically. Link to specific workflow runs, log lines, PR comments, and review verdicts. Use markdown links.
- **what_could_go_better:** Be honest about your uncertainty. If you are confident, say so and why. If you are speculating, say that too. Explain your reasoning.
- **proposed_change:** Name the specific file, config, skill, or prompt that should change. Describe what the change looks like. Be specific enough for an implementer to act on it.
- **validation_criteria:** Define measurable or observable outcomes. Include a timeframe or sample size. For example: "The next 5 code agent runs on this repo should not trigger the same review comment about missing error handling."
- **related_issues:** The dedup receipt — search phrases run (fix-keyed and root-cause-keyed) and candidates considered (`found`: a bare integer for a `target_repo` issue, or `owner/repo#N` for a cross-repo one). `found` may be empty; `searched` may not. See "Before proposing" above.

### When to propose nothing

If the workflow went well and you cannot identify meaningful improvements, write a summary saying so and return an empty proposals array. A retro that finds nothing wrong is a valid outcome.

## Constraints

The agent definition (`agents/retro.md`) is the authoritative list of prohibitions. This skill does not restate them.
