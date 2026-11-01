Feature: Prioritize posts the RICE score on the issue

  A write actor's "/fs-prioritize" comment on an issue dispatches
  prioritize. The dummy agent emits RICE scores chosen so the
  post-script's score, round2(R*I*C/E) = round2(2*3*0.5/2), is exactly
  1.5. The post-script must post its sticky RICE comment on the issue.

  Scenario: /fs-prioritize posts the RICE score comment
    Given the enrolled test repository
    And an issue
    And a dummy agent that would:
      | description          | op            | args                                                    |
      | Emit prioritize JSON | write_fixture | output/agent-result.json, fixtures/prioritize/rice.json |
    When the write actor posts "/fs-prioritize" on the issue
    Then the harness "prioritize" workflow completes successfully
    And a comment on the issue contains "<!-- fullsend:prioritize-agent -->"
    And a comment on the issue contains "RICE Priority Score: 1.5"
