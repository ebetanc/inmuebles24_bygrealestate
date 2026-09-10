"""Runs tests/sql/test_v3_unassigned.sql against an ephemeral PG17.

The whole schema chain (whatsapp-agent/migrations + supabase/migrations, in
order) is applied first, so the fixture exercises the live function bodies and
not a hand-rolled subset. Skipped when no docker daemon is reachable; the static
contract lives in tests/test_v3_unassigned_migration_draft.py.
"""

import subprocess
import time
import uuid
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
FIXTURE = ROOT / "tests" / "sql" / "test_v3_unassigned.sql"

# Roles Supabase provides and a bare postgres image does not.
ROLES = "CREATE ROLE service_role;CREATE ROLE authenticated;CREATE ROLE anon;"

# 0011/0018 and the Benjamin alias migration seed property tags that reference
# production agents by id; a bare container has none, so stand them up first.
AGENT_SEED = """
INSERT INTO agents (agent_id,name,whatsapp_number,on_shift,is_available) VALUES
 ('agent_manager','Sandy','+5215500000101',true,true),
 ('agent_manager_2','Marusa','+5215500000102',true,true),
 ('agent_carol','Carol','+5215500000103',true,true),
 ('agent_gina','Gina','+5215500000104',true,true),
 ('agent_lupita','Lupita','+5215500000105',true,true),
 ('agent_moni','Monica','+5215500000106',true,true),
 ('agent_paty','Paty','+5215500000107',true,true),
 ('agent_yol','Yolanda','+5215500000108',true,true),
 ('agent_benjamin','Benjamin','+5215500000109',true,true)
ON CONFLICT (agent_id) DO NOTHING;
"""


def _migrations() -> list[Path]:
    legacy = sorted((ROOT / "whatsapp-agent" / "migrations").glob("*.sql"))
    v3 = sorted((ROOT / "supabase" / "migrations").glob("*.sql"))
    return [f for f in legacy + v3 if "rollback" not in f.name]


def _docker(*args: str, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(("docker",) + args, capture_output=True, text=True,
                          encoding="utf-8", **kwargs)


def _docker_available() -> bool:
    try:
        return _docker("info", "--format", "{{.ServerVersion}}", timeout=30).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


@pytest.mark.skipif(not _docker_available(), reason="no docker daemon for the PG17 gate")
def test_migration_and_rollback_fixture_pass_on_pg17():
    name = f"v3-unassigned-gate-{uuid.uuid4().hex[:8]}"
    started = _docker("run", "-d", "--rm", "--name", name,
                      "-e", "POSTGRES_PASSWORD=gate", "postgres:17")
    assert started.returncode == 0, started.stderr

    def psql(sql: str) -> subprocess.CompletedProcess:
        return _docker("exec", "-i", name, "psql", "-U", "postgres",
                       "-v", "ON_ERROR_STOP=1", "-f", "-", input=sql)

    try:
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if psql("SELECT 1;").returncode == 0:
                break
            time.sleep(1)
        else:
            pytest.fail("postgres:17 never became ready")

        assert psql(ROLES).returncode == 0
        for migration in _migrations():
            run = psql(migration.read_text(encoding="utf-8"))
            assert run.returncode == 0, f"{migration.name}\n{run.stdout}{run.stderr}"
            if migration.name == "0002_rls.sql":
                seeded = psql(AGENT_SEED)
                assert seeded.returncode == 0, seeded.stderr

        # The fixture is one transaction, so nothing survives the ROLLBACK.
        run = psql("BEGIN;\n" + FIXTURE.read_text(encoding="utf-8") + "\nROLLBACK;")
        assert run.returncode == 0, run.stdout + run.stderr
        assert "V3_UNASSIGNED_TESTS_PASS" in run.stderr + run.stdout
    finally:
        _docker("rm", "-f", name)
