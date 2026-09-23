"""Static contract: WF17's weekly_lead_report reads V3 and is not exposed to anon."""
from pathlib import Path

SQL = (Path(__file__).parents[1] / "supabase" / "migrations"
       / "20260923190000_v3_weekly_lead_report.sql").read_text(encoding="utf-8")


def test_reads_v3_not_v1_tables():
    body = SQL.split("AS $function$")[1]
    assert "FROM v3_leads_dashboard" in body
    assert "conversations" not in body
    assert "auctions" not in body


def test_keeps_keys_wf17_renders():
    for key in ("recibidos", "reclamados", "no_atendidos", "por_fuente",
                "reclamados_por_asesor", "asesores_en_turno", "no_atendidos_lista", "routing_v2"):
        assert f"'{key}'" in SQL


def test_revokes_anon():
    assert "REVOKE ALL ON FUNCTION public.weekly_lead_report(integer) FROM PUBLIC, anon, authenticated;" in SQL
