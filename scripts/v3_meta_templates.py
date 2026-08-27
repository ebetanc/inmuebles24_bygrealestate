"""Create missing V3 WhatsApp templates and emit sanitized evidence."""

from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = ROOT / ".env.meta.local"
OUTPUT = ROOT / "output" / "v3-execution" / "meta-template-submission.json"


def load_env() -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in ENV_FILE.read_text(encoding="utf-8-sig").splitlines():
        match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$", raw)
        if not match:
            continue
        value = match.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[match.group(1)] = value
    for key in ("META_GRAPH_API_VERSION", "META_ACCESS_TOKEN", "META_WABA_ID"):
        if not values.get(key):
            raise SystemExit(f"Missing {key}")
    if values["META_GRAPH_API_VERSION"] != "v22.0":
        raise SystemExit("META_GRAPH_API_VERSION must be v22.0 for this approved cutover")
    return values


TEMPLATES = (
    {
        "name": "lead_subasta_v3",
        "language": "es_MX",
        "category": "UTILITY",
        "components": [
            {
                "type": "BODY",
                "text": (
                    "🏠 Nuevo lead\n\n"
                    "Prospecto: {{1}}\nTeléfono: {{2}}\n\n"
                    "Propiedad: {{3}}\nOperación: {{4}}\nZona: {{5}}\n"
                    "Precio: {{6}}\nID: {{7}}\nEasyBroker: {{8}}\n\n"
                    "Tienes 5 minutos para aceptarlo."
                ),
                "example": {
                    "body_text": [[
                        "Andrea Ejemplo", "+525500000000", "Casa muestra",
                        "Venta", "Zona Centro", "$1,000,000 MXN",
                        "EB-DEMO123", "https://www.easybroker.com/"
                    ]]
                },
            },
            {"type": "BUTTONS", "buttons": [{"type": "QUICK_REPLY", "text": "Tomo"}]},
        ],
    },
    {
        "name": "lead_asignado_v3",
        "language": "es_MX",
        "category": "UTILITY",
        "components": [
            {
                "type": "BODY",
                "text": (
                    "🏠 Lead asignado\n\n"
                    "Prospecto: {{1}}\nTeléfono: {{2}}\n\n"
                    "Propiedad: {{3}}\nOperación: {{4}}\nZona: {{5}}\n"
                    "Precio: {{6}}\nID: {{7}}\nEasyBroker: {{8}}\n\n"
                    "Este lead fue asignado directamente a ti."
                ),
                "example": {
                    "body_text": [[
                        "Andrea Ejemplo", "+525500000000", "Casa muestra",
                        "Venta", "Zona Centro", "$1,000,000 MXN",
                        "EB-DEMO123", "https://www.easybroker.com/"
                    ]]
                },
            }
        ],
    },
    {
        "name": "alerta_routing_v3",
        "language": "es_MX",
        "category": "UTILITY",
        "components": [
            {
                "type": "BODY",
                "text": (
                    "⚠️ Incidencia de routing\n\n"
                    "Tipo: {{1}}\nLead ID: {{2}}\nPropiedad ID: {{3}}\n"
                    "Estado: {{4}}\nAcción requerida: {{5}}\n\n"
                    "Consulta el tablero para resolverla."
                ),
                "example": {
                    "body_text": [[
                        "correlación ambigua", "900001", "EB-DEMO123",
                        "manual_review", "Revisar solicitud exacta"
                    ]]
                },
            }
        ],
    },
)


def request_json(url: str, token: str, *, payload: dict | None = None) -> dict:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload else None
    request = urllib.request.Request(
        url,
        data=body,
        method="POST" if payload else "GET",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        try:
            detail = json.loads(error.read().decode("utf-8"))
        except Exception:
            detail = {"error": {"message": f"HTTP {error.code}"}}
        raise RuntimeError(json.dumps(detail, ensure_ascii=False)) from None


def sanitize_template(row: dict) -> dict:
    return {
        key: row.get(key)
        for key in ("id", "name", "status", "category", "language")
        if row.get(key) is not None
    }


def contract_shape(components: list[dict]) -> list[dict]:
    return [
        {
            "type": part.get("type"),
            "text": part.get("text"),
            "buttons": [
                {"type": button.get("type"), "text": button.get("text")}
                for button in part.get("buttons", [])
            ],
        }
        for part in components
    ]


def main() -> None:
    values = load_env()
    base = (
        f"https://graph.facebook.com/{values['META_GRAPH_API_VERSION']}/"
        f"{values['META_WABA_ID']}/message_templates"
    )
    results: list[dict] = []
    for template in TEMPLATES:
        query = urllib.parse.urlencode(
            {"name": template["name"], "fields": "id,name,status,category,language,components"}
        )
        existing = request_json(f"{base}?{query}", values["META_ACCESS_TOKEN"]).get("data", [])
        exact = [row for row in existing if row.get("name") == template["name"]]
        if exact:
            results.append({
                "action": "existing",
                **sanitize_template(exact[0]),
                "definition_matches": contract_shape(exact[0].get("components", []))
                == contract_shape(template["components"]),
            })
            continue
        created = request_json(base, values["META_ACCESS_TOKEN"], payload=template)
        results.append(
            {
                "action": "created",
                "name": template["name"],
                "id": created.get("id"),
                "status": created.get("status"),
                "category": created.get("category"),
                "language": template["language"],
            }
        )
    evidence = {
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "graph_version": values["META_GRAPH_API_VERSION"],
        "templates": results,
        "token_printed": False,
        "messages_sent": 0,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(evidence, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        sys.exit(1)
