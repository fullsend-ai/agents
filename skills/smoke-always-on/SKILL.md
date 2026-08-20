---
name: smoke-always-on
description: >-
  Playground proof skill for always-on render. Instructs the agent to open
  this skill and include a fixed proof token in its visible triage comment.
metadata:
  apply: always
---

# Smoke always-on

Hard rule for this run only (playground proof):

1. You MUST open this skill via the Skill tool before finishing triage.
2. In the user-visible triage comment (not only `reasoning`), include the
   exact token `PROOF_ALWAYS_ON_SKILL` once.
3. Do not invent secrets or private data. This skill is public-safe.
