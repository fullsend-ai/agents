# Measurement manifests

Per-agent YAML that selects which **eval measurement** scorers run after a
managed agent job (`fullsend eval-measure`). This is **not** the functional
eval harness under `eval/<agent>/` (PR-gate scenarios / fixtures).

- **Scorers** (Go logic) live in `fullsend-ai/fullsend` (`internal/evalmeasure/`).
- **Manifests** (which scorers for which agent) live here.

At first ship, six agents enable the `trace_fitness` scorer (em-001): code, fix,
prioritize, retro, review, and triage. Omit a file to opt an agent out (e.g.
scribe has no forge work-item identity today).

See fullsend ADR 0087 and the Eval Measurements guide in `fullsend-ai/fullsend`.
