Feature: Agents triage behaviour

  Scenario: Triage applies the ready-to-code label
    Given the enrolled test repository
    And a dummy agent that would:
      | description      | op            | args                                                      |
      | Emit triage JSON | write_fixture | output/agent-result.json, fixtures/triage/sufficient.json |
    And an issue
    When the issue is labeled "ready-for-triage"
    Then the triage workflow completes successfully
    And the run selected the "dummy" runtime
    And the agent will succeed to Emit triage JSON
    And the issue has label "ready-to-code"

  # An insufficient result routes nowhere downstream.
  Scenario: Triage asks for more information on an insufficient issue
    Given the enrolled test repository
    And a dummy agent that would:
      | description      | op            | args                                                        |
      | Emit triage JSON | write_fixture | output/agent-result.json, fixtures/triage/insufficient.json |
    And an issue
    When the issue is labeled "ready-for-triage"
    Then the triage workflow completes successfully
    And the agent will succeed to Emit triage JSON
    And the issue has label "needs-info"
    And the issue does not have label "ready-to-code"
    And a comment on the issue contains "Behaviour smoke: triage needs more information"
