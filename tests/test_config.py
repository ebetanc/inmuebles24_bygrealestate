"""Tests for the Settings config loader."""
from __future__ import annotations

import os
import pytest

from inmobiliaria24.config import Settings


@pytest.fixture(autouse=True)
def clear_env_vars(monkeypatch):
    """Ensure credentials are cleared before each test to prevent .env file bleed-through."""
    monkeypatch.delenv("INMUEBLES24_EMAIL", raising=False)
    monkeypatch.delenv("INMUEBLES24_PASSWORD", raising=False)


def test_load_with_both_vars_set(monkeypatch):
    """Test 1: Settings.load() with both env vars set returns correct Settings object."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "agent@example.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "s3cr3tpass")

    settings = Settings.load(env_file="/dev/null")

    assert settings.email == "agent@example.com"
    assert settings.password == "s3cr3tpass"


def test_load_missing_email_raises_value_error(monkeypatch):
    """Test 2: Settings.load() with INMUEBLES24_EMAIL missing raises ValueError naming it."""
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "s3cr3tpass")

    with pytest.raises(ValueError) as exc_info:
        Settings.load(env_file="/dev/null")

    assert "INMUEBLES24_EMAIL" in str(exc_info.value)


def test_load_missing_password_raises_value_error(monkeypatch):
    """Test 3: Settings.load() with INMUEBLES24_PASSWORD missing raises ValueError naming it."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "agent@example.com")

    with pytest.raises(ValueError) as exc_info:
        Settings.load(env_file="/dev/null")

    assert "INMUEBLES24_PASSWORD" in str(exc_info.value)


def test_load_both_vars_missing_raises_value_error(monkeypatch):
    """Test 4: Settings.load() with both vars missing raises ValueError."""
    with pytest.raises(ValueError) as exc_info:
        Settings.load(env_file="/dev/null")

    error_msg = str(exc_info.value)
    assert "INMUEBLES24_EMAIL" in error_msg or "INMUEBLES24_PASSWORD" in error_msg


def test_password_not_in_repr(monkeypatch):
    """Test 5: Settings repr does not expose password value."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "agent@example.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "s3cr3tpass")

    settings = Settings.load(env_file="/dev/null")

    repr_output = repr(settings)
    str_output = str(settings)

    assert "s3cr3tpass" not in repr_output
    assert "s3cr3tpass" not in str_output
