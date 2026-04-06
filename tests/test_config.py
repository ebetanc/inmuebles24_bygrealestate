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
    monkeypatch.delenv("PROXY_HOST", raising=False)
    monkeypatch.delenv("PROXY_PORT", raising=False)
    monkeypatch.delenv("PROXY_USER", raising=False)
    monkeypatch.delenv("PROXY_PASS", raising=False)
    monkeypatch.delenv("WEBHOOK_URL", raising=False)
    monkeypatch.delenv("HEARTBEAT_URL", raising=False)
    monkeypatch.delenv("STATE_DIR", raising=False)


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


def test_load_with_proxy_vars(monkeypatch):
    """Proxy settings are loaded when all proxy vars are set."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "a@b.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "pass")
    monkeypatch.setenv("PROXY_HOST", "zproxy.lum-superproxy.io")
    monkeypatch.setenv("PROXY_PORT", "22225")
    monkeypatch.setenv("PROXY_USER", "brd-customer-123")
    monkeypatch.setenv("PROXY_PASS", "proxypass")

    settings = Settings.load(env_file="/dev/null")

    assert settings.proxy_host == "zproxy.lum-superproxy.io"
    assert settings.proxy_port == 22225
    assert settings.proxy_user == "brd-customer-123"
    assert settings.proxy_pass == "proxypass"
    assert settings.proxy_enabled is True


def test_load_without_proxy_vars(monkeypatch):
    """Missing proxy vars result in proxy_enabled=False, no error."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "a@b.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "pass")

    settings = Settings.load(env_file="/dev/null")

    assert settings.proxy_enabled is False
    assert settings.proxy_host == ""


def test_proxy_pass_not_in_repr(monkeypatch):
    """Proxy password must not appear in repr."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "a@b.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "pass")
    monkeypatch.setenv("PROXY_HOST", "proxy.example.com")
    monkeypatch.setenv("PROXY_PORT", "22225")
    monkeypatch.setenv("PROXY_USER", "user")
    monkeypatch.setenv("PROXY_PASS", "secretproxy")

    settings = Settings.load(env_file="/dev/null")

    assert "secretproxy" not in repr(settings)


def test_load_with_webhook_url(monkeypatch):
    """Custom webhook URL is loaded from env."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "a@b.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "pass")
    monkeypatch.setenv("WEBHOOK_URL", "https://my-n8n.example.com/webhook/abc")
    monkeypatch.setenv("HEARTBEAT_URL", "https://my-n8n.example.com/webhook/hb")

    settings = Settings.load(env_file="/dev/null")

    assert settings.webhook_url == "https://my-n8n.example.com/webhook/abc"
    assert settings.heartbeat_url == "https://my-n8n.example.com/webhook/hb"


def test_load_without_webhook_url_uses_defaults(monkeypatch):
    """Missing webhook/heartbeat URLs use hardcoded defaults."""
    monkeypatch.setenv("INMUEBLES24_EMAIL", "a@b.com")
    monkeypatch.setenv("INMUEBLES24_PASSWORD", "pass")

    settings = Settings.load(env_file="/dev/null")

    assert "n8n.srv856940.hstgr.cloud" in settings.webhook_url
    assert settings.heartbeat_url == ""
