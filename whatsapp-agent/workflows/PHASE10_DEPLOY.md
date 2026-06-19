# Phase 10 — Agent Follow-Up: Activation Checklist (post-go-live)

Migration 0012 is already applied to prod (additive, safe). The workflow JSON is committed
but NOT yet imported into n8n. Import per the steps below and keep crons INACTIVE until the
smoke test passes.

## Preconditions
- [ ] Evolution bot number connected and stable (out of `device_removed` 401 cooldown).
- [ ] `agents.whatsapp_number` populated with each agent's real number (plain digits, no `+`).
- [ ] `MANAGER_PHONE` env set to the gerente's number.
- [ ] `OPENROUTER_API_KEY` / `OPENROUTER_MODEL` present (already used by WF4).

## Import + wire (n8n, CLI-only on VPS — see infra memory)
- [ ] Import WF14, WF15, WF16; set each node's Postgres credential to the real
      `Postgres - Supabase` credential ID (replaces `REPLACE_WITH_POSTGRES_CREDENTIAL_ID`).
- [ ] Set env `WF15_WORKFLOW_ID` to WF15's imported workflow ID.
- [ ] Re-import the edited WF1 (agent_followup_reply branch + Call WF15 node).

## Smoke test (manual, before activating crons)

Run against PROD. WF14 and WF16 are run via **Execute Workflow**. **WF15 MUST be active** —
in n8n 2.7 an `executeWorkflow` call to an inactive sub-workflow fails with "Workflow is not
active and cannot be executed", so WF1's Call WF15 node silently no-ops unless WF15 is active.
Required: WF14/15/16 imported, **WF15 active**, `WF15_WORKFLOW_ID` set, and the edited WF1
re-imported + active (WF1 owns the Evolution webhook). NOTE: `n8n import:workflow` resets
`active=false` — after every import run `n8n update:workflow --id=<id> --active=true` and
`docker compose restart n8n`. Use a **test agent whose WhatsApp you control**
(e.g. your own number temporarily set on a throwaway agent, or the gerente). All test rows
are torn down in step 6 — the unique test UUID below ensures nothing real is touched.

Pick the test agent once and keep its `agent_id` handy:
```sql
-- run in Supabase SQL editor; copy an agent_id whose whatsapp_number is a phone you can read
SELECT agent_id, name, whatsapp_number FROM agents ORDER BY name;
```

### 1. Seed a test lead assigned to the test agent
Replace `:AGENT` with the chosen agent_id (e.g. `agent_yol`).
```sql
INSERT INTO conversations (conversation_id, lead_phone, lead_name, assigned_agent_id, mode, assigned_at)
VALUES ('aaaaaaaa-0000-4000-8000-00000000a001','5215500000001','SMOKE TEST Lead',':AGENT','human', NOW() - INTERVAL '3 hours');
INSERT INTO lead_status (conversation_id, stage, updated_by)
VALUES ('aaaaaaaa-0000-4000-8000-00000000a001','new',':AGENT');
```
- [ ] Confirm the lead is due for a `new_2h` prompt:
```sql
SELECT prompt_kind, agent_number, lead_name
FROM leads_needing_followup WHERE conversation_id='aaaaaaaa-0000-4000-8000-00000000a001';
```
Expected: one row, `prompt_kind = new_2h`.

### 2. WF14 — manual run sends the question
- [ ] In n8n, open **WF14 - Follow-Up Sweeper**, click **Execute Workflow**.
- [ ] Confirm the test agent's WhatsApp receives a message like
      *"🔔 Tienes un lead nuevo: SMOKE TEST Lead por … ¿Ya lo contactaste? …"*.
- [ ] Confirm a pending tracker row was written:
```sql
SELECT status, prompt_kind FROM lead_followups WHERE conversation_id='aaaaaaaa-0000-4000-8000-00000000a001';
```
Expected: one row, `status = pending`, `prompt_kind = new_2h`.

### 3. WF15 — agent free-text reply advances the stage
- [ ] From the test agent's WhatsApp, reply in free text, e.g.
      *"Ya le marqué, agendamos visita el viernes"*.
- [ ] Confirm the agent gets a ✅ confirmation back (*"✅ Anotado: … Si algo está mal, escríbeme la corrección."*).
- [ ] Confirm the DB advanced:
```sql
SELECT (SELECT stage FROM lead_status WHERE conversation_id='aaaaaaaa-0000-4000-8000-00000000a001') AS stage,
       (SELECT status FROM lead_followups WHERE conversation_id='aaaaaaaa-0000-4000-8000-00000000a001' ORDER BY id DESC LIMIT 1) AS fu_status,
       (SELECT parsed_stage FROM lead_followups WHERE conversation_id='aaaaaaaa-0000-4000-8000-00000000a001' ORDER BY id DESC LIMIT 1) AS parsed;
```
Expected: `stage = visit_scheduled`, `fu_status = answered`, `parsed = visit_scheduled`.
(If the LLM read the date, also check `next_action_at` is set.)

### 4. Correction within 15 min
- [ ] Reply again, e.g. *"Perdón, la visita es el sábado, no viernes"* (or *"en realidad sigue en contacto, aún no agenda"*).
- [ ] Confirm the agent gets a fresh ✅ confirmation and the stage / next_action updates again:
```sql
SELECT stage, next_action, next_action_at FROM lead_status WHERE conversation_id='aaaaaaaa-0000-4000-8000-00000000a001';
```
Expected: reflects the correction (stage and/or next_action changed). This proves the
15-min correction window (`get_active_followup` returning the answered row) works.

### 5. WF16 — weekly report to gerente
- [ ] In n8n, open **WF16 - Weekly Gerente Report**, click **Execute Workflow**.
- [ ] Confirm `MANAGER_PHONE` receives a *"📊 Reporte semanal de seguimiento"* message with
      pipeline counts, this-week conversions, and per-agent responsiveness.

### 6. Teardown (always run — removes ALL smoke-test rows)
```sql
DELETE FROM messages       WHERE conversation_id='aaaaaaaa-0000-4000-8000-00000000a001';
DELETE FROM lead_followups WHERE conversation_id='aaaaaaaa-0000-4000-8000-00000000a001';
DELETE FROM lead_status_history WHERE conversation_id='aaaaaaaa-0000-4000-8000-00000000a001';
DELETE FROM lead_status    WHERE conversation_id='aaaaaaaa-0000-4000-8000-00000000a001';
DELETE FROM conversations  WHERE conversation_id='aaaaaaaa-0000-4000-8000-00000000a001';
```
- [ ] If you temporarily changed an agent's `whatsapp_number` for the test, restore it.

### Pass criteria
All of steps 1–5 produced the Expected result and teardown ran clean. If WF15 did NOT
advance the stage, check the n8n execution of WF15 `Advance Stage + Answer` — the query
MUST use `INSERT...SELECT ... FROM ans LEFT JOIN upd` (unreferenced CTEs are pruned by
Postgres and silently no-op).

## Activate
- [ ] Activate WF14, WF15, WF16. Watch first business-day run (WF14 fires 09–19h every 2h
      Mon–Sat; WF16 Monday 08:00).
- [ ] Day 1: spot-check that real agents receive questions and replies land in `lead_status`.
