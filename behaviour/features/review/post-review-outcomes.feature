Feature: Review post-script outcomes

  Each scenario runs one review whose dummy agent emits a fixed verdict,
  then asserts what scripts/post-review.sh leaves on the pull request:
  the outcome label, the sticky review comment or the close.

  The review fixtures name the pull request head with <pr_head_sha>, so
  the dummy agent can only be set once the pull request exists. A review
  started by the pull request opening or being labeled checks out the
  base commit from the event, which does not have that script yet. The
  review trigger therefore matches only a human's /fs-review: opening
  and labeling the pull request start no review, and the write actor's
  /fs-review comment starts one that reads the current script.

  Background:
    Given the enrolled test repository
    And the repository agents are configured with:
      """
      review:
        trigger: >
          event.transition.kind == "comment_added"
          && has(event.entity.linked_change_proposal)
          && has(event.transition.comment.command)
          && event.transition.comment.command == "/fs-review"
          && event.actor.kind == "human"
      """

  # The default pull request path (behaviour/pr.txt) is not protected, and
  # the fixture's low risk score passes the risk gate.
  Scenario: An approving review labels the pull request ready-for-merge
    Given a pull request is opened
    And a dummy agent that would:
      | description      | op            | args                                                   |
      | Emit review JSON | write_fixture | output/agent-result.json, fixtures/review/approve.json |
    When the write actor posts "/fs-review" on the pull request
    Then the harness "review" workflow completes successfully
    And the agent will succeed to Emit review JSON
    And the review agent submitted "approved"
    And the pull request has label "ready-for-merge"

  # A changes-requested review from the review bot starts fix, which no
  # trigger can switch off; fullsend-no-fix keeps it from running.
  Scenario: A changes-requested review posts the review with fix hints
    Given a pull request is opened
    And the pull request is labeled "fullsend-no-fix"
    And a dummy agent that would:
      | description      | op            | args                                                           |
      | Emit review JSON | write_fixture | output/agent-result.json, fixtures/review/request-changes.json |
    When the write actor posts "/fs-review" on the pull request
    Then the harness "review" workflow completes successfully
    And the agent will succeed to Emit review JSON
    And the review agent submitted "changes_requested"
    And a comment on the pull request contains "Behaviour smoke: the review bot requests changes."
    And a comment on the pull request contains "disable automatic fix runs for this PR"
    And the pull request does not have label "ready-for-merge"
    And the pull request does not have label "requires-manual-review"

  # Every closed pull request dispatches retro, so its trigger is off. A
  # reject is submitted as changes requested, so fullsend-no-fix keeps fix
  # from running too.
  Scenario: A rejecting review closes the pull request
    Given the repository agents are configured with:
      """
      retro:
        trigger: "false"
      """
    And a pull request is opened
    And the pull request is labeled "fullsend-no-fix"
    And a dummy agent that would:
      | description      | op            | args                                                  |
      | Emit review JSON | write_fixture | output/agent-result.json, fixtures/review/reject.json |
    When the write actor posts "/fs-review" on the pull request
    Then the harness "review" workflow completes successfully
    And the agent will succeed to Emit review JSON
    And the review agent submitted "changes_requested"
    And the pull request has been closed
    And the pull request has label "rejected"

  # scripts/ is a protected path prefix in harness/review.yaml.
  Scenario: An approval of a protected path is downgraded to manual review
    Given a pull request that changes "scripts/x.sh"
    And a dummy agent that would:
      | description      | op            | args                                                   |
      | Emit review JSON | write_fixture | output/agent-result.json, fixtures/review/approve.json |
    When the write actor posts "/fs-review" on the pull request
    Then the harness "review" workflow completes successfully
    And the agent will succeed to Emit review JSON
    And the pull request has label "requires-manual-review"
    And the pull request does not have label "ready-for-merge"
    And a comment on the pull request contains "The review agent cannot approve PRs that touch these paths."
