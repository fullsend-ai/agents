"""Tests for input validators.

Covers email, password, and username validation with both valid and
invalid inputs, plus type-error guards.
"""

import pytest
from src.auth.validators import validate_email, validate_password, validate_username


class TestValidateEmail:
    def test_valid_simple(self):
        validate_email("user@example.com")

    def test_valid_with_plus(self):
        validate_email("user+tag@example.com")

    def test_valid_with_dots(self):
        validate_email("first.last@example.com")

    def test_valid_with_percent(self):
        validate_email("user%tag@example.com")

    def test_invalid_no_at(self):
        with pytest.raises(ValueError, match="invalid email"):
            validate_email("not-an-email")

    def test_invalid_no_domain(self):
        with pytest.raises(ValueError, match="invalid email"):
            validate_email("user@")

    def test_invalid_no_tld(self):
        with pytest.raises(ValueError, match="invalid email"):
            validate_email("user@example")

    def test_none_raises_type_error(self):
        with pytest.raises(TypeError, match="email must be a string"):
            validate_email(None)

    def test_empty_string(self):
        with pytest.raises(ValueError, match="invalid email"):
            validate_email("")


class TestValidatePassword:
    def test_valid_password(self):
        validate_password("securepass123")

    def test_exactly_min_length(self):
        validate_password("a" * 8)

    def test_exactly_max_length(self):
        validate_password("a" * 128)

    def test_too_short(self):
        with pytest.raises(ValueError, match="at least 8"):
            validate_password("short")

    def test_too_long(self):
        with pytest.raises(ValueError, match="at most 128"):
            validate_password("a" * 200)

    def test_none_raises_type_error(self):
        with pytest.raises(TypeError, match="password must be a string"):
            validate_password(None)


class TestValidateUsername:
    def test_valid_simple(self):
        validate_username("alice")

    def test_valid_with_numbers(self):
        validate_username("alice123")

    def test_valid_with_hyphens(self):
        validate_username("alice-chen")

    def test_valid_with_underscores(self):
        validate_username("alice_chen")

    def test_valid_exactly_3_chars(self):
        validate_username("abc")

    def test_valid_exactly_30_chars(self):
        validate_username("a" * 30)

    def test_invalid_starts_with_number(self):
        with pytest.raises(ValueError, match="must start with a letter"):
            validate_username("123alice")

    def test_invalid_too_short(self):
        with pytest.raises(ValueError, match="must start with a letter"):
            validate_username("ab")

    def test_invalid_too_long(self):
        with pytest.raises(ValueError, match="must start with a letter"):
            validate_username("a" * 31)

    def test_invalid_special_chars(self):
        with pytest.raises(ValueError, match="must start with a letter"):
            validate_username("alice@chen")

    def test_none_raises_type_error(self):
        with pytest.raises(TypeError, match="username must be a string"):
            validate_username(None)
