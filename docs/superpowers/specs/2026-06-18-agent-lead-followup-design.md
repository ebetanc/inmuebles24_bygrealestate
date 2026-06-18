# Agent Lead Follow-Up — Design Spec

**Date:** 2026-06-18
**Status:** Designed, parked as **Phase 10** (post-go-live). Do not implement yet.
**Owner:** BYG / Inmobiliaria24

## Problem

Agents have leads assigned to them (owner-first routing, WF10/WF12/WF13), but there is
**no mechanism for agents to report progress** on those leads, and **no visibility for
the gerente** into how the sales process is advancing. The CRM pipeline tables exist
(`lead_status`, `lead_status_history`) but agents never feed them — they ignore the
dashboard.

The client wants:
1. Proactive WhatsApp follow-up with each agent about their assigned leads.
2. Progress recorded step-by-step in the database (questions about the sale process).
3. A weekly report to the gerente.

Applies to both **venta** and **renta** leads (`conversations.listing_type`).

## What already exists (reuse, do not rebuild)

From migrations `0009_supabase_crm.sql` and `0011_owner_routing.sql`:

- `lead_status` — pipeline stage per lead:
  `new → contacted → qualified → visit_scheduled → offer → closed_won → closed_lost`.
  Columns: `notes`, `next_action`, `next_action_at`, `updated_by`.
- `lead_status_history` — append-only audit of every stage transition (via trigger).
- `update_lead_stage(conversation_id, stage, agent_id, note, next_action, next_action_at)`
  RPC — atomic update; trigger writes history automatically.
- `agent_metrics` view — per-agent leads volume, avg response time, outcomes, SLA breaches.
- `sla_breaches` view — leads with no reply > 15 min.
- `conversations.assigned_agent_id` / `owner_agent_id` — who owns the lead.
- `agents.whatsapp` — agent phone numbers.
- Evolution API send + WF4 IA conversation node pattern (free-text interpretation).

## Decisions (locked)

| Topic | Decision |
|---|---|
| Cadence | **Stage-based.** Different nudge timing per pipeline stage (see WF14). |
| Agent reply UX | **Free text + IA interpretation** (reuse WF4 pattern). |
| Stage advance | **Auto-advance + allow correction.** IA updates immediately, sends confirmation; agent can correct → re-parse. |
| Weekly report | **To gerente, via WhatsApp.** |
| Scope | **All active leads** (not closed_won/closed_lost), venta and renta. |

## Architecture

Chosen approach: **new n8n workflows** (max reuse of existing stack:
n8n + Evolution + Supabase + IA node). Rejected: dashboard-built (agents ignore it) and
pure edge-functions (re-implements Evolution send + IA parse).

### Core design problem: reply disambiguation

An agent owns many leads. When they reply "ya agendé la visita", the system must know
**which lead**. Solved by **one lead per message + a pending-prompt tracker**:
the bot asks about a single lead at a time and records that an answer is outstanding;
the agent's next inbound message maps to their most-recent `pending` followup.

### New DB — migration `0012_agent_followups.sql`

```
CREATE TABLE lead_followups (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id UUID NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  agent_id        TEXT NOT NULL REFERENCES agents(agent_id),
  prompt_kind     TEXT NOT NULL,        -- 'new_2h','new_24h','stalled','visit_day'
  prompt_sent_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  answered_at     TIMESTAMPTZ,
  response_text   TEXT,
  parsed_stage    TEXT,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','answered','expired'))
);
-- index: (agent_id, status, prompt_sent_at DESC) for reply matching
-- index: (conversation_id, status) to skip leads with an open prompt
```

Drives: (a) reply→lead mapping, (b) no double-asking, (c) "agentes sin responder" in the
weekly report. RLS read-only; writes via service_role.

### WF14 — Follow-Up Sweeper (cron, business hours only, ~every 2h, 09:00–19:00)

1. Query leads needing a nudge using **stage-based cadence**:
   - `new`, assigned, no agent first_response → nudge at +2h, then +24h.
   - `contacted` / `qualified` → no stage change in 2–3 days.
   - `visit_scheduled` → morning of `next_action_at`.
   - skip `closed_won` / `closed_lost`.
2. Skip any lead that already has a `pending` row in `lead_followups` (no pile-up).
3. Send WhatsApp to the owning agent (`agents.whatsapp`): lead name + property +
   listing_type + last status + the question. Example:
   *"¿En qué quedó con Juan por la casa en Lomas (venta)? ¿Ya contactaste? ¿Cuál es el próximo paso?"*
4. Insert `lead_followups` row, `status='pending'`.

### WF15 — Agent Reply Handler

- **Router change (WF1):** if inbound `from_phone` ∈ `agents.whatsapp` → **agent branch**
  (not the lead conversation branch).
- Match reply to that agent's most-recent `pending` followup
  (`ORDER BY prompt_sent_at DESC LIMIT 1`).
- IA node interprets free text → `{stage, note, next_action, next_action_at}`.
- Call `update_lead_stage()` (auto-logs history); mark the followup `answered`
  (`response_text`, `parsed_stage`, `answered_at`).
- Confirmation reply: *"✅ Anotado: cita el viernes. Te recuerdo ese día."*
- **Correction path:** if the agent says it's wrong, re-parse the correction and update.

### WF16 — Weekly Report (cron, lunes 08:00)

WhatsApp to gerente (Sandy / Marusa). Pulls from existing `agent_metrics` +
`sla_breaches` + `lead_followups`. Contents:
- Leads por etapa (snapshot del pipeline).
- Conversiones de la semana (visitas agendadas, cierres won/lost).
- Tiempo de respuesta promedio por agente.
- **Agentes con followups sin responder** (status='pending'/'expired').
- Leads estancados (sin cambio de etapa hace > N días).

## Dependencies / blockers

- **Evolution bot number** is currently stuck in WhatsApp `device_removed` 401 cooldown
  (see memory `evolution-whatsapp-status`). Must be connected and stable before this runs.
- `agents.whatsapp` must be populated with each agent's real number.
- `property_agent_alias` tags must resolve owners correctly (already validated for
  owner-first routing).

## Out of scope (YAGNI)

- Buttons/list-reply UX (Evolution support is unstable; free-text + IA covers it).
- Email/PDF reports (WhatsApp report is enough for v1).
- Per-agent weekly digests (gerente report only for v1).
- Dashboard changes (the gerente can already view live data there).

## Effort

1 migration + 3 new workflows (WF14/15/16) + 1 WF1 router tweak. Medium.
Park as **Phase 10**, after go-live.
