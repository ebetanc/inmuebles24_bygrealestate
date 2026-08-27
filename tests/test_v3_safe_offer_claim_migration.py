from pathlib import Path


ROOT = Path(__file__).parents[1]
MIGRATION = ROOT / "supabase" / "migrations" / "20260827184755_lead_routing_v3_safe_offer_claim.sql"


def test_safe_offer_claim_is_a_forward_migration_over_the_applied_rpc():
    sql = MIGRATION.read_text(encoding="utf-8").lower()
    assert "create or replace function public.v3_claim_delivery_attempts" in sql
    assert "security invoker" in sql
    assert "set search_path = ''" in sql
    assert "join public.lead_routing_opportunities" in sql
    for guard in (
        "o.v3_enabled is true",
        "o.assigned_agent_id is null",
        "o.current_delivery_attempt_id = a.attempt_id",
        "o.routing_tier = a.routing_tier",
        "a.delivery_kind = 'offer'",
        "a.status = 'requested'",
    ):
        assert guard in sql
    assert "for update of a skip locked" in sql


def test_applied_v3_migration_files_remain_hash_stable_and_are_documented():
    status = (ROOT / "supabase" / "V3_PRODUCTION_MIGRATION_STATUS.md").read_text(encoding="utf-8")
    assert "wkaeutndwawkdhswisqe" in status
    assert "20260827154900" in status and "20260827173500" in status
    assert "output/v3-execution/supabase-production-apply.json" in status
