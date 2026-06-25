# Owner-first routing — FLIP runbook (staged, NOT active)

Status as of 2026-06-24: **built staged, not wired into the live funnel.** Live
routing is still the flat guard auction (WF10 day route → WF3a fan-out), which
the client validated. Do NOT flip until the BYG data prerequisites below are
met — otherwise every lead falls to manager instead of asesores (regression).

## What is already done
- **DB (migration `0011_owner_routing.sql`)** applied to prod Supabase: table
  `property_agent_alias`, fn `resolve_agent_from_tags(text[])`, and
  `conversations.owner_agent_id / routing_tier / tier_notified_at`.
- **WF12 - Owner Resolver** (`w7yJr7naWoxPq6Pw`): live + **active** but orphaned
  (nothing calls it). Input `{property_public_id, conversation_id}` → returns
  `{owner_agent_id, owner_name, owner_number, resolved}` via EasyBroker tags.
- **WF13 - Directed Owner Notify (Cloud API)** (`Bo2YbbUpmBzRbhDa`): imported
  **INACTIVE**. Cloud-API form (send mirrors live WF3a: template
  `lead_subasta_notify` es_MX, 5 params, owner code + **2 min**). Creates a
  2-min owner-scoped auction, sets `routing_tier='owner'`, logs. Source of
  truth: `wa-rework/out/WF13_owner_notify_cloud.json`.

## BYG data prerequisites (client-side — owner-first is useless without these)
1. **Tag EVERY EasyBroker property** with the asesor name (and every new one on
   publish). Untagged → `resolve_agent_from_tags` returns NULL → manager.
2. **Add Tania to `agents`** + alias row `tania → agent_tania` in
   `property_agent_alias` (she's tagged in EB but missing from Supabase).
3. Fill `easybroker_email` for **Gina** and **Lety** (currently NULL).

## Flip steps (apply against the THEN-CURRENT live workflows — do not import the
## stale branch files; live is source of truth)

1. **WF10 (`Obr38705ZZYS3FB8`) — pass the EB code through.** In
   `Split & Normalize Leads`, add to the emitted json:
   `property_public_id: lead.property_public_id || null`. (The scraper already
   extracts `property_public_id` = `EB-XXXX` in `scraper.py`
   `_EXTRACT_LEAD_DETAIL_JS`; WF10 currently drops it.)

2. **WF10 day route — replace the flat auction with owner-first.** Today:
   `Route(day_auction) → Create Day Conversation → Prepare Auction Data →
   Cache Property → Call WF3a`. Change to:
   `Create Day Conversation → Prepare Routing Data (code: {property_public_id,
   conversation_id, lead_*, property_*}) → [Cache Property] + Call WF12
   (executeWorkflow w7yJr7naWoxPq6Pw) → Owner Resolved? (IF resolved===true)`:
   - **true** → `Prepare WF13 Payload` (code: pass conversation_id, lead_*,
     property_*, owner_agent_id/name/number from WF12) → `Call WF13`
     (executeWorkflow **`Bo2YbbUpmBzRbhDa`**).
   - **false** → `Set Manager Tier` (pg: `UPDATE conversations SET
     routing_tier='manager' WHERE conversation_id=$1`) → manager template send
     (Cloud API `lead_escalacion_manager`, to = `agent_manager.whatsapp_number`,
     mirror WF3c's manager send).
   **Remove the WF3a fan-out from the WF10 day path** — the guard auction now
   only runs via WF3c escalation (tier 2).

3. **WF3c (`UNIKqyAvIUAZkNIs`) — tiered escalation.** On each expired open
   auction, Switch on `conversations.routing_tier`:
   - `owner` → set `routing_tier='guard'` + **call WF3a** (`04aQhTOiXlDmN9bK`)
     guard auction (fan-out to on-shift calendar pool).
   - `guard` / NULL → assign `agent_manager` + manager template notify
     (current WF3c behavior — keep as the final tier).
   NULL tier stays backward-compatible (old flat behavior) during rollout.

4. **Set env on VPS** (`ssh root@69.62.108.2`, edit `/root/docker-compose.yml`
   n8n `environment:`, then `docker compose up -d n8n`):
   `WF13_WORKFLOW_ID=Bo2YbbUpmBzRbhDa`. (WF12_WORKFLOW_ID=w7yJr7naWoxPq6Pw is
   already set.) NOTE: this restarts the shared n8n briefly — do it at flip, not
   before.

5. **Activate WF13** (`POST /workflows/Bo2YbbUpmBzRbhDa/activate`), then PUT the
   edited WF10 + WF3c and reactivate each.

## Test plan (after flip, with one tagged property)
- Property `EB-VK1013` is tagged `Sandra` → resolves to `agent_manager` (Sandy).
  POST a test lead with that listing to `/webhook/scraper-leads` → confirm:
  owner (Sandy) gets the 2-min owner template → no claim in 2 min → WF3c
  escalates to guard auction (WF3a) → no claim 5 min → manager. Then re-export
  live WF10/WF3c/WF13 to `wa-rework/out` + `byg`.

## Why a runbook instead of pre-built WF10/WF3c JSON
Live n8n is the source of truth and keeps changing (templates, batch fix,
calendar fix were all applied live). A WF10/WF3c JSON staged now would be stale
by flip time — exactly how the original `feat/owner-first-routing` branch rotted
against the Evolution→Cloud-API migration. WF13 is staged as a finished
component because it is new and self-contained.
