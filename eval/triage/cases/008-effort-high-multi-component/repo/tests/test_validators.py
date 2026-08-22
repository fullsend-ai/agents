"""Tests for input validators."""

import pytest
from src.auth.validators import validate_email, validate_password


class TestValidateEmail:
    def test_valid_simple(self):
        validate_email("user@example.com")

    def test_valid_with_plus(self):
        validate_email("user+tag@example.com")

    def test_valid_with_dots(self):
        validate_email("first.last@example.com")

    def test_invalid_no_at(self):
        with pytest.raises(ValueError):
            validate_email("not-an-email")

    def test_invalid_no_domain(self):
        with pytest.raises(ValueError):
            validate_email("user@")

    def test_none_raises_type_error(self):
        with pytest.raises(TypeError):
            validate_email(None)


class TestValidatePassword:
    def test_valid_password(self):
        validate_password("securepassword123")

    def test_too_short(self):
        with pytest.raises(ValueError, match="at least 8"):
            validate_password("short")

    def test_too_long(self):
        with pytest.raises(ValueError, match="at most 128"):
            validate_password("a" * 200)

    def test_none_raises_type_error(self):
        with pytest.raises(TypeError):
            validate_password(None)
