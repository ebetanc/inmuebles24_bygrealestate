"""Weekly lead report for management (Sandy + Marusa).

Pulls one JSON blob from the Supabase function `weekly_lead_report(days_back)`
(summary + unclaimed-lead list + per-agent claims) and renders a self-contained
HTML email. Sending lives in __main__; render_html is pure so it can be
previewed without credentials.
"""
from __future__ import annotations

from datetime import datetime, timezone, timedelta

# CDMX is UTC-6 (no DST).
_CDMX = timezone(timedelta(hours=-6))

_FUENTE = {"inmuebles24": "🟠 Inmuebles24", "easybroker": "🔵 EasyBroker"}


def _fecha_rango(days: int) -> str:
    hoy = datetime.now(_CDMX)
    desde = hoy - timedelta(days=days)
    return f"{desde.strftime('%d/%m')} – {hoy.strftime('%d/%m/%Y')}"


def render_html(report: dict) -> str:
    """Render the weekly report as a standalone HTML email (inline styles)."""
    recibidos = report.get("recibidos", 0)
    reclamados = report.get("reclamados", 0)
    no_atendidos = report.get("no_atendidos", 0)
    en_turno = report.get("asesores_en_turno", 0)
    fuente = report.get("por_fuente") or {}
    por_asesor = report.get("reclamados_por_asesor") or []
    lista = report.get("no_atendidos_lista") or []
    dias = report.get("days", 7)
    tasa = round(100 * reclamados / recibidos) if recibidos else 0

    inm = fuente.get("inmuebles24", 0)
    eb = fuente.get("easybroker", 0)

    asesor_rows = "".join(
        f"<tr><td style='padding:6px 12px;border-bottom:1px solid #eee'>{a.get('asesor','?')}</td>"
        f"<td style='padding:6px 12px;border-bottom:1px solid #eee;text-align:right;font-weight:700'>{a.get('n',0)}</td></tr>"
        for a in por_asesor
    ) or "<tr><td colspan='2' style='padding:6px 12px;color:#888'>(nadie reclamó)</td></tr>"

    lista_rows = "".join(
        f"<tr>"
        f"<td style='padding:7px 10px;border-bottom:1px solid #eee'>{i+1}</td>"
        f"<td style='padding:7px 10px;border-bottom:1px solid #eee;font-weight:600'>{l.get('nombre','')}</td>"
        f"<td style='padding:7px 10px;border-bottom:1px solid #eee'>{_FUENTE.get(l.get('fuente',''), l.get('fuente',''))}</td>"
        f"<td style='padding:7px 10px;border-bottom:1px solid #eee'>{l.get('telefono','')}</td>"
        f"<td style='padding:7px 10px;border-bottom:1px solid #eee;color:#666'>{l.get('propiedad') or '—'}</td>"
        f"<td style='padding:7px 10px;border-bottom:1px solid #eee;color:#666'>{l.get('fecha','')}</td>"
        f"</tr>"
        for i, l in enumerate(lista)
    ) or "<tr><td colspan='6' style='padding:10px;color:#0a7d4d'>🎉 Todos los leads fueron atendidos.</td></tr>"

    alerta = ""
    if en_turno == 0:
        alerta = (
            "<div style='margin:18px 0;padding:14px 16px;background:#ffeede;border:2px solid #b8500a;"
            "border-radius:8px;color:#7a3606;font-size:14px'>"
            "⚠️ <b>0 asesores en turno</b> esta semana — por eso casi todos los leads se quedaron sin atender. "
            "Hay que poner asesores en turno (calendario de guardias) para que reciban y reclamen leads."
            "</div>"
        )

    def card(label, value, color):
        return (
            f"<td style='padding:0 6px'><div style='background:{color}1a;border:2px solid {color};"
            f"border-radius:10px;padding:14px;text-align:center'>"
            f"<div style='font-size:30px;font-weight:800;color:{color}'>{value}</div>"
            f"<div style='font-size:12.5px;color:#444;margin-top:2px'>{label}</div></div></td>"
        )

    return f"""<!DOCTYPE html>
<html lang="es"><head><meta charset="UTF-8"></head>
<body style="margin:0;background:#f4f1ea;font-family:'Segoe UI',Roboto,Arial,sans-serif;color:#11161c">
<div style="max-width:720px;margin:0 auto;padding:24px">

  <div style="background:#11161c;color:#fff;border-radius:12px;padding:22px 24px;margin-bottom:18px">
    <div style="font-size:22px;font-weight:800">📊 Reporte semanal de leads — BYG Real Estate</div>
    <div style="opacity:.8;font-size:14px;margin-top:4px">Periodo: {_fecha_rango(dias)} · últimos {dias} días</div>
  </div>

  <table style="width:100%;border-collapse:separate;margin-bottom:8px"><tr>
    {card("Recibidos", recibidos, "#3b5bff")}
    {card("Reclamados", reclamados, "#0a7d4d")}
    {card("Sin atender", no_atendidos, "#e8501e")}
    {card("Tasa atención", f"{tasa}%", "#11161c")}
  </tr></table>

  {alerta}

  <table style="width:100%;border-collapse:collapse;margin:18px 0">
    <tr>
      <td style="width:50%;vertical-align:top;padding-right:8px">
        <div style="font-weight:700;margin-bottom:6px">Por fuente</div>
        <div style="background:#fff;border:2px solid #11161c;border-radius:10px;padding:10px 14px;font-size:14px">
          🟠 Inmuebles24: <b>{inm}</b><br>🔵 EasyBroker: <b>{eb}</b>
        </div>
      </td>
      <td style="width:50%;vertical-align:top;padding-left:8px">
        <div style="font-weight:700;margin-bottom:6px">Reclamados por asesor</div>
        <table style="width:100%;background:#fff;border:2px solid #11161c;border-radius:10px;border-collapse:collapse;font-size:14px">{asesor_rows}</table>
      </td>
    </tr>
  </table>

  <div style="font-weight:700;font-size:16px;margin:22px 0 8px">❌ Leads sin atender ({no_atendidos}) — a recuperar</div>
  <table style="width:100%;background:#fff;border:2px solid #11161c;border-radius:10px;border-collapse:collapse;font-size:13.5px;overflow:hidden">
    <tr style="background:#11161c;color:#fff">
      <th style="padding:8px 10px;text-align:left">#</th><th style="padding:8px 10px;text-align:left">Cliente</th>
      <th style="padding:8px 10px;text-align:left">Fuente</th><th style="padding:8px 10px;text-align:left">Teléfono</th>
      <th style="padding:8px 10px;text-align:left">Propiedad</th><th style="padding:8px 10px;text-align:left">Fecha</th>
    </tr>
    {lista_rows}
  </table>

  <div style="color:#888;font-size:12px;margin-top:22px;border-top:1px solid #ddd;padding-top:10px">
    Generado automáticamente · {datetime.now(_CDMX).strftime('%d/%m/%Y %H:%M')} CDMX · Sistema de atención de leads BYG
  </div>
</div></body></html>"""
