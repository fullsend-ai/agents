Feature: Retro files proposals and summarises on the originating issue

  A write actor's "/fs-retro" comment on an issue dispatches retro. The
  dummy agent emits a summary and one proposal targeting the scenario's
  own repository, with a title naming the scenario's issue and a
  duplicate-search receipt of two distinct phrases (post-retro skips a
  proposal without one). The post-script must file the proposal as an
  issue labeled ready-for-triage and post the summary on the issue.

  The retro trigger matches only the "/fs-retro" comment, so pull
  requests closed in the slot window do not start stray retros. A triage
  trigger of "false" keeps the filed ready-for-triage issue from starting
  a triage that would run the retro fixture.

  Scenario: /fs-retro files a proposal issue and comments the summary
    Given the enrolled test repository
    And the repository agents are configured with:
      """
      triage:
        trigger: "false"
      retro:
        trigger: >
          event.transition.kind == "comment_added"
          && has(event.transition.comment.command)
          && event.transition.comment.command == "/fs-retro"
          && event.actor.kind == "human"
      """
    And an issue
    And a dummy agent that would:
      | description     | op            | args                                                   |
      | Emit retro JSON | write_fixture | output/agent-result.json, fixtures/retro/proposal.json |
    When the write actor posts "/fs-retro" on the issue
    Then the harness "retro" workflow completes successfully
    And an issue with label "ready-for-triage" and title containing "#<issue>" exists
    And a comment on the issue contains "Behaviour smoke: retro filed one proposal."
