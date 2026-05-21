# Supabase CRM Integration — n8n Workflow Hooks

Migration 0009 created the CRM tables and views. Migration 0010 added RPC helpers so workflows can mutate state with a single Postgres call (no risky JSON edits to workflow internals).

This doc spells out **where each call belongs in WF1, WF3a/b/c, and WF11**, the exact Postgres node config, and the EasyBroker degradation plan.

---

## RPC Cheat Sheet

| RPC | When to call | Idempotent | Caller |
|-----|-------------|------------|--------|
| `mark_assigned(uuid, text, text)` | Lead claimed by agent | Yes (assigned_at uses COALESCE) | WF3a, WF3b |
| `mark_first_response(uuid)` | First outbound human msg on a conv | Yes (NULL-guarded UPDATE) | WF1 |
| `record_sla_breach(uuid, text)` | 15-min SLA crossed | No (append-only log) | WF11 |
| `get_sla_breaches()` | Poll for pending breaches | Read-only | WF11 |
| `update_lead_stage(uuid, text, text, text, text, timestamptz)` | Manual pipeline stage change | Yes (upsert) | Dashboard |

All run with `SECURITY DEFINER`. Service role is granted EXECUTE. The anon dashboard only gets `get_sla_breaches` for the SLA widget.

---

## WF3a — Auction Launcher

Auction publishes a lead to a temporary `pending_auctions` row. When `expires_at` hits without a claim, WF3c picks a fallback agent. **At fallback assignment**, call:

```sql
SELECT mark_assigned(
  p_conversation_id := '{{ $json.conversation_id }}',
  p_agent_id        := '{{ $json.fallback_agent_id }}',
  p_claimed_via     := 'escalation'
);
```

Insertion point: after the `pending_auctions` UPDATE to `expired`, before the `manager_alert` send.

---

## WF3b — Claim Handler

Agent taps the WhatsApp claim button → webhook hits WF3b → atomic claim via existing `claim_auction()` function. **Immediately after** the atomic claim succeeds:

```sql
SELECT mark_assigned(
  p_conversation_id := '{{ $json.conversation_id }}',
  p_agent_id        := '{{ $json.claimer_agent_id }}',
  p_claimed_via     := 'tomo_auction'
);
```

For night-queue picks (manager assigns from `night_queue` at 8 AM via WF7):
```sql
SELECT mark_assigned(
  p_conversation_id := '{{ $json.conversation_id }}',
  p_agent_id        := '{{ $json.assigned_agent_id }}',
  p_claimed_via     := 'night_queue'
);
```

`mark_assigned` also flips `mode` from `ai`→`human` and bumps stage to `contacted`. So no separate stage update is needed at claim time.

---

## WF3c — Expiry Sweeper

Sweep runs every minute. When it escalates an unclaimed auction to the manager, treat manager assignment as `escalation` (see WF3a snippet).

---

## WF1 — Inbound Router (first_response_at)

WF1 already routes inbound + outbound traffic. Add **one Postgres node** on the **outbound human** branch (mode = `human`, direction = `outbound`, sender role = agent).

Insertion point: after the Evolution API send confirms 200 OK, before the message persistence node.

```sql
SELECT mark_first_response('{{ $json.conversation_id }}'::uuid);
```

The function is a no-op if `first_response_at` is already set, so it's safe to call on every outbound message (no need to gate it on "is this the first one").

This stamp is what drives the `agent_metrics.avg_response_sec_30d` and `sla_breaches` view.

---

## WF11 — SLA Monitor (new workflow)

WF11 doesn't exist yet. Create a fresh n8n workflow:

1. **Cron trigger** — every 5 minutes (Europe-style cron `*/5 * * * *`, no DST issues since UTC inside n8n).
2. **Postgres node — fetch breaches**
   ```sql
   SELECT * FROM get_sla_breaches();
   ```
3. **Loop over items** → for each breach:
   - **Postgres node — log breach**
     ```sql
     SELECT record_sla_breach(
       '{{ $json.conversation_id }}'::uuid,
       'SLA breach: ' || {{ $json.pending_seconds }} || 's sin respuesta'
     );
     ```
   - **HTTP node — Evolution API** → send manager nudge:
     ```
     ⚠️ {{ $json.lead_name }} ({{ $json.lead_phone }}) lleva
     {{ Math.floor($json.pending_seconds / 60) }} min sin respuesta.
     Asignado: {{ $json.agent_name }}. Stage: {{ $json.stage }}.
     ```
4. **Deduping**: `record_sla_breach` is append-only, so re-pinging every 5 min spams the manager. Add a guard before the HTTP send:
   ```sql
   SELECT NOT EXISTS (
     SELECT 1 FROM lead_status_history
     WHERE conversation_id = '{{ $json.conversation_id }}'::uuid
       AND note LIKE 'SLA breach%'
       AND changed_at > NOW() - INTERVAL '30 minutes'
   ) AS should_notify;
   ```
   Only notify when `should_notify` is true.

---

## Dashboard hooks (frontend, next session)

The dashboard already reads conversations. New pages will call:

- `update_lead_stage(...)` — Kanban drag/drop or stage-button click.
- `agent_metrics` view — Metrics tab (per-agent SLA + conversion).
- `sla_breaches` view — Live SLA widget on overview.
- `lead_status_history` — Lead detail page audit timeline.

Anon key has SELECT on the views; mutations go through `update_lead_stage` (RPC) which logs the change automatically via trigger.

---

## EasyBroker Degradation Strategy

EasyBroker stays in the loop **as a write-only ledger** so the client retains historical visibility in their existing tool. It is no longer the source of truth for assignment.

| Function | Before (EasyBroker) | Now (Supabase) |
|----------|---------------------|----------------|
| Agent assignment | EB user routing (broken — shared login) | `mark_assigned` RPC |
| Lead pipeline stage | EB pipeline columns | `lead_status` table |
| First-response SLA | not tracked | `first_response_at` + `sla_breaches` |
| Per-agent metrics | EB dashboard (shows only the shared user) | `agent_metrics` view |
| Audit log | EB activity stream | `lead_status_history` |

### What still writes to EasyBroker

- **WF8** (EasyBroker polling) — continues to PULL leads from EB into Supabase. **No change**.
- **WF2** (Lead Intake) — when a lead arrives from any source, push a "Lead" record to EB with the assigned agent name in a custom note field. This keeps EB readable for the client but does not depend on EB's routing.
- **Stage changes** — fire-and-forget POST to EB. If EB is down, log a warning and continue; Supabase is authoritative.

### What no longer writes to EasyBroker

- Assignment notifications. EB will show the shared user as the owner of every lead — this is expected. The agent name is in the custom note.

### Removal path

If/when BYG grants individual EB seats per agent, flip `assignment_method` back to `easybroker_legacy` and re-enable EB routing. The Supabase tables remain as the operational CRM regardless.

---

## Testing the helpers

```sql
-- pick any conversation
SELECT conversation_id, assigned_agent_id, assigned_at, first_response_at, mode
FROM conversations LIMIT 1;

-- simulate a claim
SELECT mark_assigned('<uuid>', '<agent_id>', 'manual');

-- simulate first response
SELECT mark_first_response('<uuid>');

-- check stamps
SELECT assigned_at, first_response_at, mode FROM conversations WHERE conversation_id = '<uuid>';
SELECT * FROM lead_status WHERE conversation_id = '<uuid>';
SELECT * FROM lead_status_history WHERE conversation_id = '<uuid>' ORDER BY changed_at;
```

---

## Open Questions for Next Session

1. WF11 manager-nudge channel: WhatsApp message vs Telegram alert? (current convention: Telegram for system, WhatsApp for client-facing).
2. Should `mark_first_response` also bump stage to `qualified`? Currently it does not — stage stays `contacted` until manual update.
3. Kanban dashboard view: ship as `/leads/pipeline` page or embed in `/leads` with a tab toggle?
