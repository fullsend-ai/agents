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
