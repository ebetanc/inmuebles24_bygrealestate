"""WF25 (Tokko intake): parses real Tokko notices (anonymized fixtures) and feeds V3."""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
WF = json.loads((ROOT / "whatsapp-agent/workflows/WF25_tokko_intake.json").read_text(encoding="utf-8"))
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


@needs_node
def test_country_code_typed_twice_is_collapsed():
    html = "Hay una nueva consulta de X<br>Móvil: +52 52 5551043838<br>Ref: EB-XG3457<br>Teléfono: 12345678901234"
    (row,) = _parse([{"id": "d", "html": html}])
    assert row["phone"] == "+525551043838"


def test_intake_contract():
    trigger = _node("Correo de Tokko")["parameters"]
    assert trigger["filters"] == {"q": 'from:notifier@tokkobroker.com "nueva consulta"', "readStatus": "both"}
    assert trigger["simple"] is False
    # Every notice is logged; only a first-seen one (insert returned a row) goes on, so a re-read
    # email after an import/restart cannot notify an agent twice.
    assert "ON CONFLICT (gmail_message_id) DO NOTHING RETURNING *" in _node("Guardar sombra")["parameters"]["query"]
    assert WF["connections"]["Leer aviso"]["main"] == [[{"node": "Guardar sombra", "type": "main", "index": 0}]]
    assert WF["connections"]["Guardar sombra"]["main"] == [[{"node": "¿Datos completos?", "type": "main", "index": 0}]]
    # Only complete notices (contact + EB ref) reach V3; the false branch goes nowhere.
    assert _node("¿Datos completos?")["parameters"]["conditions"]["conditions"][0]["leftValue"] == "={{ $json.parse_ok }}"
    assert WF["connections"]["¿Datos completos?"]["main"] == [[{"node": "Crear lead V3", "type": "main", "index": 0}], []]
    intake = _node("Crear lead V3")["parameters"]["query"]
    assert "public.v3_tokko_intake(" in intake
    # One lead per contact + property + CDMX day: Consulta and WhatsApp notices collapse.
    assert "'tokko:' || COALESCE(s.j->>'email', s.j->>'phone') || ':' || (s.j->>'eb_ref')" in intake
    # Polls every minute: never keep successful executions (n8n sqlite bloat).
    assert WF["settings"]["saveDataSuccessExecution"] == "none"
    # Routing happens downstream (Pi dispatcher -> WF10); WF25 itself never sends anything.
    assert {n["type"] for n in WF["nodes"]} == {
        "n8n-nodes-base.gmailTrigger", "n8n-nodes-base.code", "n8n-nodes-base.postgres", "n8n-nodes-base.if"}


def test_tokko_capture_skips_contactado_and_i24_notes():
    sql = (ROOT / "supabase/migrations/20261010210000_v3_tokko_intake.sql").read_text(encoding="utf-8")
    assert "FROM public.v3_intake(" in sql
    assert "SET contactado_status = 'verified'" in sql and "IF r.disposition <> 'non_routable'" in sql
    assert "DISABLE TRIGGER v3_enqueue_i24_note" in sql
