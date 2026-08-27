"""Static V3 contracts for Meta definitions and Raspberry timers."""

import ast
from pathlib import Path


ROOT = Path(__file__).parents[1]


def _templates():
    tree = ast.parse((ROOT / "scripts" / "v3_meta_templates.py").read_text(encoding="utf-8"))
    assignment = next(
        node for node in tree.body
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "TEMPLATES"
            for target in node.targets
        )
    )
    return ast.literal_eval(assignment.value)


def test_meta_v3_templates_have_frozen_contract():
    templates = {template["name"]: template for template in _templates()}
    assert set(templates) == {"lead_subasta_v3", "lead_asignado_v3", "alerta_routing_v3"}
    for name in ("lead_subasta_v3", "lead_asignado_v3"):
        body = next(part for part in templates[name]["components"] if part["type"] == "BODY")
        assert [body["text"].count(f"{{{{{number}}}}}") for number in range(1, 9)] == [1] * 8
        assert templates[name]["language"] == "es_MX"
        assert templates[name]["category"] == "UTILITY"
    buttons = next(
        part for part in templates["lead_subasta_v3"]["components"]
        if part["type"] == "BUTTONS"
    )
    assert buttons["buttons"] == [{"type": "QUICK_REPLY", "text": "Tomo"}]
    assert all(part["type"] != "BUTTONS" for part in templates["lead_asignado_v3"]["components"])
    assert "Este lead fue asignado directamente a ti." in next(
        part["text"] for part in templates["lead_asignado_v3"]["components"]
        if part["type"] == "BODY"
    )


def test_v3_timers_match_operational_cadence():
    i24 = (ROOT / "deploy" / "inmobiliaria24.timer").read_text(encoding="utf-8")
    easybroker = (ROOT / "deploy" / "easybroker.timer").read_text(encoding="utf-8")
    assert "OnCalendar=*-*-* *:0/15:00 America/Mexico_City" in i24
    assert "RandomizedDelaySec=5" in i24
    assert "OnCalendar=*-*-* *:*:00 America/Mexico_City" in easybroker
    assert "RandomizedDelaySec=5" in easybroker
