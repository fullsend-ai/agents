"""Tests for analytics module."""

from datetime import datetime

from src.analytics import Event


def test_event_creation():
    e = Event("click", datetime(2024, 1, 1), 1.0)
    assert e.name == "click"
    assert e.value == 1.0


def test_event_repr():
    e = Event("click", datetime(2024, 1, 1), 1.0)
    assert "click" in repr(e)
