"""Weekly lead report — fetch from Supabase, render, email to management.

Usage:
    python -m reporte_semanal              # fetch + email (Sandy + Marusa)
    python -m reporte_semanal --preview    # write HTML to logs/, do NOT send
    python -m reporte_semanal --days 7

Env:
    SUPABASE_URL, SUPABASE_SERVICE_KEY        (query the weekly_lead_report fn)
    SMTP_HOST, SMTP_PORT (465), SMTP_USER, SMTP_PASS, REPORT_FROM
    REPORT_TO   = comma-separated recipients (e.g. sandy@…,marusa@…)
"""
from __future__ import annotations

import argparse
import os
import smtplib
import ssl
import sys
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path

import httpx
from dotenv import load_dotenv

from reporte_semanal import render_html


def fetch_report(days: int) -> dict:
    url = os.environ.get("SUPABASE_URL", "").strip()
    key = os.environ.get("SUPABASE_SERVICE_KEY", "").strip()
    if not url or not key:
        raise SystemExit("Falta SUPABASE_URL / SUPABASE_SERVICE_KEY")
    endpoint = f"{url.rstrip('/')}/rest/v1/rpc/weekly_lead_report"
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    with httpx.Client(timeout=30) as c:
        r = c.post(endpoint, json={"days_back": days}, headers=headers)
        r.raise_for_status()
        return r.json()


def send_email(html: str, subject: str) -> None:
    host = os.environ.get("SMTP_HOST", "").strip()
    port = int(os.environ.get("SMTP_PORT", "465"))
    user = os.environ.get("SMTP_USER", "").strip()
    pwd = os.environ.get("SMTP_PASS", "").strip()
    sender = os.environ.get("REPORT_FROM", user).strip()
    to = [x.strip() for x in os.environ.get("REPORT_TO", "").split(",") if x.strip()]
    missing = [k for k, v in {"SMTP_HOST": host, "SMTP_USER": user, "SMTP_PASS": pwd, "REPORT_TO": ",".join(to)}.items() if not v]
    if missing:
        raise SystemExit(f"Falta config SMTP: {', '.join(missing)}")

    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = ", ".join(to)
    msg.attach(MIMEText("Tu cliente de correo no soporta HTML. Abre el reporte en uno que sí.", "plain"))
    msg.attach(MIMEText(html, "html"))

    ctx = ssl.create_default_context()
    with smtplib.SMTP_SSL(host, port, context=ctx) as s:
        s.login(user, pwd)
        s.sendmail(sender, to, msg.as_string())
    print(f"Reporte enviado a: {', '.join(to)}")


def main() -> int:
    load_dotenv(".env", override=False)
    ap = argparse.ArgumentParser(prog="reporte_semanal")
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--preview", action="store_true", help="Render to logs/reporte_semanal_preview.html, no enviar")
    args = ap.parse_args()

    report = fetch_report(args.days)
    html = render_html(report)
    subject = f"📊 Reporte semanal de leads BYG — {report.get('no_atendidos',0)} sin atender"

    if args.preview:
        Path("logs").mkdir(exist_ok=True)
        out = Path("logs/reporte_semanal_preview.html")
        out.write_text(html, encoding="utf-8")
        print(f"Preview: {out.resolve()}")
        return 0

    send_email(html, subject)
    return 0


if __name__ == "__main__":
    sys.exit(main())
