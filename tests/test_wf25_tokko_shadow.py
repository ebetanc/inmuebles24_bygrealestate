"""WF25 (Tokko intake, shadow): the Code node parses real Tokko notices (anonymized fixtures)."""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
WF = json.loads((ROOT / "whatsapp-agent/workflows/WF25_tokko_intake_shadow.json").read_text(encoding="utf-8"))
FIX = ROOT / "tests/fixtures/tokko"
needs_node = pytest.mark.skipif(not shutil.which("node"), reason="node not installed")


def _node(name):
    return next(n for n in WF["nodes"] if n["name"] == name)


def _parse(items):
    harness = (
        "const items = JSON.parse(require('fs').readFileSync(0, 'utf8'));"
        "const $input = { all: () => items.map((json) => ({ json })) };"
        f"const out = (() => {{ {_node('Leer aviso')['parameters']['jsCode']} }})();"
        "process.stdout.write(JSON.stringify(out.map((i) => i.json)));"
    )
    res = subprocess.run(
        ["node", "-e", harness], input=json.dumps(items), capture_output=True,
        text=True, encoding="utf-8", check=True,
    )
    return json.loads(res.stdout)


@needs_node
def test_parses_the_three_notice_shapes():
    items = [
        {"id": f"m{i}", "date": "2026-10-10T04:20:00.000Z", "subject": "s", "html": (FIX / f).read_text(encoding="utf-8")}
        for i, f in enumerate(["i24_consulta.html", "i24_whatsapp.html", "jamesedition.html"])
    ]
    consulta, whatsapp, james = _parse(items)

    assert consulta == {
        "gmail_message_id": "m0", "received_at": "2026-10-10T04:20:00.000Z", "subject": "s",
        "webcontact_id": "900000001", "portal": "inmuebles24", "kind": "Consulta",
        "tags": "inmuebles24, Consulta, Lomas AnAhuac, Renta, Departamento",
        "lead_name": "Ana Prueba", "phone": "+525500000001", "email": "ana.prueba@example.com",
        "eb_ref": "EB-XA5105", "i24_listing_id": "151311979", "property_title": "Carretones Planta Baja",
        "message": consulta["message"], "parse_ok": True,
    }
    assert consulta["message"].startswith("[Lomas AnAhuac | Renta | Departamento] ¡Hola! Quiero")
    # Same lead, second notice: only the webcontact id and kind differ.
    assert (whatsapp["kind"], whatsapp["webcontact_id"]) == ("Contacto por Whatsapp", "900000002")
    assert (whatsapp["phone"], whatsapp["eb_ref"]) == (consulta["phone"], consulta["eb_ref"])
    # Empty "Móvil" must not swallow the next line; the phone comes from "Teléfono".
    assert (james["portal"], james["kind"], james["phone"], james["eb_ref"], james["i24_listing_id"]) == (
        "JamesEdition", None, "+525500000002", "EB-WE8774", None)
    assert james["parse_ok"] is True


@needs_node
def test_unparseable_notice_is_kept_but_flagged():
    (row,) = _parse([{"id": "x", "html": "<p>Hola</p>"}])
    assert row["parse_ok"] is False and row["gmail_message_id"] == "x"


def test_shadow_contract():
    trigger = _node("Correo de Tokko")["parameters"]
    assert trigger["filters"] == {"q": 'from:notifier@tokkobroker.com "nueva consulta"', "readStatus": "both"}
    assert trigger["simple"] is False
    assert "ON CONFLICT (gmail_message_id) DO NOTHING" in _node("Guardar sombra")["parameters"]["query"]
    # Polls every minute: never keep successful executions (n8n sqlite bloat).
    assert WF["settings"]["saveDataSuccessExecution"] == "none"
    # Shadow: nothing may call WF10/WF13 or send anything.
    assert {n["type"] for n in WF["nodes"]} == {
        "n8n-nodes-base.gmailTrigger", "n8n-nodes-base.code", "n8n-nodes-base.postgres"}
