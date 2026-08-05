"""Tests for the user database layer."""

from src.db.users import (
    get_all_users,
    get_user_by_id,
    get_user_by_email,
    update_user,
    delete_user,
    USERS,
)


class TestGetAllUsers:
    def test_returns_list(self):
        result = get_all_users()
        assert isinstance(result, list)
        assert len(result) > 0

    def test_contains_expected_users(self):
        users = get_all_users()
        emails = [u["email"] for u in users]
        assert "alice@example.com" in emails


class TestGetUserById:
    def test_existing_user(self):
        user = get_user_by_id("user-alice")
        assert user is not None
        assert user["email"] == "alice@example.com"

    def test_missing_user(self):
        assert get_user_by_id("user-nonexistent") is None


class TestGetUserByEmail:
    def test_existing_email(self):
        user = get_user_by_email("bob@example.com")
        assert user is not None
        assert user["id"] == "user-bob"

    def test_missing_email(self):
        assert get_user_by_email("nobody@example.com") is None


class TestUpdateUser:
    def test_update_existing(self):
        original_name = USERS["user-bob"]["name"]
        update_user("user-bob", {"name": "Robert Martinez"})
        assert USERS["user-bob"]["name"] == "Robert Martinez"
        # Restore
        USERS["user-bob"]["name"] = original_name

    def test_update_missing(self):
        assert update_user("user-nonexistent", {"name": "Ghost"}) is False


class TestDeleteUser:
    def test_delete_existing(self):
        USERS["user-temp"] = {"id": "user-temp", "email": "temp@example.com"}
        assert delete_user("user-temp") is True
        assert "user-temp" not in USERS

    def test_delete_missing(self):
        assert delete_user("user-nonexistent") is False
