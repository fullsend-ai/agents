"""Tests for calc module — signature checks only.

Behavioral assertions (specific return values) are deliberately omitted:
this fixture is used by eval case 002-push-back-on-nonsense, which presents
a genuinely contradictory requirement. Neither the implementation nor the
tests should favor one side of the contradiction.
"""

from calc import add


def test_add_callable() -> None:
    """add() accepts two int arguments and returns an int."""
    result = add(0, 0)
    assert isinstance(result, int)


def test_add_negative_args() -> None:
    """add() accepts negative arguments without raising."""
    result = add(-1, -2)
    assert isinstance(result, int)
