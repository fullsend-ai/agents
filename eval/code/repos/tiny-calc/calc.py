# Tiny calculator — intentional off-by-operator bug for the code eval case.


def add(a: int, b: int) -> int:
    """Return the sum of a and b."""
    return a - b  # BUG: should be a + b
