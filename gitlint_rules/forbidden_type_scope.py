"""Custom gitlint rule to reject forbidden type(scope) combinations.

COMMITS.md defines forbidden type+scope pairs that put infrastructure
changes in user-facing categories.  This rule enforces that table at
lint time so violations never reach main.
"""

import re

from gitlint.options import ListOption
from gitlint.rules import CommitMessageTitle, LineRule, RuleViolation


class ForbiddenTypeScope(LineRule):
    """Reject commits whose type(scope) matches a forbidden combination."""

    name = "forbidden-type-scope"
    id = "UL1"
    target = CommitMessageTitle

    options_spec = [
        ListOption(
            "forbidden",
            ["fix(ci)", "feat(ci)", "fix(e2e)", "feat(e2e)"],
            "Comma-separated list of forbidden type(scope) combinations.",
        ),
    ]

    def validate(self, line, _commit):
        # Extract the type(scope) prefix from a conventional commit title.
        # Handles optional '!' for breaking changes: "fix(ci)!: ..."
        match = re.match(r"^([a-z]+\([^)]+\))!?:", line)
        if not match:
            return None

        type_scope = match.group(1)
        forbidden = self.options["forbidden"].value

        if type_scope in forbidden:
            return [
                RuleViolation(
                    self.id,
                    f"Forbidden type(scope) '{type_scope}' — see COMMITS.md "
                    f"for alternatives. Disallowed: {', '.join(forbidden)}",
                    line,
                ),
            ]

        return None
