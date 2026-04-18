# Architecture

## The problem

When a lead messages the agency via WhatsApp asking about a property, we need to:

1. Identify which property they're asking about.
2. Offer the lead to the agent rotation pool (plus the property's assigned agent, if any).
3. Whichever agent responds first gets the lead — atomically, no double-assignments.
4. Hand off to an AI that answers factual questions about the property using EasyBroker data.
5. Escalate to the human agent when the conversation needs a person (visits, negotiation, complex questions).

## The shape of the solution

Five n8n workflows communicating through a shared Supabase Postgres database. Twilio is the WhatsApp gateway.

```
┌──────────────────┐       ┌──────────────────┐
│  Twilio WhatsApp │       │    EasyBroker    │
│   (inbound +     │       │    REST API      │
│    outbound)     │       │                  │
└────────┬─────────┘       └────────▲─────────┘
         │                          │
         │ webhooks                 │ HTTP
         │                          │
    ┌────▼──────────────────────────┴────┐
    │  n8n — five workflows              │
    │                                    │
    │  WF1  inbound router               │
    │  WF2  lead intake                  │
    │  WF3  auction (a/b/c)              │
    │  WF4  AI conversation              │
    │  WF5  human handoff                │
    └────────────────┬───────────────────┘
                     │
           ┌─────────▼─────────┐
           │ Supabase Postgres │
           │  (state + audit)  │
           └───────────────────┘
```

## Why five workflows, not one

Each workflow has one responsibility and one trigger type. Splitting them:

- Makes each one testable in isolation (you can invoke WF3a manually without leads or Twilio).
- Prevents a failure in one stage from breaking the others.
- Keeps race-critical logic (the auction claim in WF3b) small and reviewable.

## The race condition and how it's solved

The "first-reply-wins" requirement is a distributed race. Three agents all see the notification; any two could reply within milliseconds of each other.

**This is not solved in n8n logic.** It's solved in a single SQL statement:

```sql
UPDATE auctions
SET status = 'claimed', winner_agent_id = $agent, claimed_at = NOW()
WHERE short_code = $code
  AND status     = 'open'
  AND expires_at > NOW()
RETURNING *;
```

The `WHERE status = 'open'` inside the UPDATE is evaluated atomically with the write. Exactly one concurrent transaction finds the row as `'open'` and wins; every other transaction sees 0 rows affected.

You can prove this yourself — see `docs/wf3-testing.md` for the two-psql-session race test.

## State management

Postgres is the single source of truth for:

- **agents** — the pool, with on_shift / is_available flags
- **conversations** — one per lead, carries the `mode` flag (`pending_assignment | ai | human`)
- **auctions** — one per lead-assignment event, carries `status` for the atomic claim
- **messages** — full audit log, also enables AI memory reconstruction
- **properties_cache** — avoids hammering EasyBroker's 20 req/sec limit

n8n workflows are **stateless**. Every execution reads state from Postgres, writes back to Postgres, and returns. Don't rely on n8n's built-in memory nodes for anything production — conversations span days, executions don't.

## Data flow for a typical lead

1. Lead messages the Twilio number: *"Hola, me interesa EB-12345"*
2. Twilio webhook → **WF1** classifies sender as new lead, routes to WF2.
3. **WF2** extracts `EB-12345`, fetches property from EasyBroker (or cache), creates `conversations` row with `mode='pending_assignment'`, calls WF3a.
4. **WF3a** creates `auctions` row, fans WhatsApp to all on-shift agents with a claim code `TOMO-AB12`.
5. First agent replies `TOMO-AB12`. Twilio webhook → WF1 recognizes agent + claim pattern → calls WF3b.
6. **WF3b** runs the atomic claim. Winner gets confirmation, lead gets a greeting, other agents are told it's taken. Conversation flips to `mode='ai'`.
7. Lead asks *"¿tiene alberca?"*. WF1 → WF4 (because mode=ai).
8. **WF4** reads the cached property, calls the LLM, replies with the answer.
9. Lead asks *"¿puedo verlo mañana?"*. WF4's guardrails trigger a handoff via WF5.
10. **WF5** shares the agent's contact with the lead, DMs a conversation summary to the agent, flips mode to `human`. WF1 now passes messages directly between lead and agent.

## What's built vs. what's next

**Built (this repo):**
- Migrations for all five tables
- WF3a / WF3b / WF3c (the auction subsystem) — the hardest part

**Not yet built:**
- WF1 (inbound router) — see `docs/wf1-spec.md` for the spec
- WF2 (lead intake)
- WF4 (AI conversation)
- WF5 (human handoff)
- WF6 (EasyBroker sync, if needed)

WF3 is built first because it's the only race-critical piece and building anything on top of a shaky auction is risky. With WF3 stable, WF1 and WF2 are straightforward routing and intake.
