Feature: Fix applier pushes to the pull request branch

  A write actor's "/fs-fix" comment on a pull request dispatches the fix
  stage through the bash route in fullsend's reusable-dispatch.yml. The
  dummy agent checks out the pull request's head branch, which records a
  marker commit, and emits a fix result. The post-script must push that
  commit to the pull request branch and post the fix summary comment.
  The agent's branch must equal the pull request head, or post-fix
  refuses to push with a branch mismatch. The fixture's pr_number is
  only schema-checked: post-fix comments on the dispatched pull request.

  A review trigger of "false" keeps the opened pull request, and the
  synchronize event from the fix push, from starting a review that would
  run the fix fixture.

  Scenario: /fs-fix pushes the fix commit and posts the summary
    Given the enrolled test repository
    And the repository agents are configured with:
      """
      review:
        trigger: "false"
      """
    And an issue
    And an open pull request on branch "agent/<issue>-fix"
    And the tip of branch "agent/<issue>-fix" is recorded
    And a dummy agent that would:
      | description          | op              | args                                                |
      | Check out fix branch | checkout_branch | agent/<issue>-fix                                   |
      | Emit fix JSON        | write_fixture   | output/agent-result.json, fixtures/fix/summary.json |
    When the write actor posts "/fs-fix" on the pull request
    Then the harness "fix" workflow completes successfully
    And branch "agent/<issue>-fix" has advanced
    And a comment on the pull request contains "Fix agent — iteration"
