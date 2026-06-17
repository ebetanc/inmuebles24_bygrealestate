# Owner-First Tiered Lead Routing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the competitive TOMO fan-out auction with property-owner-first tiered routing: the asesor who owns a property gets the lead first (2 min), then the guard auction (5 min), then the manager.

**Architecture:** A lead's property tag in EasyBroker resolves to a single owner agent. n8n notifies that owner with a claim code (reuse WF3b atomic claim). On no-claim, escalate tier-by-tier driven by a sweeper. Per-property agent comes from EasyBroker `tags` (validated linchpin) normalized through a Supabase alias table.

**Tech Stack:** Supabase Postgres (migrations + RPC), n8n workflows (Postgres + HTTP nodes, Evolution API), Python scraper (Playwright), EasyBroker REST API.

**Routing model (locked):**
1. Lead arrives (any source) → resolve **owner agent** from the property.
2. Bot WhatsApps owner with a unique claim code → owner has **2 min** (NIVEL owner).
3. No claim → **NIVEL guard** = TOMO auction among on-shift guard agents (fan-out, first-reply-wins).
4. No claim in **5 min** total → **NIVEL manager**.
5. Owner unresolvable (no tag / lookup fails / no WhatsApp) → **directo a manager**.
- Day = owner routing. Night keeps current AI bot + night_queue; 8:05 AM batch enters routing.

---

## Current state (verified 2026-06-17)

- DB helper fns exist: `generate_tomo_code()`, `get_on_shift_agents()`, `mark_assigned(uuid,text,text)`, `update_lead_stage(...)`, `find_returning_lead`, `is_daytime`, `current_shift`.
- `conversations` has: assigned_agent_id, mode (pending_assignment/ai/human/night_queued), claimed_via (tomo_auction/night_queue/manual/escalation), assignment_method, assigned_at, first_response_at.
- `auctions`: short_code, status (open/claimed/expired/cancelled), winner_agent_id, notified_agents[], expires_at.
- Roster (8): Carol, Gina (easybroker_email NULL), Lupita, Marusa (agent_manager_2, mgr), Moni, Paty, Sandy (agent_manager, mgr), Yol. **Tania tagged in EB but NOT in agents.**
- WF10 intake → on day route → `Create Day Conversation` → `Prepare Auction Data` (`assigned_agent_id:null`) → `Call WF3a` (fan-out to all on-shift).
- EasyBroker key (BYG): `uswezovjw0fr4v4cdbw1737f93hp4p`, base `https://api.easybroker.com/v1`, header `X-Authorization`. **Not yet set in n8n.**
- Linchpin validated: `GET /properties/EB-VK1013` → `tags:["Sandra"]`. Tag value ≠ system name → needs alias layer.

## File structure

- Create: `whatsapp-agent/migrations/0011_owner_routing.sql` — alias table, resolver fn, conversations tier columns.
- Create: `whatsapp-agent/workflows/WF12_owner_resolver.json` — n8n subworkflow: property → EB tags → owner agent.
- Modify: `whatsapp-agent/workflows/WF10_scraper_intake.json` — day route calls resolver, branches owner vs manager (Phase 4).
- Create: `whatsapp-agent/workflows/WF13_directed_notify.json` — notify ONE owner with claim code (Phase 4).
- Modify: `whatsapp-agent/workflows/WF3c_expiry_sweeper.json` — tiered escalation owner→guard→manager (Phase 5).
- Modify: scraper `src/inmobiliaria24/` — capture EB code + mark Contactado (Phase 3).

---

## Phase 1 — Database (build now)

### Task 1: Migration 0011 — alias table, resolver fn, tier columns

**Files:**
- Create: `whatsapp-agent/migrations/0011_owner_routing.sql`
- Apply: Supabase project `wkaeutndwawkdhswisqe`

- [ ] **Step 1: Write the migration**

```sql
-- 0011_owner_routing.sql -- Property-owner-first tiered lead routing
-- Adds: property_agent_alias (tag->agent), resolver fn, conversations tier cols.
-- Idempotent: safe to re-run.

-- 1. alias table: EasyBroker tag (lowercased, trimmed) -> agent_id
CREATE TABLE IF NOT EXISTS property_agent_alias (
  tag_normalized TEXT PRIMARY KEY,
  agent_id       TEXT NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE property_agent_alias IS
  'Maps EasyBroker property tag (lowercased, trimmed) -> agent_id for owner-first routing.';
ALTER TABLE property_agent_alias ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE tablename='property_agent_alias' AND policyname='alias_read') THEN
    CREATE POLICY alias_read ON property_agent_alias FOR SELECT USING (true);
  END IF;
END $$;

-- 2. seed known aliases (tag spelling variants -> canonical agent)
INSERT INTO property_agent_alias (tag_normalized, agent_id) VALUES
  ('carol','agent_carol'),
  ('gina','agent_gina'),
  ('lupita','agent_lupita'),
  ('glozoya','agent_lupita'),
  ('marusa','agent_manager_2'),
  ('moni','agent_moni'),
  ('monica','agent_moni'),
  ('mónica','agent_moni'),
  ('paty','agent_paty'),
  ('patricia','agent_paty'),
  ('yol','agent_yol'),
  ('yolanda','agent_yol'),
  ('sandy','agent_manager'),
  ('sandra','agent_manager')
ON CONFLICT (tag_normalized) DO NOTHING;

-- 3. resolver: first agent matching any property tag, else NULL
CREATE OR REPLACE FUNCTION resolve_agent_from_tags(p_tags text[])
RETURNS text AS $$
  SELECT a.agent_id
  FROM unnest(p_tags) WITH ORDINALITY AS t(tag, ord)
  JOIN property_agent_alias al ON al.tag_normalized = lower(btrim(t.tag))
  JOIN agents a ON a.agent_id = al.agent_id
  ORDER BY t.ord
  LIMIT 1;
$$ LANGUAGE sql STABLE;
COMMENT ON FUNCTION resolve_agent_from_tags IS
  'Returns first agent_id matching any property tag via property_agent_alias, else NULL.';

-- 4. conversations tier columns
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='conversations' AND column_name='owner_agent_id') THEN
    ALTER TABLE conversations ADD COLUMN owner_agent_id TEXT REFERENCES agents(agent_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='conversations' AND column_name='routing_tier') THEN
    ALTER TABLE conversations ADD COLUMN routing_tier TEXT
      CHECK (routing_tier IS NULL OR routing_tier IN ('owner','guard','manager'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='conversations' AND column_name='tier_notified_at') THEN
    ALTER TABLE conversations ADD COLUMN tier_notified_at TIMESTAMPTZ;
  END IF;
END $$;

-- 5. allow claimed_via='owner'
DO $$ BEGIN
  ALTER TABLE conversations DROP CONSTRAINT IF EXISTS conversations_claimed_via_check;
  ALTER TABLE conversations ADD CONSTRAINT conversations_claimed_via_check
    CHECK (claimed_via IS NULL OR
           claimed_via IN ('tomo_auction','night_queue','manual','escalation','owner'));
END $$;
```

- [ ] **Step 2: Apply migration** (via Supabase MCP `apply_migration` name `owner_routing`, or `psql` against pooler).

- [ ] **Step 3: Verify alias resolver** — Expected: `agent_manager` (Sandy).

```sql
SELECT resolve_agent_from_tags(ARRAY['Sandra']) AS owner;   -- agent_manager
SELECT resolve_agent_from_tags(ARRAY['Mónica']) AS owner;   -- agent_moni
SELECT resolve_agent_from_tags(ARRAY['Nadie'])  AS owner;   -- NULL
```

- [ ] **Step 4: Verify tier columns exist**

```sql
SELECT column_name FROM information_schema.columns
WHERE table_name='conversations'
  AND column_name IN ('owner_agent_id','routing_tier','tier_notified_at');
-- Expected: 3 rows.
```

- [ ] **Step 5: Commit**

```bash
git add whatsapp-agent/migrations/0011_owner_routing.sql
git commit -m "feat(db): owner-first routing — alias table, resolver fn, tier columns"
```

### Task 2: Roster reconciliation (DATA-PENDING — needs BYG input)

Not blocking Phase 1-2. Track as follow-ups:
- [ ] Add agent **Tania** to `agents` (needs whatsapp_number from BYG), then `INSERT INTO property_agent_alias VALUES ('tania','agent_tania')`.
- [ ] Fill **Gina** `easybroker_email` (needs value from BYG).
- [ ] Confirm tag→agent aliases with BYG (esp. "Sandra"→Sandy is a MANAGER; real owner tags should be non-manager).

---

## Phase 2 — Resolver workflow + EB key in n8n (build now)

### Task 3: WF12 Owner Resolver subworkflow

**Files:**
- Create: `whatsapp-agent/workflows/WF12_owner_resolver.json`

Input (executeWorkflowTrigger passthrough): `{ property_public_id: 'EB-VK1013', conversation_id?: uuid }`.
Output: `{ owner_agent_id, owner_name, owner_number, resolved: bool }`.

- [ ] **Step 1: Build the workflow JSON** — nodes: trigger → HTTP GET `{{$env.EASYBROKER_BASE}}/properties/{{public_id}}` (header `X-Authorization: {{$env.EASYBROKER_API_KEY}}`, `continueOnFail`) → Code (extract `tags` array) → Postgres (`SELECT resolve_agent_from_tags($1::text[]) ...` joined to `agents` for name+number) → Code (shape output, `resolved = owner_agent_id != null`). (Full JSON written to the file.)

- [ ] **Step 2: Set n8n env** on VPS (`/root/.env` + compose `environment:`), then `docker compose up -d n8n`:

```
EASYBROKER_API_KEY=uswezovjw0fr4v4cdbw1737f93hp4p
EASYBROKER_BASE=https://api.easybroker.com/v1
```

- [ ] **Step 3: Import + activate** WF12 via n8n API (POST /api/v1/workflows with {name,nodes,connections,settings}; assign Postgres cred `dEHKygi1neTNvPtH`). Record the assigned WF12 id.

- [ ] **Step 4: Test resolve** — execute WF12 with `{property_public_id:'EB-VK1013'}`. Expected output `owner_agent_id: 'agent_manager'`, `resolved: true`.

- [ ] **Step 5: Commit**

```bash
git add whatsapp-agent/workflows/WF12_owner_resolver.json
git commit -m "feat(n8n): WF12 owner resolver — EB tags to owner agent"
```

**Deploy note:** Steps 2-3 require VPS access (`ssh root@69.62.108.2`, reachable via Pi+sshpass over Tailscale; n8n API key at `/tmp/n8n_key` on Pi). If Tailscale needs re-auth, hand these two steps to the user.

---

## Phase 3 — Scraper (later; depends on BYG tagging + scraper run)

- [ ] Capture EB code (`Cód. del anunciante: EB-XXXX`) from property page → cache `listing_id→EB` in state.db, send `property_public_id` in the webhook payload. (Resolves the listing_id→EB mapping open question.)
- [ ] Mark "Contactado" in inmuebles24 on extract (Playwright write via the `Pendiente ∨ → Contactado` dropdown + screenshot-on-error).

## Phase 4 — Directed routing (later; depends on WhatsApp/Evolution connected)

- [ ] WF10: after `Create Day Conversation`, call WF12. If `resolved` → set `owner_agent_id`, `routing_tier='owner'`, `tier_notified_at=NOW()` and call **WF13** (notify owner only). If not → set `routing_tier='manager'`, notify manager.
- [ ] WF13 directed-notify: create auction row scoped to owner, send ONE claim-code message (reuse WF3b atomic claim; claimed_via='owner').

## Phase 5 — Tiered escalation (later)

- [ ] WF3c sweeper: owner tier + `tier_notified_at` > 2 min & unclaimed → escalate to guard auction (call WF3a among on-shift). Guard tier > 5 min total & unclaimed → escalate to manager. Update `routing_tier` + `tier_notified_at` each hop.

---

## Dependencies on BYG (rollout)
- Tag ALL properties in EasyBroker with the asesor (and new ones on publish). Untagged → lead falls to manager.
- Provide Tania's whatsapp_number + Gina's easybroker_email.

## Self-review notes
- Resolver avoids the `unaccent` extension (uses `lower(btrim())` + seeded accent variants e.g. monica/mónica).
- `resolve_agent_from_tags` returns NULL on no match → WF12 sets `resolved:false` → manager route (covers "owner unresolvable").
- Phases 1-2 are testable with EB-VK1013/"Sandra" without WhatsApp cooldown or full BYG tagging.
