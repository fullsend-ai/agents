"""Shared screen for invisible and directional instruction text."""

import unicodedata


def has_hidden_text(value):
    return any(
        (unicodedata.category(c) in {"Cc", "Cf", "Co", "Cs"} and c not in "\t\n\r")
        or ord(c) in {0x034F, 0x115F, 0x1160, 0x3164, 0xFFA0, 0x2028, 0x2029, 0x2800}
        or 0x2060 <= ord(c) <= 0x206F
        or 0xFFF0 <= ord(c) <= 0xFFF8
        or 0xE0000 <= ord(c) <= 0xE0FFF
        or 0xFE00 <= ord(c) <= 0xFE0F
        or 0xE0100 <= ord(c) <= 0xE01EF
        for c in value
    )
