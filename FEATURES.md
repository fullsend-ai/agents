# Adding a Configuration Option to an Agent

Checklist for introducing a new configurable behavior to an agent.
Use this to avoid missing integration points — the system has several
layers and a change that only touches one may silently fail or not behave as
you expect.

A new configuration option often falls into one of three categories:

1. **Scripts only** — the change lives entirely in the pre-script or
   post-script. The agent prompt and skills are unchanged. Example:
   gating whether the agent runs at all based on an env var.
2. **Agent only** — the change lives in the agent prompt or a skill.
   The pre/post scripts are unchanged. Example: adding a skill that
   changes how the agent evaluates an issue.
3. **Agent + scripts** — the agent needs to produce new information and
   the post-script needs to consume it. This usually also requires a
   schema update (`schemas/<agent>-result.schema.json`) to accommodate
   whatever new field the agent uses to expose its conclusions to the
   post-script. Example: the `requires_workflow_changes` flag in triage.

## 1. Decide what changes and what stays the same

Before writing code, answer:

- **What is the current default behavior?** Document it explicitly.
- **Will the default change?** If yes, that could be considered a breaking
  change.  Prefer keeping the existing behavior as the default and making the
  *new* behavior opt-in.

## 2. Choose the configuration surface

| Surface | When to use | Example |
|---------|-------------|---------|
| **Environment variable** | Runtime behavior toggle, simple values. Repo owners set it in their `.fullsend/` harness overlay or workflow inputs. The agent prompt, pre-script, or post-script reads the var and adjusts behavior. | `CODE_ALLOWED_TARGET_BRANCHES` |
| **Skill override** | The behavior is best expressed as natural-language instructions to the agent. Repo owners drop a replacement skill in `.agents/skills/` or org owners in `.fullsend/customized/skills/`. | `issue-labels` skill |

Environment variables are the simplest for end users to configure.
Skills are more flexible — they let repo or org owners override
behavior with natural-language instructions without forking the agent
definition.

## 3. Env var placement — sandbox vs. runner vs. both

The harness separates the sandbox (where the agent runs) from the
runner (where pre/post scripts run). An env var must be in the right
place:

| Where the var is read | Where needs to declare it |
|-----------------------|---------------------|
| Agent prompt only (sandbox) | `env.sandbox` in `harness/<agent>.yaml` |
| Pre/post script only (runner) | `env.runner` in `harness/<agent>.yaml` |
| Both agent and scripts | Both `env.sandbox` and `env.runner` |

Use `forge.github.env.sandbox` and `forge.github.env.runner` only if you need
environment variables with different values between github and gitlab.

## 4. Update the subagent definition file

If the agent needs to know about the new option:

- [ ] Add the env var to the `## Inputs` section of `agents/<agent>.md`
- [ ] Add conditional behavior to the agent prompt. Keep it minimal —
      describe the env var's meaning and what the agent should do
      differently. Don't add a paragraph where a sentence will do.
- [ ] If the default is "do what you already do," make the prompt change
      a conditional block: "If `$VAR` is set to `X`, then..."
- [ ] Exhort the agent to expose new information via its output schema, if
      necessary for processing in the post script.

## 5. Update pre/post scripts

Ask yourself:

- [ ] **Pre-script:** Does the new option affect how the agent gathers input
      before it runs? Does the new option affect whether the agent should run at
      all? The [skipped=true
      mechanism](https://fullsend.sh/docs/guides/user/building-custom-agents.html#skipping-the-run-from-the-pre-script)
      in the pre-script lets you skip the agent entirely based on configuration.
- [ ] **Post-script:** Does the new option change how the agent's output
      is applied?  If your option changes output label behavior, comment
      content, or whether to suppress output entirely, the post script is where
      that logic lives.
- [ ] **Both:** Some features may require changes in both.

## 6. Update the harness definition

In `harness/<agent>.yaml`:

- [ ] Add the env var to the appropriate sections (see step 3)
- [ ] If the var needs a default that differs from empty-string, set it
      with shell default syntax: `${VAR:-default_value}`

## 7. Update the schema (if the agent output changes)

If the new option adds a field to the agent's JSON output:

- [ ] Add the field to `schemas/<agent>-result.schema.json`
- [ ] Make it optional (`"required"` array unchanged) unless every
      invocation must produce it
- [ ] Add conditional validation in `allOf` if the field is required
      only for certain actions
- [ ] Run `scripts/validate-output-schema-test.sh` to verify

## 8. Check skill impact

If your change modifies a skill rather than (or in addition to) the
agent prompt:

- [ ] Check which other agents use that skill:
      `grep -r '<skill-name>' agents/ harness/`
- [ ] If the env var is agent-specific, consider whether or not it should be
      baked into that skill.  Keep agent-specific logic in the agent prompt;
      keep reusable judgment in the skill.
- [ ] If you add a new skill, add it to `harness/<agent>.yaml` under
      `skills:` and to the agent frontmatter `skills:` array.

## 9. Update documentation

- [ ] `docs/<agent>.md` — add the variable to the `### Variables`
      table. If the table says "None," replace it.
- [ ] Keep the description to one line in the table; link to and expand a
      section below if it needs explanation.
- [ ] If you added or modified a skill, update its `SKILL.md` and
      document it in `docs/<agent>.md` under the `### Skill:` section
      (see `docs/triage.md` for an example with `issue-labels`).

## 10. Update tests

- [ ] **Post-script tests** (`scripts/post-<agent>-test.sh`) — add
      cases for the new option: default behavior preserved, option
      set to each valid value, invalid/empty values handled.
- [ ] **Pre-script tests** (if the pre-script changed).
- [ ] **Schema tests** (`scripts/validate-output-schema-test.sh`) — if
      you changed the schema.
- [ ] Run the full test suite: `make test`

## 11. Check network policy

If the new option requires the agent to reach a new external service
from the sandbox:

- [ ] Update `policies/<agent>.yaml` to allow the new host/port
- [ ] This is rare — most configuration changes don't need network
      changes

## 12. Review checklist

Before opening the PR, verify:

- [ ] The existing default behavior is preserved when the option is
      unset, unless you're sure it should change
- [ ] The env var appears in every layer it needs to (env file, harness
      yaml sandbox/runner, forge sections)
- [ ] Tests cover both the default and the configured case
- [ ] Documentation is updated
- [ ] No other agent is broken by a skill change
- [ ] The lint passes: `make lint`
