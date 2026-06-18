# Agent Lead Follow-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give agents a WhatsApp-driven way to report progress on their assigned leads, record it in the existing CRM pipeline, and send the gerente a weekly report.

**Architecture:** Three new n8n workflows + one migration + one small edit to WF1. WF14 (cron sweeper) DMs the owning agent one lead at a time with a stage-appropriate question. The agent replies in free text; WF15 interprets it via OpenRouter, advances the pipeline stage (`update_lead_stage`), and confirms. WF16 sends a weekly WhatsApp summary to the gerente. A `lead_followups` tracker table maps each agent reply back to the correct lead. Reuses all existing CRM infra (`lead_status`, `update_lead_stage`, `agent_metrics`, `classify_sender`, Evolution send, OpenRouter call).

**Tech Stack:** Supabase Postgres, n8n (postgres v2.5, httpRequest v4.2, scheduleTrigger, executeWorkflow nodes), Evolution API, OpenRouter (`anthropic/claude-sonnet-4`).

**Status:** Build now, leave workflows INACTIVE. Activate post-go-live once the Evolution bot number is connected and `agents.whatsapp_number` is populated. Nothing here touches the lead-routing critical path (additive migration, separate workflows, one isolated WF1 branch).

**Spec:** `docs/superpowers/specs/2026-06-18-agent-lead-followup-design.md`

**Testing note (honesty):** DB tasks are fully testable now via a Supabase dev branch
(`mcp__supabase__create_branch` → `apply_migration` → `execute_sql` assertions → `merge_branch`).
n8n workflow JSON is verified by (a) JSON validity, (b) node/connection sanity, (c) manual
import into n8n. True end-to-end WhatsApp send/receive is a **post-go-live smoke test** —
it cannot be verified now because the Evolution bot number is in a `device_removed` cooldown.
Do NOT claim the live flow works until that smoke test passes.

---

## File Structure

- Create: `whatsapp-agent/migrations/0012_agent_followups.sql` — tracker table, cadence view, helper functions, weekly summary view.
- Create: `whatsapp-agent/workflows/WF14_followup_sweeper.json` — cron sweeper that sends stage-based follow-up questions.
- Create: `whatsapp-agent/workflows/WF15_followup_reply.json` — interprets agent replies, advances stage, confirms.
- Create: `whatsapp-agent/workflows/WF16_weekly_report.json` — Monday WhatsApp summary to gerente.
- Modify: `whatsapp-agent/workflows/WF1_inbound_router.json` — reroute agent non-TOMO messages to WF15.
- Modify: `whatsapp-agent/.env.example` (or deployment notes) — add `WF15_WORKFLOW_ID`.

---

## Task 1: Migration — `lead_followups` table

**Files:**
- Create: `whatsapp-agent/migrations/0012_agent_followups.sql`

- [ ] **Step 1: Write the table + indexes + RLS**

Create the file with this header and section 1:

```sql
-- ============================================================================
-- 0012_agent_followups.sql -- Agent lead follow-up tracker (Phase 10)
--
-- Adds a pending-prompt tracker so the follow-up sweeper (WF14) can ask agents
-- about ONE lead at a time and map each free-text reply (WF15) back to the
-- correct lead. Also adds the stage-based cadence view, reply-matching helpers,
-- and a weekly-report summary view.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- 1. tracker table -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS lead_followups (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id UUID NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  agent_id        TEXT NOT NULL REFERENCES agents(agent_id),
  prompt_kind     TEXT NOT NULL
                  CHECK (prompt_kind IN ('new_2h','new_24h','stalled','visit_day')),
  prompt_sent_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  answered_at     TIMESTAMPTZ,
  response_text   TEXT,
  parsed_stage    TEXT,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','answered','expired'))
);
COMMENT ON TABLE lead_followups IS
  'One row per follow-up question sent to an agent. Maps agent reply -> lead; feeds weekly report.';

CREATE INDEX IF NOT EXISTS idx_followups_agent_active
  ON lead_followups(agent_id, prompt_sent_at DESC)
  WHERE status IN ('pending','answered');
CREATE INDEX IF NOT EXISTS idx_followups_conv
  ON lead_followups(conversation_id, status);
-- Hard backstop: at most ONE pending prompt per lead at a time (no pile-up).
CREATE UNIQUE INDEX IF NOT EXISTS idx_followups_one_pending
  ON lead_followups(conversation_id)
  WHERE status = 'pending';

ALTER TABLE lead_followups ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE tablename='lead_followups' AND policyname='followups_read') THEN
    CREATE POLICY followups_read ON lead_followups FOR SELECT USING (true);
  END IF;
END $$;
```

- [ ] **Step 2: Apply to a Supabase dev branch and verify the table exists**

Use `mcp__supabase__create_branch` (name `followup-dev`), then `mcp__supabase__apply_migration`
with the file contents, then `mcp__supabase__execute_sql`:

```sql
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name='lead_followups' ORDER BY ordinal_position;
```
Expected: 9 columns (`id, conversation_id, agent_id, prompt_kind, prompt_sent_at, answered_at, response_text, parsed_stage, status`).

- [ ] **Step 3: Verify the one-pending backstop**

```sql
-- pick any existing conversation_id + agent_id first
INSERT INTO lead_followups (conversation_id, agent_id, prompt_kind)
SELECT c.conversation_id, c.assigned_agent_id, 'new_2h'
FROM conversations c WHERE c.assigned_agent_id IS NOT NULL LIMIT 1;
-- second pending insert for SAME conversation must fail:
INSERT INTO lead_followups (conversation_id, agent_id, prompt_kind)
SELECT conversation_id, agent_id, 'new_24h' FROM lead_followups WHERE status='pending' LIMIT 1;
```
Expected: second insert raises `duplicate key value violates unique constraint "idx_followups_one_pending"`. Then clean up: `DELETE FROM lead_followups;`

- [ ] **Step 4: Commit**

```
git add whatsapp-agent/migrations/0012_agent_followups.sql
git commit -m "feat(followup): lead_followups tracker table (migration 0012 part 1)"
```

---

## Task 2: Migration — stage-based cadence view

**Files:**
- Modify: `whatsapp-agent/migrations/0012_agent_followups.sql`

- [ ] **Step 1: Append the cadence view**

Append section 2 to the migration file:

```sql
-- 2. cadence view: which (lead, prompt_kind) are due right now -----------------
-- Owning agent = conversations.assigned_agent_id (lead already claimed).
-- Excludes closed leads and any lead that currently has a pending prompt.
CREATE OR REPLACE VIEW leads_needing_followup AS
WITH base AS (
  SELECT
    c.conversation_id,
    c.lead_name,
    c.lead_phone,
    c.assigned_agent_id              AS agent_id,
    a.name                           AS agent_name,
    a.whatsapp_number                AS agent_number,
    c.assigned_at,
    c.first_response_at,
    c.current_property,
    COALESCE(ls.stage,'new')         AS stage,
    ls.stage_changed_at,
    ls.next_action_at,
    COALESCE(pc.payload->>'title', c.current_property, 'la propiedad') AS property_title,
    NULLIF(pc.payload->>'operation_type','')                          AS operation
  FROM conversations c
  JOIN agents a            ON a.agent_id = c.assigned_agent_id
  LEFT JOIN lead_status ls ON ls.conversation_id = c.conversation_id
  LEFT JOIN properties_cache pc ON pc.property_id = c.current_property
  WHERE c.assigned_agent_id IS NOT NULL
    AND COALESCE(ls.stage,'new') NOT IN ('closed_won','closed_lost')
    AND NOT EXISTS (
      SELECT 1 FROM lead_followups f
      WHERE f.conversation_id = c.conversation_id AND f.status = 'pending'
    )
)
-- new_2h: assigned >2h ago, agent never replied, not yet asked
SELECT b.*, 'new_2h'::text AS prompt_kind FROM base b
WHERE b.stage IN ('new','contacted')
  AND b.first_response_at IS NULL
  AND b.assigned_at <= NOW() - INTERVAL '2 hours'
  AND NOT EXISTS (SELECT 1 FROM lead_followups f
                  WHERE f.conversation_id=b.conversation_id AND f.prompt_kind='new_2h')
UNION ALL
-- new_24h: same, but 24h escalation
SELECT b.*, 'new_24h' FROM base b
WHERE b.stage IN ('new','contacted')
  AND b.first_response_at IS NULL
  AND b.assigned_at <= NOW() - INTERVAL '24 hours'
  AND NOT EXISTS (SELECT 1 FROM lead_followups f
                  WHERE f.conversation_id=b.conversation_id AND f.prompt_kind='new_24h')
UNION ALL
-- stalled: in-progress stage with no change in 2 days, not nudged in last 2 days
SELECT b.*, 'stalled' FROM base b
WHERE b.stage IN ('contacted','qualified','offer')
  AND b.stage_changed_at <= NOW() - INTERVAL '2 days'
  AND NOT EXISTS (SELECT 1 FROM lead_followups f
                  WHERE f.conversation_id=b.conversation_id AND f.prompt_kind='stalled'
                    AND f.prompt_sent_at > NOW() - INTERVAL '2 days')
UNION ALL
-- visit_day: visit scheduled for today, not yet reminded today
SELECT b.*, 'visit_day' FROM base b
WHERE b.stage = 'visit_scheduled'
  AND b.next_action_at::date = CURRENT_DATE
  AND NOT EXISTS (SELECT 1 FROM lead_followups f
                  WHERE f.conversation_id=b.conversation_id AND f.prompt_kind='visit_day'
                    AND f.prompt_sent_at::date = CURRENT_DATE);

COMMENT ON VIEW leads_needing_followup IS
  'Stage-based cadence: emits (lead, agent, prompt_kind) rows due for a follow-up DM.';
```

- [ ] **Step 2: Re-apply migration to the dev branch and seed a due lead**

`apply_migration` again (idempotent), then seed via `execute_sql`:

```sql
-- make an existing assigned lead look 3h old with no agent reply, stage 'new'
UPDATE conversations SET assigned_at = NOW() - INTERVAL '3 hours', first_response_at = NULL
WHERE conversation_id = (SELECT conversation_id FROM conversations WHERE assigned_agent_id IS NOT NULL LIMIT 1);
SELECT conversation_id, agent_id, prompt_kind FROM leads_needing_followup;
```
Expected: at least one row with `prompt_kind='new_2h'` for that lead.

- [ ] **Step 3: Verify pending suppression**

```sql
INSERT INTO lead_followups (conversation_id, agent_id, prompt_kind)
SELECT conversation_id, agent_id, prompt_kind FROM leads_needing_followup LIMIT 1;
SELECT count(*) FROM leads_needing_followup;  -- that lead must drop out
```
Expected: the lead with a now-pending row no longer appears. Clean up: `DELETE FROM lead_followups;`

- [ ] **Step 4: Commit**

```
git add whatsapp-agent/migrations/0012_agent_followups.sql
git commit -m "feat(followup): stage-based cadence view leads_needing_followup"
```

---

## Task 3: Migration — reply-matching + report helpers

**Files:**
- Modify: `whatsapp-agent/migrations/0012_agent_followups.sql`

- [ ] **Step 1: Append helper functions + weekly summary view**

Append section 3:

```sql
-- 3a. record a sent prompt (called by WF14 after a successful send) -----------
CREATE OR REPLACE FUNCTION record_followup_sent(
  p_conversation_id uuid, p_agent_id text, p_kind text
) RETURNS bigint AS $$
  INSERT INTO lead_followups (conversation_id, agent_id, prompt_kind)
  VALUES (p_conversation_id, p_agent_id, p_kind)
  RETURNING id;
$$ LANGUAGE sql;

-- 3b. find the active followup for an agent (WF15) ----------------------------
-- Returns the pending prompt if any; else the most-recently-answered prompt
-- within 15 min (a correction window). is_correction tells WF15 which it is.
CREATE OR REPLACE FUNCTION get_active_followup(p_agent_id text)
RETURNS TABLE(
  followup_id bigint, conversation_id uuid, lead_name text,
  prompt_kind text, current_stage text, is_correction boolean
) AS $$
  SELECT f.id, f.conversation_id, c.lead_name, f.prompt_kind,
         COALESCE(ls.stage,'new'), (f.status='answered') AS is_correction
  FROM lead_followups f
  JOIN conversations c     ON c.conversation_id = f.conversation_id
  LEFT JOIN lead_status ls ON ls.conversation_id = f.conversation_id
  WHERE f.agent_id = p_agent_id
    AND (f.status='pending'
         OR (f.status='answered' AND f.answered_at > NOW() - INTERVAL '15 minutes'))
  ORDER BY (f.status='pending') DESC, f.prompt_sent_at DESC
  LIMIT 1;
$$ LANGUAGE sql STABLE;

-- 3c. mark a followup answered (WF15, after update_lead_stage) -----------------
CREATE OR REPLACE FUNCTION answer_followup(
  p_followup_id bigint, p_response text, p_stage text
) RETURNS void AS $$
  UPDATE lead_followups
  SET status='answered', answered_at=NOW(), response_text=p_response, parsed_stage=p_stage
  WHERE id = p_followup_id;
$$ LANGUAGE sql;

-- 3d. weekly summary of unanswered follow-ups (WF16) --------------------------
CREATE OR REPLACE VIEW weekly_followup_summary AS
SELECT
  a.agent_id,
  a.name AS agent_name,
  count(*) FILTER (WHERE f.status='pending')  AS pending_count,
  count(*) FILTER (WHERE f.status='expired'
                   AND f.prompt_sent_at >= NOW() - INTERVAL '7 days') AS expired_7d,
  count(*) FILTER (WHERE f.status='answered'
                   AND f.answered_at >= NOW() - INTERVAL '7 days')    AS answered_7d
FROM agents a
LEFT JOIN lead_followups f ON f.agent_id = a.agent_id
GROUP BY a.agent_id, a.name;

COMMENT ON VIEW weekly_followup_summary IS
  'Per-agent follow-up responsiveness for the weekly gerente report (WF16).';
```

- [ ] **Step 2: Re-apply and test the helpers round-trip**

`apply_migration`, then `execute_sql`:

```sql
-- seed one pending followup for a known agent
INSERT INTO lead_followups (conversation_id, agent_id, prompt_kind)
SELECT conversation_id, assigned_agent_id, 'new_2h'
FROM conversations WHERE assigned_agent_id IS NOT NULL LIMIT 1;
-- get_active_followup returns it, is_correction=false
SELECT * FROM get_active_followup(
  (SELECT agent_id FROM lead_followups WHERE status='pending' LIMIT 1));
-- answer it
SELECT answer_followup(
  (SELECT followup_id FROM get_active_followup(
     (SELECT agent_id FROM lead_followups WHERE status='pending' LIMIT 1))),
  'ya le marqué, agendamos visita el viernes', 'visit_scheduled');
-- now get_active_followup returns the same row with is_correction=true (within 15m)
SELECT followup_id, is_correction, current_stage FROM get_active_followup(
  (SELECT agent_id FROM lead_followups WHERE status='answered' LIMIT 1));
```
Expected: first select `is_correction=false`; after `answer_followup`, status is `answered`; final select returns the row with `is_correction=true`. Clean up: `DELETE FROM lead_followups;`

- [ ] **Step 3: Merge the dev branch and commit**

Verify no advisors regressions: `mcp__supabase__get_advisors` (type `security`). Then
`mcp__supabase__merge_branch` to apply 0012 to production (SAFE — purely additive, no
changes to existing tables/flows).

```
git add whatsapp-agent/migrations/0012_agent_followups.sql
git commit -m "feat(followup): reply-matching helpers + weekly summary view"
```

---

## Task 4: WF14 — Follow-Up Sweeper workflow

**Files:**
- Create: `whatsapp-agent/workflows/WF14_followup_sweeper.json`

- [ ] **Step 1: Write the workflow JSON**

Create the file. Nodes: Schedule (cron `0 9-19/2 * * 1-6`) → Expire stale pendings →
Select due leads → (auto per-item) Build message → Send via Evolution → Record + log.

```json
{
  "name": "WF14 - Follow-Up Sweeper (Evolution)",
  "nodes": [
    {
      "parameters": {
        "rule": { "interval": [ { "field": "cronExpression", "expression": "0 9-19/2 * * 1-6" } ] }
      },
      "id": "f1f2f3f4-0001-4000-8000-000000000001",
      "name": "Business Hours Cron",
      "type": "n8n-nodes-base.scheduleTrigger",
      "typeVersion": 1.2,
      "position": [200, 300],
      "notes": "Every 2h, 09:00-19:00, Mon-Sat. Sends stage-based follow-up questions to owning agents."
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "-- Expire prompts unanswered for >3 days so they stop blocking new cadence and feed the weekly report.\nUPDATE lead_followups SET status='expired'\nWHERE status='pending' AND prompt_sent_at < NOW() - INTERVAL '3 days'\nRETURNING id;",
        "options": {}
      },
      "id": "f1f2f3f4-0002-4000-8000-000000000002",
      "name": "Expire Stale Pendings",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.5,
      "position": [440, 300],
      "credentials": { "postgres": { "id": "REPLACE_WITH_POSTGRES_CREDENTIAL_ID", "name": "Postgres - Supabase" } },
      "alwaysOutputData": true
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "SELECT conversation_id, agent_id, agent_name, agent_number, lead_name, property_title, operation, stage, prompt_kind FROM leads_needing_followup;",
        "options": {}
      },
      "id": "f1f2f3f4-0003-4000-8000-000000000003",
      "name": "Select Due Leads",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.5,
      "position": [680, 300],
      "credentials": { "postgres": { "id": "REPLACE_WITH_POSTGRES_CREDENTIAL_ID", "name": "Postgres - Supabase" } },
      "alwaysOutputData": true
    },
    {
      "parameters": {
        "jsCode": "// One item per due lead. Build a stage-appropriate question for the owning agent.\nconst r = $input.item.json;\nif (!r || !r.conversation_id) { return []; }\nconst op = r.operation ? ` (${r.operation})` : '';\nconst lead = r.lead_name || 'el lead';\nconst prop = r.property_title || 'la propiedad';\nlet q;\nswitch (r.prompt_kind) {\n  case 'new_2h':\n    q = `\\u{1F514} Tienes un lead nuevo: *${lead}* por ${prop}${op}. \\u00bfYa lo contactaste? Cu\\u00e9ntame en qu\\u00e9 qued\\u00f3 y el pr\\u00f3ximo paso.`; break;\n  case 'new_24h':\n    q = `\\u23F0 Recordatorio: *${lead}* (${prop}${op}) sigue sin registrar contacto. \\u00bfPudiste comunicarte? \\u00bfQu\\u00e9 sigue?`; break;\n  case 'stalled':\n    q = `\\u{1F4CB} \\u00bfC\\u00f3mo va *${lead}* por ${prop}${op}? No hay novedades hace unos d\\u00edas. \\u00bfEn qu\\u00e9 etapa est\\u00e1 y cu\\u00e1l es el siguiente paso?`; break;\n  case 'visit_day':\n    q = `\\u{1F4C5} Hoy es la visita con *${lead}* por ${prop}${op}. \\u00bfSigue en pie? Av\\u00edsame c\\u00f3mo te va.`; break;\n  default:\n    q = `\\u{1F4CB} \\u00bfC\\u00f3mo va *${lead}* por ${prop}${op}?`;\n}\nreturn [{ json: { number: r.agent_number, text: q, conversation_id: r.conversation_id, agent_id: r.agent_id, prompt_kind: r.prompt_kind } }];"
      },
      "id": "f1f2f3f4-0004-4000-8000-000000000004",
      "name": "Build Question",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [920, 300]
    },
    {
      "parameters": {
        "method": "POST",
        "url": "={{ $env.EVOLUTION_API_URL }}/message/sendText/{{ $env.EVOLUTION_INSTANCE }}",
        "sendHeaders": true,
        "headerParameters": { "parameters": [ { "name": "apikey", "value": "={{ $env.EVOLUTION_API_KEY }}" } ] },
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={\n  \"number\": \"{{ $json.number }}\",\n  \"text\": {{ JSON.stringify($json.text) }},\n  \"delay\": 1200\n}",
        "options": { "timeout": 15000 }
      },
      "id": "f1f2f3f4-0005-4000-8000-000000000005",
      "name": "Send Question via Evolution",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [1160, 300],
      "continueOnFail": true
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "-- Record the sent prompt (creates the pending tracker row) and log the outbound message.\nWITH ins AS (\n  SELECT record_followup_sent($1::uuid, $2, $3) AS followup_id\n)\nINSERT INTO messages (conversation_id, direction, sender_type, recipient_phone, body, metadata)\nSELECT $1::uuid, 'outbound', 'system', $4, $5,\n       jsonb_build_object('purpose','followup_question','prompt_kind',$3,'followup_id',ins.followup_id)\nFROM ins\nRETURNING conversation_id;",
        "options": {
          "queryReplacement": "={{ $json.conversation_id }},={{ $json.agent_id }},={{ $json.prompt_kind }},={{ $json.number }},={{ $json.text }}"
        }
      },
      "id": "f1f2f3f4-0006-4000-8000-000000000006",
      "name": "Record + Log",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.5,
      "position": [1400, 300],
      "credentials": { "postgres": { "id": "REPLACE_WITH_POSTGRES_CREDENTIAL_ID", "name": "Postgres - Supabase" } },
      "continueOnFail": true
    }
  ],
  "connections": {
    "Business Hours Cron": { "main": [[{ "node": "Expire Stale Pendings", "type": "main", "index": 0 }]] },
    "Expire Stale Pendings": { "main": [[{ "node": "Select Due Leads", "type": "main", "index": 0 }]] },
    "Select Due Leads": { "main": [[{ "node": "Build Question", "type": "main", "index": 0 }]] },
    "Build Question": { "main": [[{ "node": "Send Question via Evolution", "type": "main", "index": 0 }]] },
    "Send Question via Evolution": { "main": [[{ "node": "Record + Log", "type": "main", "index": 0 }]] }
  },
  "settings": { "executionOrder": "v1", "saveExecutionProgress": true, "saveManualExecutions": true }
}
```

- [ ] **Step 2: Validate JSON + sanity-check nodes/connections**

Run:
```
python -c "import json,sys; d=json.load(open(r'whatsapp-agent/workflows/WF14_followup_sweeper.json',encoding='utf-8')); print('nodes',len(d['nodes'])); print('conns',list(d['connections'].keys()))"
```
Expected: `nodes 6` and 5 connection keys ending at `Send Question via Evolution`. If it raises, fix the JSON.

- [ ] **Step 3: Commit**

```
git add whatsapp-agent/workflows/WF14_followup_sweeper.json
git commit -m "feat(followup): WF14 stage-based follow-up sweeper"
```

---

## Task 5: WF15 — Agent Reply Handler workflow

**Files:**
- Create: `whatsapp-agent/workflows/WF15_followup_reply.json`

- [ ] **Step 1: Write the workflow JSON**

Nodes: executeWorkflowTrigger (from WF1) → Get active followup → IF found →
Build parse prompt → OpenRouter → Parse JSON → Update stage → Mark answered →
Send confirmation. If no active followup → silent No-Op (avoid spamming agents mid-chat).

```json
{
  "name": "WF15 - Follow-Up Reply Handler (Evolution)",
  "nodes": [
    {
      "parameters": { "inputSource": "passthrough" },
      "id": "a5a5a5a5-0001-4000-8000-000000000001",
      "name": "When Called by WF1",
      "type": "n8n-nodes-base.executeWorkflowTrigger",
      "typeVersion": 1,
      "position": [200, 300],
      "notes": "Input from WF1 agent branch:\n{ agent_id, agent_name, agent_phone, text, messageId }"
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "SELECT followup_id, conversation_id, lead_name, prompt_kind, current_stage, is_correction FROM get_active_followup($1);",
        "options": { "queryReplacement": "={{ $json.agent_id }}" }
      },
      "id": "a5a5a5a5-0002-4000-8000-000000000002",
      "name": "Get Active Followup",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.5,
      "position": [440, 300],
      "credentials": { "postgres": { "id": "REPLACE_WITH_POSTGRES_CREDENTIAL_ID", "name": "Postgres - Supabase" } },
      "alwaysOutputData": true
    },
    {
      "parameters": {
        "conditions": {
          "options": { "caseSensitive": true, "typeValidation": "loose", "version": 2 },
          "conditions": [
            { "id": "has-followup", "leftValue": "={{ $json.followup_id }}", "rightValue": "", "operator": { "type": "number", "operation": "exists", "singleValue": true } }
          ],
          "combinator": "and"
        }
      },
      "id": "a5a5a5a5-0003-4000-8000-000000000003",
      "name": "Active Followup?",
      "type": "n8n-nodes-base.if",
      "typeVersion": 2.2,
      "position": [680, 300]
    },
    {
      "parameters": {
        "jsCode": "// Build a strict-JSON extraction prompt for the agent's free-text reply.\nconst trig = $('When Called by WF1').first().json;\nconst fu = $('Get Active Followup').first().json;\nconst system = `Eres un asistente que interpreta el reporte de un asesor inmobiliario sobre un lead.\\nEtapa actual del lead: ${fu.current_stage}.\\nEtapas validas: new, contacted, qualified, visit_scheduled, offer, closed_won, closed_lost.\\n\\nDevuelve SOLO un objeto JSON (sin texto extra) con esta forma:\\n{\\n  \\\"stage\\\": \\\"<una de las etapas validas, la mas avanzada que implique el mensaje>\\\",\\n  \\\"note\\\": \\\"<resumen corto del avance en espanol>\\\",\\n  \\\"next_action\\\": \\\"<proximo paso o null>\\\",\\n  \\\"next_action_at\\\": \\\"<fecha ISO 8601 si el asesor menciono una fecha/hora concreta, o null>\\\",\\n  \\\"confirmation\\\": \\\"<una frase corta para confirmar al asesor lo que registraste>\\\"\\n}\\nReglas: si el mensaje no implica avance claro, mantiene la etapa actual. Si menciona 'visita/cita' usa visit_scheduled. Si menciona 'cerro/vendido/rentado' usa closed_won. Si 'no le interesa/perdido' usa closed_lost. Interpreta fechas relativas (ej. 'el viernes') segun la fecha de hoy ${new Date().toISOString().slice(0,10)}.`;\nconst chatMessages = [ { role:'system', content: system }, { role:'user', content: trig.text } ];\nreturn [{ json: { chatMessages, followup_id: fu.followup_id, conversation_id: fu.conversation_id, agent_id: trig.agent_id, agent_phone: trig.agent_phone, lead_name: fu.lead_name, raw_text: trig.text } }];"
      },
      "id": "a5a5a5a5-0004-4000-8000-000000000004",
      "name": "Build Parse Prompt",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [920, 200]
    },
    {
      "parameters": {
        "method": "POST",
        "url": "https://openrouter.ai/api/v1/chat/completions",
        "sendHeaders": true,
        "headerParameters": { "parameters": [
          { "name": "Authorization", "value": "=Bearer {{ $env.OPENROUTER_API_KEY }}" },
          { "name": "Content-Type", "value": "application/json" }
        ] },
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={\n  \"model\": \"{{ $env.OPENROUTER_MODEL || 'anthropic/claude-sonnet-4' }}\",\n  \"messages\": {{ JSON.stringify($json.chatMessages) }},\n  \"max_tokens\": 300,\n  \"temperature\": 0.2,\n  \"response_format\": { \"type\": \"json_object\" }\n}",
        "options": { "timeout": 30000 }
      },
      "id": "a5a5a5a5-0005-4000-8000-000000000005",
      "name": "Call OpenRouter LLM",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [1160, 200],
      "continueOnFail": true
    },
    {
      "parameters": {
        "jsCode": "// Parse the LLM JSON. Guard against malformed output.\nconst ctx = $('Build Parse Prompt').first().json;\nconst resp = $input.first().json;\nlet raw='';\ntry { raw = resp.choices[0].message.content || ''; } catch(e) { raw=''; }\nlet parsed={};\ntry { parsed = JSON.parse(raw); } catch(e) {\n  // fallback: keep current stage, store the raw text as the note\n  parsed = { stage: null, note: ctx.raw_text, next_action: null, next_action_at: null, confirmation: 'Anotado.' };\n}\nconst valid=['new','contacted','qualified','visit_scheduled','offer','closed_won','closed_lost'];\nconst stage = valid.includes(parsed.stage) ? parsed.stage : null;\nreturn [{ json: {\n  followup_id: ctx.followup_id,\n  conversation_id: ctx.conversation_id,\n  agent_id: ctx.agent_id,\n  agent_phone: ctx.agent_phone,\n  raw_text: ctx.raw_text,\n  stage,\n  note: parsed.note || ctx.raw_text,\n  next_action: parsed.next_action || null,\n  next_action_at: parsed.next_action_at || null,\n  confirmation: parsed.confirmation || 'Anotado.'\n} }];"
      },
      "id": "a5a5a5a5-0006-4000-8000-000000000006",
      "name": "Parse LLM JSON",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [1400, 200]
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "-- Advance stage (only if the LLM returned a valid stage), mark the followup answered, log the inbound reply.\nWITH upd AS (\n  SELECT CASE WHEN $5 IS NOT NULL AND $5 <> ''\n    THEN (SELECT 1 FROM update_lead_stage($1::uuid, $5, $2, $6, $7, NULLIF($8,'')::timestamptz))\n    ELSE NULL END AS did\n),\nans AS ( SELECT answer_followup($3::bigint, $4, NULLIF($5,'')) )\nINSERT INTO messages (conversation_id, direction, sender_type, body, metadata)\nVALUES ($1::uuid, 'inbound', 'agent', $4,\n        jsonb_build_object('purpose','followup_reply','followup_id',$3,'parsed_stage',$5))\nRETURNING conversation_id;",
        "options": {
          "queryReplacement": "={{ $json.conversation_id }},={{ $json.agent_id }},={{ $json.followup_id }},={{ $json.raw_text }},={{ $json.stage }},={{ $json.note }},={{ $json.next_action }},={{ $json.next_action_at }}"
        }
      },
      "id": "a5a5a5a5-0007-4000-8000-000000000007",
      "name": "Advance Stage + Answer",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.5,
      "position": [1640, 200],
      "credentials": { "postgres": { "id": "REPLACE_WITH_POSTGRES_CREDENTIAL_ID", "name": "Postgres - Supabase" } },
      "continueOnFail": true
    },
    {
      "parameters": {
        "method": "POST",
        "url": "={{ $env.EVOLUTION_API_URL }}/message/sendText/{{ $env.EVOLUTION_INSTANCE }}",
        "sendHeaders": true,
        "headerParameters": { "parameters": [ { "name": "apikey", "value": "={{ $env.EVOLUTION_API_KEY }}" } ] },
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={\n  \"number\": \"{{ $('Parse LLM JSON').first().json.agent_phone }}\",\n  \"text\": {{ JSON.stringify('\\u2705 ' + $('Parse LLM JSON').first().json.confirmation + '\\n\\nSi algo esta mal, escribeme la correccion.') }}\n}",
        "options": { "timeout": 10000 }
      },
      "id": "a5a5a5a5-0008-4000-8000-000000000008",
      "name": "Send Confirmation",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [1880, 200],
      "continueOnFail": true
    },
    {
      "parameters": {},
      "id": "a5a5a5a5-0009-4000-8000-000000000009",
      "name": "No Active Followup (silent)",
      "type": "n8n-nodes-base.noOp",
      "typeVersion": 1,
      "position": [920, 420],
      "notes": "Agent texted the bot but has no pending/recent follow-up. Stay silent to avoid noise."
    }
  ],
  "connections": {
    "When Called by WF1": { "main": [[{ "node": "Get Active Followup", "type": "main", "index": 0 }]] },
    "Get Active Followup": { "main": [[{ "node": "Active Followup?", "type": "main", "index": 0 }]] },
    "Active Followup?": { "main": [
      [{ "node": "Build Parse Prompt", "type": "main", "index": 0 }],
      [{ "node": "No Active Followup (silent)", "type": "main", "index": 0 }]
    ] },
    "Build Parse Prompt": { "main": [[{ "node": "Call OpenRouter LLM", "type": "main", "index": 0 }]] },
    "Call OpenRouter LLM": { "main": [[{ "node": "Parse LLM JSON", "type": "main", "index": 0 }]] },
    "Parse LLM JSON": { "main": [[{ "node": "Advance Stage + Answer", "type": "main", "index": 0 }]] },
    "Advance Stage + Answer": { "main": [[{ "node": "Send Confirmation", "type": "main", "index": 0 }]] }
  },
  "settings": { "executionOrder": "v1", "saveExecutionProgress": true, "saveManualExecutions": true }
}
```

- [ ] **Step 2: Validate JSON + node count**

```
python -c "import json; d=json.load(open(r'whatsapp-agent/workflows/WF15_followup_reply.json',encoding='utf-8')); print('nodes',len(d['nodes']))"
```
Expected: `nodes 9`. If it raises, fix the JSON.

- [ ] **Step 3: Dry-run the parse SQL against the dev branch**

On the dev branch (recreate if merged), seed a pending followup, then run the
`Advance Stage + Answer` query with literal values simulating a "visit scheduled" reply:

```sql
-- seed
INSERT INTO lead_followups (conversation_id, agent_id, prompt_kind)
SELECT conversation_id, assigned_agent_id, 'new_2h' FROM conversations WHERE assigned_agent_id IS NOT NULL LIMIT 1;
-- simulate WF15's write (followup_id/conversation_id/agent from the seeded row)
WITH t AS (SELECT id, conversation_id, agent_id FROM lead_followups WHERE status='pending' LIMIT 1),
upd AS ( SELECT (SELECT 1 FROM update_lead_stage((SELECT conversation_id FROM t),'visit_scheduled',(SELECT agent_id FROM t),'agendó visita viernes','llamar viernes', (CURRENT_DATE + 2)::timestamptz)) ),
ans AS ( SELECT answer_followup((SELECT id FROM t),'agendamos visita el viernes','visit_scheduled') )
SELECT 'ok';
-- verify
SELECT stage FROM lead_status WHERE conversation_id=(SELECT conversation_id FROM lead_followups WHERE status='answered' LIMIT 1);
SELECT status, parsed_stage FROM lead_followups WHERE status='answered' LIMIT 1;
```
Expected: `lead_status.stage='visit_scheduled'`, `lead_followups.status='answered'`, `parsed_stage='visit_scheduled'`, and a row in `lead_status_history`. Clean up.

- [ ] **Step 4: Commit**

```
git add whatsapp-agent/workflows/WF15_followup_reply.json
git commit -m "feat(followup): WF15 agent reply handler (IA parse -> update_lead_stage)"
```

---

## Task 6: WF1 — route agent follow-up replies to WF15

**Files:**
- Modify: `whatsapp-agent/workflows/WF1_inbound_router.json`

- [ ] **Step 1: Change the agent non-claim branch in `Classify & Route`**

In the `Classify & Route` code node (`id: 249f2966-...`), find the agent non-claim return:

```js
  // Agent sent something else - ignore for now
  return [{ json: { route: 'ignore', reason: 'agent_non_claim_message' } }];
```

Replace it with:

```js
  // Agent sent a non-TOMO message -> treat as a follow-up reply (WF15 decides if relevant)
  return [{
    json: {
      route: 'agent_followup_reply',
      agent_id: db.agent_id,
      agent_name: db.agent_name,
      agent_phone: phone,
      text,
      messageId
    }
  }];
```

- [ ] **Step 2: Add a switch output + WF15 call node**

In the `Route Message` switch (`id: d7a2e059-...`), add a new rule value after the
`pending` rule (so it becomes output index 5, before the fallback):

```json
{
  "conditions": {
    "options": { "caseSensitive": true, "typeValidation": "strict", "leftValue": "" },
    "conditions": [
      { "leftValue": "={{ $json.route }}", "rightValue": "agent_followup_reply",
        "operator": { "type": "string", "operation": "equals" },
        "id": "c0ffee00-0001-4000-8000-000000000001" }
    ],
    "combinator": "and"
  },
  "renameOutput": true,
  "outputKey": "agent_followup_reply"
}
```

Add this node to the `nodes` array:

```json
{
  "parameters": { "source": "database", "workflowId": "={{ $env.WF15_WORKFLOW_ID }}", "options": {} },
  "id": "c0ffee00-0002-4000-8000-000000000002",
  "name": "Call WF15: Followup Reply",
  "type": "n8n-nodes-base.executeWorkflow",
  "typeVersion": 1.2,
  "position": [1560, 840]
}
```

In `connections."Route Message".main`, append a new output array (index 5) BEFORE the
existing fallback array (which must remain LAST):

```json
[ { "node": "Call WF15: Followup Reply", "type": "main", "index": 0 } ]
```

So the `Route Message` `main` order becomes: new_lead, agent_claim, ai_conversation,
human_forward, pending, **agent_followup_reply**, End (Fallback).

- [ ] **Step 3: Validate JSON + verify output alignment**

```
python -c "import json; d=json.load(open(r'whatsapp-agent/workflows/WF1_inbound_router.json',encoding='utf-8')); sw=[n for n in d['nodes'] if n['name']=='Route Message'][0]; print('rules',len(sw['parameters']['rules']['values'])); print('outs',len(d['connections']['Route Message']['main']))"
```
Expected: `rules 6` and `outs 7` (6 named outputs + fallback). The fallback connection
(`End (Fallback)`) must be the last entry in `main`.

- [ ] **Step 4: Commit**

```
git add whatsapp-agent/workflows/WF1_inbound_router.json
git commit -m "feat(followup): WF1 routes agent non-TOMO messages to WF15"
```

---

## Task 7: WF16 — Weekly Report workflow

**Files:**
- Create: `whatsapp-agent/workflows/WF16_weekly_report.json`

- [ ] **Step 1: Write the workflow JSON**

Nodes: Cron (`0 8 * * 1` — Monday 08:00) → Pull metrics → Build report text → Send to gerente.

```json
{
  "name": "WF16 - Weekly Gerente Report (Evolution)",
  "nodes": [
    {
      "parameters": { "rule": { "interval": [ { "field": "cronExpression", "expression": "0 8 * * 1" } ] } },
      "id": "16161616-0001-4000-8000-000000000001",
      "name": "Monday 8am",
      "type": "n8n-nodes-base.scheduleTrigger",
      "typeVersion": 1.2,
      "position": [200, 300]
    },
    {
      "parameters": {
        "operation": "executeQuery",
        "query": "-- One JSON blob with everything the report needs.\nSELECT jsonb_build_object(\n  'pipeline', (SELECT jsonb_object_agg(stage, n) FROM (\n     SELECT COALESCE(stage,'new') AS stage, count(*) n FROM lead_status\n     WHERE stage NOT IN ('closed_won','closed_lost') GROUP BY 1) p),\n  'won_7d',  (SELECT count(*) FROM lead_status_history WHERE to_stage='closed_won'  AND changed_at >= NOW()-INTERVAL '7 days'),\n  'lost_7d', (SELECT count(*) FROM lead_status_history WHERE to_stage='closed_lost' AND changed_at >= NOW()-INTERVAL '7 days'),\n  'visits_7d',(SELECT count(*) FROM lead_status_history WHERE to_stage='visit_scheduled' AND changed_at >= NOW()-INTERVAL '7 days'),\n  'agents', (SELECT jsonb_agg(jsonb_build_object('name',agent_name,'pending',pending_count,'expired',expired_7d,'answered',answered_7d) ORDER BY pending_count DESC)\n             FROM weekly_followup_summary WHERE pending_count>0 OR expired_7d>0 OR answered_7d>0)\n) AS report;",
        "options": {}
      },
      "id": "16161616-0002-4000-8000-000000000002",
      "name": "Pull Weekly Metrics",
      "type": "n8n-nodes-base.postgres",
      "typeVersion": 2.5,
      "position": [440, 300],
      "credentials": { "postgres": { "id": "REPLACE_WITH_POSTGRES_CREDENTIAL_ID", "name": "Postgres - Supabase" } },
      "alwaysOutputData": true
    },
    {
      "parameters": {
        "jsCode": "// Format the weekly report text for the gerente.\nconst r = ($input.first().json.report) || {};\nconst pl = r.pipeline || {};\nconst stages = ['new','contacted','qualified','visit_scheduled','offer'];\nconst labels = { new:'Nuevos', contacted:'Contactados', qualified:'Calificados', visit_scheduled:'Con visita', offer:'Con oferta' };\nconst plLines = stages.filter(s=>pl[s]).map(s=>`  \\u2022 ${labels[s]}: ${pl[s]}`).join('\\n') || '  (sin leads activos)';\nconst agents = r.agents || [];\nconst agLines = agents.length\n  ? agents.map(a=>`  \\u2022 ${a.name}: ${a.answered} resp, ${a.pending} pend, ${a.expired} sin responder`).join('\\n')\n  : '  (todos al d\\u00eda)';\nconst text = [\n  `\\u{1F4CA} *Reporte semanal de seguimiento*`,\n  ``,\n  `*Pipeline activo:*`,\n  plLines,\n  ``,\n  `*Esta semana:* ${r.visits_7d||0} visitas agendadas, ${r.won_7d||0} cerradas, ${r.lost_7d||0} perdidas`,\n  ``,\n  `*Respuesta de asesores:*`,\n  agLines\n].join('\\n');\nreturn [{ json: { number: $env.MANAGER_PHONE, text } }];"
      },
      "id": "16161616-0003-4000-8000-000000000003",
      "name": "Build Report",
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [680, 300]
    },
    {
      "parameters": {
        "method": "POST",
        "url": "={{ $env.EVOLUTION_API_URL }}/message/sendText/{{ $env.EVOLUTION_INSTANCE }}",
        "sendHeaders": true,
        "headerParameters": { "parameters": [ { "name": "apikey", "value": "={{ $env.EVOLUTION_API_KEY }}" } ] },
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={\n  \"number\": \"{{ $json.number }}\",\n  \"text\": {{ JSON.stringify($json.text) }}\n}",
        "options": { "timeout": 15000 }
      },
      "id": "16161616-0004-4000-8000-000000000004",
      "name": "Send to Gerente",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [920, 300],
      "continueOnFail": true
    }
  ],
  "connections": {
    "Monday 8am": { "main": [[{ "node": "Pull Weekly Metrics", "type": "main", "index": 0 }]] },
    "Pull Weekly Metrics": { "main": [[{ "node": "Build Report", "type": "main", "index": 0 }]] },
    "Build Report": { "main": [[{ "node": "Send to Gerente", "type": "main", "index": 0 }]] }
  },
  "settings": { "executionOrder": "v1", "saveExecutionProgress": true, "saveManualExecutions": true }
}
```

- [ ] **Step 2: Validate JSON + test the metrics query on the dev branch**

```
python -c "import json; d=json.load(open(r'whatsapp-agent/workflows/WF16_weekly_report.json',encoding='utf-8')); print('nodes',len(d['nodes']))"
```
Expected: `nodes 4`. Then run the `Pull Weekly Metrics` query via `execute_sql` on the dev
branch — expect a single `report` JSON object with keys `pipeline, won_7d, lost_7d, visits_7d, agents`.

- [ ] **Step 3: Commit**

```
git add whatsapp-agent/workflows/WF16_weekly_report.json
git commit -m "feat(followup): WF16 weekly gerente report"
```

---

## Task 8: Deployment notes + env wiring (no activation)

**Files:**
- Modify: `whatsapp-agent/.env.example` (if present) — add `WF15_WORKFLOW_ID`.
- Create: `whatsapp-agent/workflows/PHASE10_DEPLOY.md` — activation checklist.

- [ ] **Step 1: Document the activation checklist**

Create `whatsapp-agent/workflows/PHASE10_DEPLOY.md`:

```markdown
# Phase 10 — Agent Follow-Up: Activation Checklist (post-go-live)

Migration 0012 is already merged (additive, safe). Workflows are imported but INACTIVE.
Do NOT activate until ALL of the below pass.

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
- [ ] Manually create one pending followup row for a test agent + lead.
- [ ] From the test agent's WhatsApp, reply in free text → confirm WF15 advanced the
      stage in `lead_status`, marked the followup answered, and the agent got a ✅ confirmation.
- [ ] Send a correction within 15 min → confirm it re-updates the stage.
- [ ] Manually execute WF14 once → confirm it DMs the agent the right stage-based question.
- [ ] Manually execute WF16 once → confirm the gerente receives the report.

## Activate
- [ ] Activate WF14, WF15, WF16. Watch first business-day run.
```

- [ ] **Step 2: Commit**

```
git add whatsapp-agent/workflows/PHASE10_DEPLOY.md whatsapp-agent/.env.example
git commit -m "docs(followup): Phase 10 activation checklist + WF15_WORKFLOW_ID env"
```

---

## Self-Review

**Spec coverage:**
- Stage-based cadence → Task 2 view + Task 4 sweeper. ✓
- Free-text + IA interpretation → Task 5 OpenRouter node. ✓
- Auto-advance + correction → Task 5 (`update_lead_stage` + 15-min correction window via `get_active_followup`). ✓
- Weekly WhatsApp report to gerente → Task 7. ✓
- All active leads, venta + renta → Task 2 view (`NOT IN closed_won/closed_lost`; operation best-effort from `properties_cache`). ✓
- Reply→lead disambiguation → Task 1 tracker + one-pending unique index + Task 3 `get_active_followup`. ✓
- WF1 router tweak (reuse `classify_sender`) → Task 6. ✓

**Type consistency:** `get_active_followup` returns `followup_id` (used in WF15 IF + writes);
`record_followup_sent`/`answer_followup` signatures match WF14/WF15 calls; `update_lead_stage`
signature matches its 0009 definition (conversation_id, stage, agent_id, note, next_action, next_action_at).
Column `agents.whatsapp_number` (not `whatsapp`) used throughout. No `conversations.listing_type` referenced.

**Placeholders:** Only intentional `REPLACE_WITH_POSTGRES_CREDENTIAL_ID` (matches existing
workflow convention, resolved at import per Task 8). No TODO/TBD.
```
