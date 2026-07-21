"""Date arithmetic helpers."""

from datetime import date


def parse_date(date_str: str) -> date:
    """Parse an ISO-8601 date string (YYYY-MM-DD) into a date object."""
    return date.fromisoformat(date_str)


def days_until(start: str, end: str) -> int:
    """Return the inclusive count of days from *start* to *end*.

    Both endpoints are included in the count, so
    ``days_until("2025-01-01", "2025-01-03")`` returns 3
    (Jan 1, Jan 2, Jan 3).

    Raises ``ValueError`` if *end* is before *start*.
    """
    s = parse_date(start)
    e = parse_date(end)
    if e < s:
        raise ValueError(f"end date {end} is before start date {start}")
    return (e - s).days
