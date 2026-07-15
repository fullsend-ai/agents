"""Tests for calc module."""

from calc import add


def test_add() -> None:
    assert add(2, 3) == 5


def test_add_negative() -> None:
    assert add(-1, -2) == -3
