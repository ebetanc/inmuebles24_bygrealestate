"""Runs tests/sql/test_v3_daily_report_whatsapp.sql against an ephemeral PG17.

Skipped when no docker daemon is reachable; the static contract lives in
tests/test_v3_daily_report_whatsapp_migration_draft.py.
"""

import subprocess
import time
import uuid
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20260911100000_v3_daily_report_whatsapp.sql"
FIXTURE = ROOT / "tests" / "sql" / "test_v3_daily_report_whatsapp.sql"


def _docker(*args: str, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(("docker",) + args, capture_output=True, text=True, **kwargs)


def _docker_available() -> bool:
    try:
        return _docker("info", "--format", "{{.ServerVersion}}", timeout=30).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


@pytest.mark.skipif(not _docker_available(), reason="no docker daemon for the PG17 gate")
def test_migration_and_rollback_fixture_pass_on_pg17():
    name = f"v3-report-gate-{uuid.uuid4().hex[:8]}"
    started = _docker("run", "-d", "--rm", "--name", name,
                      "-e", "POSTGRES_PASSWORD=gate", "postgres:17")
    assert started.returncode == 0, started.stderr
    try:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if _docker("exec", name, "pg_isready", "-U", "postgres").returncode == 0:
                break
            time.sleep(1)
        else:
            pytest.fail("postgres:17 never became ready")

        # service_role exists in Supabase, not in a bare container; the whole run is
        # one transaction so nothing survives the ROLLBACK.
        script = "\n".join([
            "CREATE ROLE service_role;",
            "BEGIN;",
            MIGRATION.read_text(encoding="utf-8"),
            FIXTURE.read_text(encoding="utf-8"),
            "ROLLBACK;",
        ])
        run = _docker("exec", "-i", name, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1",
                      "-f", "-", input=script)
        assert run.returncode == 0, run.stdout + run.stderr
        assert "V3_DAILY_REPORT_WHATSAPP_TESTS_PASS" in run.stderr + run.stdout
    finally:
        _docker("rm", "-f", name)
