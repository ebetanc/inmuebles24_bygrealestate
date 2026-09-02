"""Half-hourly V3 health digest (read-only). Usage: python scripts/v3_health.py [minutes]

Prints facts from Supabase (same rules WF24 uses), the Pi timers/worker log and
n8n active workflows, then a list of ALERTA lines. Exit code 1 when any alert.
"""
import json
import subprocess
import sys
from pathlib import Path

import psycopg
from psycopg.rows import dict_row

ROOT = Path(__file__).resolve().parents[1]
MINUTES = int(sys.argv[1]) if len(sys.argv) > 1 else 35
V3_WORKFLOWS = 13

env = {}
for raw in (ROOT / ".env").read_text(encoding="utf-8-sig").splitlines():
    if "=" in raw and not raw.lstrip().startswith("#"):
        k, v = raw.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")

HEALTH = """
SELECT (SELECT max(completed_at) FROM public.scrape_logs WHERE status='ok') AS scraper_last_ok,
  (SELECT round(extract(epoch FROM now()-max(completed_at))/60) FROM public.scrape_logs WHERE status='ok') AS scraper_age_min,
  (SELECT count(*) FROM public.lead_routing_delivery_attempts WHERE status='requested' AND requested_at < now()-interval '3 minutes') AS stuck_requested,
  (SELECT count(*) FROM public.lead_routing_opportunities WHERE assigned_agent_id IS NULL AND current_delivery_attempt_id IS NOT NULL AND expires_at IS NOT NULL AND expires_at < now()-interval '90 seconds') AS stuck_expired,
  (SELECT count(*) FROM public.lead_routing_opportunities WHERE state='queued_night') AS queued_night,
  (SELECT count(*) FROM public.i24_capture_events WHERE route_dispatch_status='manual_review' AND happened_at >= now()-make_interval(mins=>%(m)s)) AS manual_review_new,
  (SELECT count(*) FROM public.easybroker_effect_ledger WHERE close_state IN ('manual_review','exhausted') AND updated_at >= now()-make_interval(mins=>%(m)s)) AS eb_effects_failed,
  (SELECT count(*) FROM public.easybroker_contact_request_creation_ledger WHERE state IN ('recovery','manual_review') AND updated_at < now()-interval '20 minutes' AND created_at >= now()-interval '1 day') AS eb_creation_stuck,
  now() AT TIME ZONE 'America/Mexico_City' AS now_cdmx
"""
LEADS = """
SELECT opportunity_id, lead_name, property_id, state, assigned_name, assignment_method, owner_offer_delivered_at, guard_offer_delivered_at,
  sandy_notice_delivered_at, eb_note_ok, eb_attended_ok, problem_reason, has_problem, created_at
FROM public.v3_leads_dashboard
WHERE created_at >= now()-make_interval(mins=>%(m)s) OR assigned_at >= now()-make_interval(mins=>%(m)s)
   OR opportunity_id IN (SELECT opportunity_id FROM public.lead_routing_events WHERE occurred_at >= now()-make_interval(mins=>%(m)s))
ORDER BY opportunity_id
"""


def ssh(target, cmd, timeout=90):
    try:
        out = subprocess.run(["ssh", "-o", "ConnectTimeout=15", "-o", "BatchMode=yes", target, cmd],
                             capture_output=True, text=True, timeout=timeout)
        return (out.stdout + out.stderr).strip()
    except Exception as exc:  # noqa: BLE001
        return f"SSH_ERROR {exc}"


alerts = []
with psycopg.connect(host=env["SUPABASE_DB_HOST"], port=int(env["SUPABASE_DB_PORT"]), user=env["SUPABASE_DB_USER"],
                     password=env["SUPABASE_DB_PASSWORD"], dbname=env["SUPABASE_DB_NAME"], sslmode="require",
                     connect_timeout=20, application_name="v3_health", row_factory=dict_row) as conn:
    conn.execute("SET default_transaction_read_only = on")
    h = conn.execute(HEALTH, {"m": MINUTES}).fetchone()
    leads = conn.execute(LEADS, {"m": MINUTES}).fetchall()

print(f"== V3 health · ventana {MINUTES} min · ahora {h['now_cdmx']:%H:%M} CDMX")
print("supabase:", json.dumps({k: (v.isoformat() if hasattr(v, "isoformat") else v) for k, v in h.items()}, ensure_ascii=False, default=str))
if h["scraper_age_min"] is None or h["scraper_age_min"] > 40:
    alerts.append(f"Scraper sin corrida OK hace {h['scraper_age_min']} min")
if h["stuck_requested"]:
    alerts.append(f"{h['stuck_requested']} envío(s) WhatsApp en 'requested' >3 min (WF23/WF13)")
if h["stuck_expired"]:
    alerts.append(f"{h['stuck_expired']} oferta(s) vencida(s) sin escalar (WF23/WF3c)")
if h["manual_review_new"]:
    alerts.append(f"{h['manual_review_new']} captura(s) nueva(s) en manual_review (lead sin ID EB)")
if h["eb_effects_failed"]:
    alerts.append(f"{h['eb_effects_failed']} nota(s)/Atendida EB fallidas (manual_review/exhausted)")
if h["eb_creation_stuck"]:
    alerts.append(f"{h['eb_creation_stuck']} solicitud(es) EB sin crear >20 min (recovery/manual_review)")

print(f"== leads con actividad: {len(leads)}")
for r in leads:
    print(json.dumps({k: (v.isoformat() if hasattr(v, "isoformat") else v) for k, v in r.items()}, ensure_ascii=False, default=str))
    if r["has_problem"]:
        alerts.append(f"lead #{r['opportunity_id']} {r['lead_name']}: {r['problem_reason']}")

pi = ssh("esteban@100.88.225.103",
         "systemctl is-active inmobiliaria24.timer easybroker.timer | paste -sd' '; "
         f"C=$(date -d '-{MINUTES} min' '+%Y-%m-%d %H:%M'); "
         "for f in eb_run.log run.log; do sudo -n tail -c 80000 /opt/inmobiliaria24/logs/$f 2>/dev/null"
         " | grep -a 'ERROR\\|EasyBroker V3 .* failed' | awk -v c=\"$C\" 'substr($0,1,16)>=c' | tail -5 | sed \"s/^/$f: /\"; done")
print("== pi:", pi)
if not pi.startswith("active active"):
    alerts.append(f"Pi timers/ssh: {pi[:120]}")

n8n = ssh("root@69.62.108.2",
          "docker exec root-n8n-1 n8n list:workflow --active=true 2>/dev/null | grep -cE 'WF(1|3b|3c|7|10|12|13|17|20|21|22|23|24) '; "
          "docker stats --no-stream --format '{{.MemUsage}}' root-n8n-1")
print("== n8n active V3 workflows / mem:", n8n.replace("\n", " · "))
try:
    active = int(n8n.splitlines()[0])
    if active < V3_WORKFLOWS:
        alerts.append(f"n8n: solo {active}/{V3_WORKFLOWS} workflows V3 activos")
except (ValueError, IndexError):
    alerts.append(f"n8n no respondió: {n8n[:120]}")

print(f"== ALERTAS: {len(alerts)}")
for a in alerts:
    print("ALERTA:", a)
sys.exit(1 if alerts else 0)
