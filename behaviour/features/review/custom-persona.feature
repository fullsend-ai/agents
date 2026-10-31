Feature: Review personas come from the staged skill files

  The pr-review skill builds its roster from the persona files the runner
  staged, read through the runner's persona manifest, and tags every
  finding with the dimension (persona name) that produced it. A harness
  overlay that adds a persona to pr-review through a skill file override
  therefore gets that persona dispatched on a real review run, with no
  edit to the skill itself.

  The scenario runs a real model on the claude runtime, in CI, as one
  small run on Haiku. The runtime is set per agent on the review entry
  in agents:, because the suite's dummy runtime comes from a layered
  config preset rather than the repository's own config. The overlay
  sets model haiku and effort low, and points Claude Code's opus and
  sonnet names at Haiku inside the sandbox (the eval/harness/review.yaml
  pattern), so no persona runs Opus or Sonnet. It needs a fullsend
  version that stages skill file overrides and writes the persona
  manifest, so it is gated behind the review-skill-overrides capability,
  which the Makefile enables by default. The overlay's base: is pinned
  to an agents commit that includes persona selection, with the #sha256=
  of that harness file, as remote harness resources require.

  The primary check does not depend on the model: the review harness run
  logs "applying its file overrides to base skill", which shows the
  overlay's pr-review entry was applied on top of the base harness's
  skill.

  The persona file is committed with the "a claude agent" step, which
  writes .fullsend/agents/<name>.md; the overlay maps it into pr-review
  as sub-agents/behaviour-canary.md. It is always: true and its when
  names behaviour-canary.txt, so it is selected. It builds a marker from
  line 1 of that file (the pull request step writes "behaviour test", so
  the marker is CANARY-behaviour-test) and returns it in its finding.
  The review run's log streams each sub-agent's reply, so finding the
  marker there proves the persona was dispatched and ran on the pull
  request. The marker is computed rather than written in the persona
  file because another persona reading the canary file must not satisfy
  the check. The posted review text is written by the model, which may
  paraphrase the finding, so it is not asserted. No suite step reads the
  agent result or the ledger marker yet, so the finding's
  "dimension": "behaviour-canary" is asserted by the post-review and
  schema unit tests in this repository rather than here.

  The review entry's trigger matches only a human's /fs-review, so
  opening the pull request starts no review. A changes-requested review
  would start fix and closing the pull request would start retro, so
  fullsend-no-fix and a retro trigger of "false" keep this scenario to
  the one review run.

  @requires:capability:review-skill-overrides
  Scenario: A persona added by a skill file override is dispatched by a real review
    Given the enrolled test repository
    And a custom harness "review" with:
      """
      base: https://raw.githubusercontent.com/fullsend-ai/agents/d3566f0121a05d2ac8d642c1a96b7488d12fde4c/harness/review.yaml#sha256=c6db342731181835bf1f006cf9fda21e84e0771995d8436b4465d2ce26bb95bc
      model: haiku
      effort: low
      env:
        sandbox:
          ANTHROPIC_DEFAULT_OPUS_MODEL: claude-haiku-5-5
          ANTHROPIC_DEFAULT_SONNET_MODEL: claude-haiku-5-5
      skills:
        - skills/pr-review:
            sub-agents/behaviour-canary.md: agents/behaviour-canary.md
      """
    And the repository agents are configured with:
      """
      review:
        runtime: claude
        trigger: >
          event.transition.kind == "comment_added"
          && has(event.entity.linked_change_proposal)
          && has(event.transition.comment.command)
          && event.transition.comment.command == "/fs-review"
          && event.actor.kind == "human"
      retro:
        trigger: "false"
      """
    And a claude agent "behaviour-canary" defined as:
      """
      ---
      name: behaviour-canary
      description: >-
        Behaviour-test persona that reports one fixed finding on
        behaviour-canary.txt.
      model: haiku
      role: dimension
      always: true
      when: >-
        The pull request changes behaviour-canary.txt.
      categories:
        - doc-style
      failure_severity: info
      tools: Read, Grep, Glob
      ---

      # Behaviour canary

      You are a behaviour-test persona. Do not review anything else.

      Read line 1 of behaviour-canary.txt. Build a marker: the word
      CANARY, a hyphen, then that line with every space replaced by a
      hyphen.

      Return one JSON array with exactly one finding and nothing else:
      severity "low", category "doc-style", file "behaviour-canary.txt",
      line 1, actionable false, and a description that starts with the
      marker, then ": line 1 has no heading."
      """
    And a pull request that changes "behaviour-canary.txt"
    And the pull request is labeled "fullsend-no-fix"
    When the write actor posts "/fs-review" on the pull request
    Then the harness "review" workflow completes successfully
    And the harness "review" workflow logs contain "applying its file overrides to base skill"
    And the run selected the "claude" runtime from "agents.review"
    And the harness "review" workflow logs contain "CANARY-behaviour-test"
