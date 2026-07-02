---
name: agent-scaffolding
description: >-
  Use when diagnosing why agents underperform or ideating improvements to
  agent infrastructure — skills, agent definitions, harness configs,
  AGENTS.md files, hooks, CI gates, or context files.
---

# Agent Scaffolding

Diagnose scaffolding problems and propose improvements. This is a lens
for evaluating what exists, not a setup checklist.

## Core principles

These are ordered by impact. When diagnosing or proposing changes,
evaluate against the higher-impact principles first.

### 1. Verification > documentation

Giving agents a way to verify their work is the single highest-leverage
scaffolding investment. A runnable test suite, a fast linter, a
type-checker — these create tight feedback loops that let agents
self-correct. Documentation without verification is the agent equivalent
of "trust me, bro."

**Diagnostic questions:**
- Can the agent run tests with a single command, without external
  dependencies?
- Can the agent lint or type-check a single file in under 2 seconds?
- Does CI surface failures clearly, or are they buried in noise?

### 2. Deterministic enforcement > advisory instructions

Prose instructions in context files are advisory — the agent may follow
them, may not. Hooks and lint rules are deterministic — they always
execute. When a convention matters, enforce it mechanically.

**Diagnostic questions:**
- Is a recurring agent mistake caused by an advisory instruction that
  should be a hook or lint rule?
- Are there hooks that auto-format, block destructive operations, or
  validate outputs?
- Could a lint rule catch this class of error before review?

### 3. Minimal, hand-written context

Auto-generated context files (e.g., shipping `/init` output unedited)
reduce agent success rates by ~3% and increase costs by 20-23%.
Human-written context helps only marginally (+4%). Agents are good at
discovering repo structure on their own — only tell them things they
cannot figure out by reading the code.

**Diagnostic questions:**
- Is the context file under 150 lines? Over 300 is a red flag.
- Does every line pass the litmus test: "Would removing this cause the
  agent to make a mistake it wouldn't otherwise make?"
- Does the context file duplicate information the agent can discover
  from the code, directory structure, or existing docs?

### 4. Progressive disclosure

Root context routes the agent to the right area. Skills and
component-level files provide depth on demand. Loading everything
upfront dilutes the context that matters.

**Diagnostic questions:**
- Is the root context file trying to do too much? Should some of it be
  a skill that loads only when needed?
- Are there path-scoped rules for modules with non-obvious conventions?
- Could on-demand skills replace sections of a bloated context file?

### 5. Pattern references > narratives

"Follow the pattern in `src/api/handlers/users.ts`" is more reliable
than a paragraph explaining the pattern. Agents handle copy-modify
changes far better than novel changes from prose descriptions.

**Diagnostic questions:**
- Are the 3-5 most common change types documented as pattern
  references?
- Could a failing agent task succeed if pointed to an existing example?

### 6. Design intent for what code can't say

Agents discover *what* code does by reading it, but not *why* it was
designed that way. When invariants, preconditions, and design rationale
are undocumented, agents make changes that pass tests but violate design
contracts.

**Diagnostic questions:**
- Did the agent violate an undocumented invariant or precondition?
- Is there a design rationale that should be captured so agents don't
  repeat this class of mistake?

## Applying principles to infrastructure

**Skills** — Narrow, self-contained, loads only when needed. Write
specific trigger descriptions. Know whether you're writing a rigid
procedure or a flexible reference. Don't restate the agent definition.

**Agent definitions** — Short and stable; changes affect every run.
Prohibitions belong here, not in skills. When the agent keeps doing
something wrong, ask: constraint (agent def), procedure (skill), or
enforcement (hook/lint)?

**Harness configs** — Determines what the agent *can* do (vs. *should*
do). Too-tight sandbox causes undiagnosable failures; too-loose creates
risk. Missing runtime context may be a harness fix, not a prompt fix.

**Context files** — Under 150 lines, hard cap 300. Build commands, test
commands, key conventions, PR rules. For large repos, the root file is a
routing layer. Treat recurring review comments as update signals.

**Hooks** — Start with auto-format and blocking destructive operations.
Commit shared hooks so they apply to every agent. A blocking hook beats
a context file line asking the agent not to do it.
