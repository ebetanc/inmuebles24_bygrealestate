# Phase 2 `unassigned` — inventario de dependencias (2026-09-10)

Verificado contra producción (psql, 2026-09-10 18:45 UTC): estados vivos
`assigned 149, unassigned_alerted 40, manual_non_deduplicable 14, captured 7, closed_lost 5,
queued_night 1, guard_delivery_pending 1`; 0 ofertas abiertas en ese momento.

## 0. Función viva → migración que la define (la última gana)

| Función | Definición viva |
|---|---|
| `v3_assign_sandy` | `supabase/migrations/20260827154900_lead_routing_v3_intake_routing.sql:759-801` |
| `v3_route_ready_opportunity` | `supabase/migrations/20260907152702_v3_day_deadline.sql:741-859` |
| `v3_advance_routing_tier` | `supabase/migrations/20260907152702_v3_day_deadline.sql:862-977` |
| `claim_v3_delivery` | `supabase/migrations/20260907152702_v3_day_deadline.sql:581-738` |
| `claim_v3_easybroker_effects` | `supabase/migrations/20260907152702_v3_day_deadline.sql:431-578` |
| `claim_v3_easybroker_request_creations` | `supabase/migrations/20260907152702_v3_day_deadline.sql:~300-330` |
| `v3_day_sweep` | `supabase/migrations/20260907152702_v3_day_deadline.sql:107-135` |
| `finish_v3_easybroker_effect` | `supabase/migrations/20260901153200_fix_v3_night_release_property_readiness.sql:657-871` |
| `v3_release_night_queue` | `supabase/migrations/20260901153200_...sql:451-536` |
| `v3_enqueue_assigned_notice` | `supabase/migrations/20260827154900_...sql:709-756` |
| delivery-callback terminal guard | `supabase/migrations/20260827173500_*.sql:139` (`state IN ('assigned','unassigned_alerted','closed_won','closed_lost')`) |
| vista `v3_leads_dashboard` | `supabase/migrations/20260907113520_v3_stalled_capture_visibility.sql:5-130` (`assignment_method` = `claim`/`sandy_fallback`, líneas 71-72) |

## 1. Constraints vivos (producción)

```
lead_routing_opportunities_state_check: state IN ('captured','deduplicated','resolved','delivery_requested',
  'guard_delivery_pending','delivered','owner_open','primary_guard_open','backup_guard_open','assigned',
  'unassigned_alerted','queued_night','manual_non_deduplicable','safe_mode','closed_won','closed_lost')
conversations_assignment_method_check: NULL or IN ('whatsapp_number','manual','easybroker_legacy','manager_escalation')
conversations_claimed_via_check: NULL or IN ('tomo_auction','night_queue','manual','escalation','owner')
conversations_routing_tier_check: NULL or IN ('owner','guard','manager')
conversations_mode_check: IN ('pending_assignment','ai','human','night_queued')
easybroker_effect_ledger_check: close_state='awaiting_responsible' OR (responsible_agent_id IS NOT NULL AND NULLIF(btrim(responsible_first_name),'') IS NOT NULL)
easybroker_effect_ledger_check1: close_state<>'completed' OR (note_state='succeeded' AND attended_state='succeeded')
easybroker_effect_ledger_attended_state_check: IN ('pending','succeeded','failed')
easybroker_effect_ledger_note_state_check: IN ('pending','succeeded','failed')
```

Nota: `v3_assign_sandy` escribe `claimed_via='v3_manager_fallback'` y `claim_v3_delivery`
`assignment_method='v3_response_claim'`, ambos fuera de los CHECK vivos. Funciona porque las
oportunidades V3 tienen `conversation_id IS NULL` (el UPDATE a `conversations` no corre).
`v3_mark_unassigned` NO tocará `conversations`.

## 2. Lugares que deben cambiar para `unassigned`

- `lead_routing_opportunities_state_check` → agregar `'unassigned'`.
- `easybroker_effect_ledger_check` → permitir responsable sin agente: `close_state='awaiting_responsible' OR NULLIF(btrim(responsible_first_name),'') IS NOT NULL`.
- `easybroker_effect_ledger_check1` → `attended_state IN ('succeeded','skipped')`; `attended_state_check` → agregar `'skipped'`.
- `claim_v3_easybroker_request_creations` (20260907152702:321) → `o.state IN ('assigned','closed_won','unassigned')`.
- `claim_v3_easybroker_effects` (20260907152702:468) → promoción también con `o.state='unassigned'`, `responsible_first_name='SIN ASIGNACIÓN'`, `attended_due=false` cuando `responsible_agent_id IS NULL`.
- `finish_v3_easybroker_effect` (20260901153200:657) → al terminar `note` ok con `responsible_agent_id IS NULL`: `attended_state='skipped'`, `close_state='completed'`.
- `v3_route_ready_opportunity` :849, `v3_advance_routing_tier` :944 y :969 → `v3_mark_unassigned`, retornando `{'state':'unassigned','tier':NULL}`.
- `v3_advance_routing_tier` :883 early-return → tratar `unassigned` como terminal (no re-procesar).
- `v3_day_sweep` :115/:123 → `unassigned` con `unassigned_at <= deadline` cuenta como cierre; EB `attended_state IN ('succeeded','skipped')`.
- callback terminal guard 20260827173500:139 → agregar `'unassigned'`.
- vista `v3_leads_dashboard` → `assignment_method='unassigned'` cuando `external_evidence->>'v3_final_route'='unassigned'`.
- `dashboard/src/lib/types.ts:144`, `queries.ts:253-255`, `app/(dashboard)/leads-v3/page.tsx:17,44,50,57` → valor `unassigned` / pestaña "Sin asignación".
- WF24 SQL `stuck_expired` (build_wf24_monitor.py:54) → `AND state <> 'unassigned'`; whitelist de eventos (py:41) → agregar `'left_unassigned'`; SQL `leads` → exponer `o.unassigned_at`.
- WF24 render (`wf24_render.js`) → rama `state==='unassigned'`, quitar el OR `assigned_role==='manager'`.
- WF10 `WF10_scraper_intake.json:859` → agregar `'unassigned'` a la lista de estados activos (dedupe).
- WF3c `Route Transition` (:86-93): condición `rightValue:"assigned"` → agregar regla `unassigned` → NoOp; `Reject Unexpected Transition State` (:116-125) allowlist → agregar `'unassigned'`.
- `src/easybroker/inbox.py:418-430` parser `RESPONSABLE:` acepta `SIN ASIGNACIÓN`; `src/easybroker/main.py:85-90` omite paso Atendida si `attended_due=false`.

## 3. Columna del id de conversación i24

`i24_capture_events.external_event_id` (= `contact_publisher_user_id`), también en
`easybroker_i24_request_links.i24_lead_id`. `offer_context->>'lead_id'` NO existe.

## 4. Evento y evidencia

`lead_routing_events(opportunity_id, event_type, actor_id, idempotency_key, metadata)`;
`event_type` TEXT sin CHECK → nuevo `left_unassigned` sin DDL. `external_evidence` JSONB:
`{'v3_final_route':'unassigned','reason':<reason>}`.
