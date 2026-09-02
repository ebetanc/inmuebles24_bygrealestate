# Plan — Owner/Manager roles, Team Calendar, Auctioned-lead visibility fix

Date: 2026-06-20. Branch base: `feat/twilio-whatsapp` (or new `feat/agents-roles-calendar`).

Decisions (locked with user):
- **Access model:** add `role` column (owner/manager/asesor); Marusa = owner ("Dueña"). Dashboard stays single shared password — no per-user auth.
- **Calendar:** full date calendar (month/week) with an events table — vacations, one-off shifts, coverage.
- **Lead bug:** diagnose + fix now (highest priority — dashboard currently blind).

Evidence captured 2026-06-20:
- n8n and dashboard share ONE Supabase (`Postgres - Supabase`, host `2a05:d012:7a:e02::`).
- `conversations=0, auctions=0, lead_status=0`. `agents=9`. `messages=19` — **all 19 have `conversation_id = NULL`**, newest `TOMO-2606` claim at 16:55 today (after the 8:46am test-cleanup).
- Dashboard leads list = `getRecentConversations()` → `select * from conversations` → empty → nothing renders. Root symptom confirmed.

---

## PHASE 0 — PRIORITY: Auctioned-lead visibility fix (bug)

Goal: a scraper lead that gets auctioned + claimed persists `conversations` + `auctions` rows AND shows on the dashboard.

Steps:
1. **Pull n8n execution logs** for the live run that produced `TOMO-2606` (today ~16:55) and trace: WF10 scraper intake → owner-routing (WF12/WF13) or guard auction (WF3a) → claim handler (WF3b). Identify the node where the `conversations` INSERT and/or `auctions` INSERT is lost or errors (several nodes are `continueOnFail`).
2. **Reconcile deployed vs repo workflows.** Deployed are `live_*.json`; repo `WFxx_*.json` may be out of sync. Diff the live conversation/auction-creating nodes.
3. **Confirm hypotheses (likely one of):**
   - Day path never creates a `conversations` row (only night path has `Create Night Conversation`); auction/claim then run without a conversation_id.
   - Auction INSERT silently fails (continueOnFail) → claim logs `messages` with `conversation_id = NULL`.
   - Claim/message-log node fires before/without the conversation_id.
4. **Fix** the failing INSERT(s) so: conversation row created on every intake (day + night), auction row written, messages carry a non-null `conversation_id`, claim sets `assigned_agent_id`/`assigned_at`/`claimed_via` (matches prior WF3b fixes).
5. **Backfill check:** decide whether to reconstruct conversations for the 19 orphan messages or leave as historical noise (likely leave — they're team chatter, not leads).
6. **Verify dashboard embed:** `getRecentConversations()` uses `agents(name)`. With both `assigned_agent_id` and `owner_agent_id` FKs to `agents`, confirm the PostgREST embed is unambiguous (disambiguate to `agents!assigned_agent_id(name)` if it errors).
7. **Re-test E2E:** real scraper lead → auction → claim → confirm row visible in dashboard `/leads` and `/subastas`.

Exit: one fresh auctioned lead visible end-to-end in the UI.

---

## PHASE 1 — Owner/Manager role on agents

DB migration (`whatsapp-agent/migrations/00xx_agent_roles.sql`):
```sql
ALTER TABLE agents
  ADD COLUMN role TEXT NOT NULL DEFAULT 'asesor'
  CHECK (role IN ('owner','manager','asesor'));

UPDATE agents SET role = 'owner'   WHERE agent_id = 'agent_manager_2'; -- Marusa
UPDATE agents SET role = 'manager' WHERE agent_id = 'agent_manager';   -- Sandy
```

UI (`dashboard/src/app/(dashboard)/agentes/`):
- `types.ts`: add `role` to Agent.
- `agent-form-modal.tsx`: role select (owner/manager/asesor).
- `agent-manager.tsx`: role badge per card — "Dueña" (owner), "Manager", "Asesor".
- `actions.ts`: persist `role` in create/update; guard so only one `owner` (optional: demote prior owner on reassignment).
- `queries.ts`: include `role` in `getAllAgents()`.

WhatsApp editing already works (canonical `521XXXXXXXXXX`) — no change, just confirm surfaced clearly.

Exit: Marusa shows "Dueña"; roles editable; saved in DB.

---

## PHASE 2 — Team calendar (full date)

DB migration (`00xx_agent_schedule.sql`):
```sql
CREATE TABLE agent_schedule_event (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id    TEXT NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
  event_type  TEXT NOT NULL CHECK (event_type IN ('shift','vacation','coverage','off')),
  start_at    DATE NOT NULL,
  end_at      DATE NOT NULL,
  slot        TEXT CHECK (slot IS NULL OR slot IN ('morning','afternoon','full')),
  note        TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ON agent_schedule_event (start_at, end_at);
```

UI new route `dashboard/src/app/(dashboard)/calendario/`:
- Month view (lightweight — custom grid or small calendar lib).
- Click a day → modal: pick agent + event_type + slot + note.
- Color by agent/role; show who covers each day.
- Server actions: create/update/delete events; query by month range.

Keep `agents.on_shift` / `shift_slot` for live routing; calendar is the planning layer. (Optional later: derive `on_shift` from today's calendar events.)

Exit: month calendar, dated events (vacations/shifts/coverage) saved + always current.

---

## Sequencing & verification
1. Phase 0 (bug) first — independently shippable.
2. Phase 1 (roles) — small, ship next.
3. Phase 2 (calendar) — largest, ship last.

Each phase: migration applied to Supabase, dashboard built/typecheck clean, manual verify in UI, then commit. Update memory (`whatsapp-cloud-api.md`, agent-management-ui.md) after Phase 0 fix.
```
