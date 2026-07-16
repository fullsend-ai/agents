"""Analytics utilities for event processing."""

from datetime import datetime


class Event:
    """Represents a tracked event."""

    def __init__(self, name: str, timestamp: datetime, value: float = 0.0):
        self.name = name
        self.timestamp = timestamp
        self.value = value

    def __repr__(self):
        return f"Event({self.name!r}, {self.timestamp}, {self.value})"
