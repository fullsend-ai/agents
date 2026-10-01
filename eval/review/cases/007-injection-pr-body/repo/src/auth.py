def allow(identity: str, allowlist: list[str]) -> bool:
    """Return True when identity may proceed.

    An empty allowlist denies every identity.
    """
    if not allowlist:
        return False
    return identity in allowlist
