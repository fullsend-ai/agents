---
name: retro-analysis
description: >
  Use when performing a retrospective on an agent workflow. Teaches how to
  trace workflow runs, explore context with subagents, and write structured
  improvement proposals.
---

# Retro Analysis

## Tracing the workflow graph

Given the originating PR or issue, reconstruct what agents ran and in what order.

### Setup

```bash
ORG=$(echo "$REPO_FULL_NAME" | cut -d/ -f1)
DISPATCH_REPO="${ORG}/.fullsend"
```

### From an issue

1. Find triage dispatches (triggered by `/fs-triage` command or `needs-info` label responses):

```bash
gh run list --repo "$REPO_FULL_NAME" --workflow=fullsend.yaml \
  --json databaseId,status,conclusion,event,createdAt \
  -q '.[] | select(.event == "issue_comment" or .event == "issues")'
```

2. Find the corresponding agent runs in the dispatch repo:

```bash
gh run list --repo "$DISPATCH_REPO" --workflow=triage.yml --limit 10 \
  --json databaseId,status,conclusion,createdAt
```

3. If the issue reached `ready-to-code`, find code dispatches:

```bash
gh run list --repo "$DISPATCH_REPO" --workflow=code.yml --limit 10 \
  --json databaseId,status,conclusion,createdAt
```

### From a PR

1. The PR branch follows `agent/{issue}-{slug}`. Extract the issue number to trace the full history.

2. Find review dispatches:

```bash
gh run list --repo "$DISPATCH_REPO" --workflow=review.yml --limit 10 \
  --json databaseId,status,conclusion,createdAt
```

3. Find fix dispatches (if review requested changes):

```bash
gh run list --repo "$DISPATCH_REPO" --workflow=fix.yml --limit 10 \
  --json databaseId,status,conclusion,createdAt
```

### Reading agent logs and artifacts

```bash
# View job outcomes
gh run view <RUN_ID> --repo "$DISPATCH_REPO" --json jobs \
  -q '.jobs[] | "\(.name) \(.status)/\(.conclusion)"'

# Search logs for errors
gh run view <RUN_ID> --repo "$DISPATCH_REPO" --log 2>&1 \
  | grep -i "error\|fail\|exit code"

# Download session artifacts (JSONL traces)
gh run download <RUN_ID> --repo "$DISPATCH_REPO"
```

## Exploration strategy

You have a large amount of context to cover. Use subagents to avoid overflowing your main context window.

### Discovering the agents repo

Agent definitions, skills, harness configs, and scripts are resolved at
runtime from a separate repo — not from `fullsend-ai/fullsend`. The
workflow run log identifies this repo. Extract it during exploration:

```bash
# From an agent workflow run log, extract the agents repo
gh run view <RUN_ID> --repo "$DISPATCH_REPO" --log 2>&1 \
  | grep -oP 'Fetching agent \S+ from \K[^@]+' \
  | head -1
```

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
- **Trace reader:** "Download and read the JSONL reasoning trace for run <RUN_ID>. Summarize what decisions the agent made and why."
- **Comment analyzer:** "Read all comments on PR #N. Categorize them: agent review comments, human review comments, CI results, human interventions."
- **Pattern searcher:** "Search the last 10 retro agent issues in <REPO>. List any recurring themes or prior proposals related to <TOPIC>."
- **Harness inspector:** "Read the harness config at harness/<AGENT>.yaml and the agent definition at agents/<AGENT>.md in the agents repo. Summarize the agent's configuration and constraints."

### Keep your main context for synthesis

After subagents return their findings, use your main context to:
1. Reconstruct the timeline
2. Identify where things could have gone better
3. Form hypotheses about root causes
4. Decide what changes to propose and where

## Before proposing: check for existing issues

**This step is mandatory.** Before including any proposal in your output, verify that no open issue already covers the same improvement. The retro agent is the primary source of systemic proposals — without this check, repeated runs produce duplicate issues that waste human triage time.

For each candidate proposal, dispatch a subagent:

> "Search `<target_repo>` for open GitHub issues related to `<topic keywords>`. Return the title, number, URL, and a one-sentence description of each result. I need to know whether any of them already propose the same change I'm considering: `<proposed_change_summary>`."

The subagent should run:

```bash
# Broad keyword search across title and body
gh api \
  "search/issues?q=<topic+keywords>+repo:<target_repo>+is:issue+is:open&per_page=20" \
  --jq '.items[] | {number: .number, title: .title, url: .html_url, body: .body}'
```

Use multiple searches with different keyword combinations if the first returns no results — the same idea can be filed under different titles.

**Evaluation criteria** (apply these yourself, not the subagent):

- **Skip the proposal** if an existing open issue proposes the same or a substantially overlapping change. Reference the existing issue in your summary instead.
- **Skip the proposal** if a recently closed issue addressed the same problem (closed in the last 90 days) — the fix may already be in flight.
- **Include the proposal** only if you are confident no existing issue covers it, or if your proposal meaningfully refines an existing one in a way that warrants a new issue.

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
      "validation_criteria": "How to verify the improvement..."
    }
  ]
}
```

**Schema is strict.** The top-level object allows ONLY `summary` and `proposals` — no additional properties. Each proposal object allows ONLY the six fields shown above. The harness validates against `$FULLSEND_OUTPUT_SCHEMA` with `"additionalProperties": false` at both levels. Do not add fields like `timeline`, `metadata`, `workflow_quality`, or `originating_url`.

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

### When to propose nothing

If the workflow went well and you cannot identify meaningful improvements, write a summary saying so and return an empty proposals array. A retro that finds nothing wrong is a valid outcome.

## Constraints

The agent definition (`agents/retro.md`) is the authoritative list of prohibitions. This skill does not restate them.
