Feature: Review personas come from the staged skill files

  The pr-review skill builds its roster from the persona files the runner
  staged, read through the runner's persona manifest, and tags every
  finding with the dimension (persona name) that produced it. A harness
  overlay that adds a persona to pr-review through a skill file override
  therefore gets that persona dispatched on a real review run, with no
  edit to the skill itself.

  The scenario runs a real model on the claude runtime. It needs a
  fullsend version that stages skill file overrides and writes the
  persona manifest, so it is gated behind the review-skill-overrides
  capability until the pinned fullsend module includes that support
  (enable with BEHAVIOUR_CAPABILITIES=review-skill-overrides). When
  enabling it, pin the overlay's base: to an agents commit that includes
  persona selection, with the #sha256= of that harness file, as remote
  harness resources require.

  The persona file is committed with the "a claude agent" step, which
  writes .fullsend/agents/<name>.md; the overlay maps it into pr-review
  as sub-agents/behaviour-canary.md. Its when matches only the pull
  request's behaviour-canary.txt, and it reports one finding whose
  description carries a fixed token, so the posted review shows the
  persona was chosen from its frontmatter and its finding survived the
  post-review drop of unstaged dimensions. No suite step reads the
  agent result or the ledger marker yet, so the finding's
  "dimension": "behaviour-canary" is asserted by the post-review and
  schema unit tests in this repository rather than here.

  @requires:capability:review-skill-overrides
  Scenario: A persona added by a skill file override is dispatched by a real review
    Given the enrolled test repository
    And the repository runtime is "claude"
    And a custom harness "review" with:
      """
      base: https://raw.githubusercontent.com/fullsend-ai/agents/main/harness/review.yaml
      skills:
        - skills/pr-review:
            sub-agents/behaviour-canary.md: agents/behaviour-canary.md
      trigger: >
        event.transition.kind == "comment_added"
        && has(event.entity.linked_change_proposal)
        && has(event.transition.comment.command)
        && event.transition.comment.command == "/fs-review"
        && event.actor.kind == "human"
      """
    And a claude agent "behaviour-canary" defined as:
      """
      ---
      name: behaviour-canary
      description: >-
        Behaviour-test persona that reports one fixed finding on
        behaviour-canary.txt.
      model: sonnet
      role: dimension
      when: >-
        The pull request adds or changes a file named behaviour-canary.txt.
      categories:
        - doc-style
      failure_severity: info
      tools: Read, Grep, Glob
      ---

      # Behaviour canary

      You are a behaviour-test persona. Do not review anything else.

      Return exactly this JSON array and nothing else:

      [{"severity": "low", "category": "doc-style", "file": "behaviour-canary.txt", "line": 1, "description": "BEHAVIOUR-CANARY-PERSONA finding from the custom persona.", "actionable": false}]
      """
    And a pull request that changes "behaviour-canary.txt"
    When the write actor posts "/fs-review" on the pull request
    Then the harness "review" workflow completes successfully
    And the run selected the "claude" runtime
    And a comment on the pull request contains "BEHAVIOUR-CANARY-PERSONA"
