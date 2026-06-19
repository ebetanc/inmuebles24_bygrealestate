# Agent Management UI — Design

Date: 2026-06-19
Status: Approved

## Problem

Client's team rotates (hires/departures). The dashboard's `Calendario` page lets a
manager assign **existing** agents to shifts, and the `Agentes` page is **read-only**.
There is no UI to add a new agent, deactivate a departed one, or edit agent details.
Today those changes require manual SQL against the `agents` and `property_agent_alias`
tables. We need self-serve agent management in the dashboard.

## Decisions (locked)

- **Removal = soft deactivate** (`is_available = false`). No hard delete — avoids FK
  breakage in `agent_schedule`, `conversations`, `lead_followups`, claims. Reversible.
- **Alias management included** in the same form. New agents need a
  `property_agent_alias` row, else owner-first routing never matches their listings.
- **Access control: open**. Anyone with the dashboard password manages agents (same
  model as the calendar today). No auth rework.

## Architecture

Next.js App Router + Supabase. Writes use the existing server-side service-role client
(`createSupabaseServer`), which bypasses RLS — direct table writes, no new RPC needed.
No DB migration required: the `agents` table already has every column
(`agent_id`, `name`, `whatsapp_number`, `is_available`, `on_shift`, `easybroker_email`,
`shift_slot`), and `property_agent_alias` already exists.

### Data layer — `dashboard/src/lib/queries.ts`
- `getAllAgents()` — all agents (no `is_available` filter); order available-first then
  name. Existing `getAgents()` stays as the active-only query used by calendar/routing.
- `getAgentAliases()` → `Record<agent_id, string[]>` from `property_agent_alias`.

### Server actions — `dashboard/src/app/(dashboard)/agentes/actions.ts` (new)
- `createAgent(input)` — insert into `agents`. `agent_id` auto-derived from name (slug,
  accent-stripped, `agent_<slug>`), editable on create, must be unique. Then write aliases.
- `updateAgent(agent_id, input)` — update name / whatsapp / email / shift_slot.
  `agent_id` immutable.
- `setAgentAvailability(agent_id, isAvailable)` — soft deactivate / reactivate.
- `replaceAliases(agent_id, tags[])` — delete the agent's existing alias rows, insert the
  normalized (lowercase + trim + dedupe) set. Tag already owned by another agent is
  reassigned (upsert) and reported back.

Server-side validation: name + whatsapp required; whatsapp normalized to digits and
checked against E.164 shape `52XXXXXXXXXX`; `whatsapp_number` UNIQUE; `agent_id` UNIQUE
on create.

### UI
- `agentes/page.tsx` — fetch all agents + aliases + per-agent stats, render the new
  client component.
- `agent-manager.tsx` (new) — card grid (keeps the live stats display), inactive agents
  dimmed, "Nuevo agente" button. Each card has Editar and Desactivar / Reactivar.
- `agent-form-modal.tsx` (new) — brutalist modal. Fields: nombre, WhatsApp (`52…`),
  email EasyBroker (optional), turno preferido (manana / tarde / ninguno), aliases de
  propiedad (tag chips). Persist via `useTransition` + toast + `router.refresh()`,
  mirroring the calendar editor pattern.
- `sidebar.tsx` — no change needed; `/agentes` already linked.

## Edge cases

- **Alias collision** — `property_agent_alias.tag_normalized` is the global PK (one tag →
  one agent). Reassigning a tag upserts and the modal warns "tag X reasignado".
- **Deactivated agents** — drop out of the calendar dropdown and routing (both filter
  `is_available = true`) but retain all history.
- **shift_slot** — optional; column added in migration 0005.

## Out of scope

- Hard delete of agents.
- Per-user accounts / manager-only role gating.
- Editing the routing tier logic itself.
