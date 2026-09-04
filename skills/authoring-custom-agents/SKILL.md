---
name: authoring-custom-agents
description: >-
  Use when completing an agent skeleton produced by `fullsend agent new` —
  filling in the agent definition, keeping the result schema, the prompt and
  the post-script in agreement, and validating the result before committing.
---

# Authoring custom agents

`fullsend agent new <name>` writes a valid, registered agent. Everything is
complete except the prompt. Your job is to finish `agents/<name>.md` without
breaking the contract the other generated files encode.

Three of those files matter here. The **agent definition**
(`agents/<name>.md`) is the prompt — the instructions the agent follows. The
**result schema** describes the single JSON object the agent must write. The
**post-script** (`scripts/post-<name>.sh`) runs afterwards, on the machine
outside the sandbox, and is the only thing that touches the issue or pull
request. The agent itself changes nothing.

For diagnosing why an existing agent underperforms, use `agent-scaffolding`
instead — this skill is the authoring procedure, not the evaluation lens.

## What the generator produced

| File | Yours to edit? |
|---|---|
| `agents/<name>.md` | **Yes — this is the work.** |
| `schemas/<name>-result.schema.json` | Only alongside the prompt and post-script |
| `scripts/post-<name>.sh` | Only if the result shape changes |
| `harness/<name>.yaml` (how it runs: image, timeout, trigger) | Only to change how it runs, not what it does |
| `policies/`, `providers/`, `profiles/` | No — shared by every agent here |

## Procedure

1. **Replace every `<!-- FILL IN -->` marker.** Leaving one is a lint failure
   in repositories that run `skillsaw --strict`, and a vague step is the most
   common reason a custom agent produces unusable output.

2. **Write the Steps section as commands, not intentions.** Name the exact
   command to run, the exact files to read, and the thresholds that decide the
   outcome. "Analyse the changes" produces nothing reproducible; "run
   `gh pr diff --name-only`, keep `.md` files, resolve each relative link
   against the file's directory" does.

3. **State the decision boundary explicitly.** Say what makes the result `ok`
   rather than `findings` rather than `error`. If you cannot write that
   sentence, the agent does not yet have a job.

4. **Keep three things in agreement.** They are checked by different
   mechanisms at different times, so a mismatch fails late:
   - the `## Output contract` section of the prompt,
   - `required` and `properties` in the result schema,
   - the fields the post-script reads.
   Adding a field means editing all three.

5. **Keep `tools:` matching the body.** The frontmatter grants exactly what the
   Steps use. If you add a step that runs `git`, add it to `tools:`; if you
   drop the step, drop the tool.

6. **Leave mutation to the post-script.** The prompt must forbid pushing,
   commenting, labelling and every other mutating call. The agent's only
   output is the JSON result file. This is what makes model output safe to act
   on: the post-script validates and allowlists it.

## Validate before committing

```bash
fullsend lock <name> --fullsend-dir <dir> --offline
```

```
  ✓ Harness has no remote dependencies — nothing to lock
```

That loads the agent the same way the automation does when a real event
arrives, so a mistake shows up now rather than the first time it runs.
`--offline` proves the agent needs nothing from the network.

`fullsend agent list` only lists what is registered — it never opens these
files, so a clean listing does not mean the agent works.

## Before you call it done

- Every `FILL IN` marker is gone.
- The Output contract, the schema and the post-script name the same fields.
- `tools:` lists exactly what the Steps use.
- The prompt forbids mutation.
- `fullsend lock <name> --fullsend-dir <dir> --offline` passes.

See `examples/link-check/` in this repository for a completed agent generated
this way.
