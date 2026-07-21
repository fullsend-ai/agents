"""Tests for datemath.calc."""

import pytest
from datemath.calc import days_until


def test_days_until_same_day():
    assert days_until("2025-06-15", "2025-06-15") == 1


def test_days_until_inclusive():
    assert days_until("2025-01-01", "2025-01-03") == 3


def test_days_until_one_day_apart():
    assert days_until("2025-03-01", "2025-03-02") == 2


def test_days_until_cross_month():
    assert days_until("2025-01-30", "2025-02-02") == 4


def test_days_until_raises_on_reversed():
    with pytest.raises(ValueError, match="before start"):
        days_until("2025-06-15", "2025-06-10")
