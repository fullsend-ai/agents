"""Order pricing calculations."""


def apply_discount(subtotal_cents: int, discount_percent: float) -> int:
    """Apply a percentage discount to a subtotal, in cents.

    discount_percent is a whole number percentage (e.g. 10 for 10%).
    """
    if not 0 <= discount_percent <= 100:
        raise ValueError("discount_percent must be between 0 and 100")
    return round(subtotal_cents * (100 - discount_percent) / 100)
