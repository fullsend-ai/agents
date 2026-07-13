"""Tests for calc module."""

from src.calc import add, subtract


def test_add():
    assert add(2, 3) == 5


def test_add_negative():
    assert add(-1, -2) == -3


def test_subtract():
    assert subtract(10, 4) == 6


def test_subtract_negative():
    assert subtract(3, 7) == -4
