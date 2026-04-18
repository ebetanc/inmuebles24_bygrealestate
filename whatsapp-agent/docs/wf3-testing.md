# WF3 Testing Guide

How to verify the auction subsystem works end-to-end, including proving the race-condition guarantee.

## Prerequisites

- Migrations applied (`make migrate`)
- Three test agents in the `agents` table (seed data provides this)
- Three workflows imported into n8n: WF3a, WF3b, WF3c
- Credentials configured: `Supabase Postgres`, `Twilio`
- Env vars set: `TWILIO_WHATSAPP_FROM`, `MANAGER_WHATSAPP_TO`

## Test 1 — Manual WF3a trigger

Open `WF3a - Auction Launcher` in n8n. Click the trigger node. Paste this test input:

```json
{
  "conversation_id": "00000000-0000-0000-0000-000000000001",
  "lead_phone": "+5215512345678",
  "lead_name": "María García",
  "property_id": "EB-12345",
  "property_title": "Depto. Bosques de las Lomas",
  "property_price": "$1,000,883 MXN",
  "assigned_agent_id": "agent_yolanda"
}
```

Click "Execute Workflow". You should see:

- Three Twilio calls fire (one per seeded agent).
- An `auctions` row created with `status='open'`.
- Three `messages` rows with `direction='outbound'`, `sender_type='system'`.

Verify with:

```bash
make check
```

Note the `short_code` — you'll need it for test 2. Example output:

```
 short_code | status | notified_agents
------------+--------+------------------------------
 AB12       | open   | {agent_yolanda,agent_marusa,agent_gina}
```

## Test 2 — Manual WF3b claim

Open `WF3b - Claim Handler`. Paste this test input using the `short_code` from test 1:

```json
{
  "agent_id": "agent_yolanda",
  "agent_name": "Yolanda",
  "agent_phone": "+5215500000001",
  "short_code": "AB12",
  "raw_message": "TOMO-AB12",
  "twilio_sid": "SMtest1"
}
```

Execute. You should see:

- `auctions.status` flips to `claimed`, `winner_agent_id='agent_yolanda'`.
- `conversations.mode` flips to `ai`, `assigned_agent_id='agent_yolanda'`.
- Three Twilio sends: winner confirmation, lead greeting, two "already taken" messages.

## Test 3 — Losing the race

Using the same `short_code` from test 1 (already claimed in test 2), run WF3b again with a different agent:

```json
{
  "agent_id": "agent_marusa",
  "agent_name": "Marusa",
  "agent_phone": "+5215500000002",
  "short_code": "AB12",
  "raw_message": "TOMO-AB12",
  "twilio_sid": "SMtest2"
}
```

Expected: the atomic claim returns 0 rows, the "Too Late" branch fires, Marusa gets the "⚠️ No pude asignarte el lead AB12" message. No state changes. `winner_agent_id` remains `agent_yolanda`.

## Test 4 — Expiry

Create an auction that expires in a few seconds by running this SQL directly:

```sql
-- Create an already-expired open auction for the test conversation.
INSERT INTO auctions (conversation_id, property_id, short_code, expires_at)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'EB-99999',
  'EXPR',
  NOW() - INTERVAL '1 minute'
);
```

Wait for the next minute boundary. WF3c (must be active) fires. Expected:

- Row flips to `status='expired'`.
- Manager receives the `⚠️ Lead sin asignar` WhatsApp.

If nothing happens, check WF3c is activated and `MANAGER_WHATSAPP_TO` is set correctly.

## Test 5 — Proving race-safety (the important one)

You can't easily race two n8n executions by hand, but you can prove the DB guarantee directly. This is what actually matters — n8n is just a caller; Postgres is what provides correctness.

First, create a fresh auction:

```sql
INSERT INTO auctions (conversation_id, property_id, short_code, expires_at)
VALUES ('00000000-0000-0000-0000-000000000001', 'EB-RACE', 'RACE', NOW() + INTERVAL '5 minutes');
```

Open **two** psql shells (`make psql` in each). In both, paste — but do NOT press Enter yet:

**Shell 1:**
```sql
UPDATE auctions
SET status='claimed', winner_agent_id='agent_yolanda', claimed_at=NOW()
WHERE short_code='RACE' AND status='open' AND expires_at > NOW()
RETURNING *;
```

**Shell 2:**
```sql
UPDATE auctions
SET status='claimed', winner_agent_id='agent_marusa', claimed_at=NOW()
WHERE short_code='RACE' AND status='open' AND expires_at > NOW()
RETURNING *;
```

Press Enter in shell 1 first, then shell 2 as fast as you can.

**Expected:**
- Shell 1 returns one row. Yolanda wins.
- Shell 2 returns **zero rows**. The `WHERE status='open'` failed because shell 1's update already committed.

That's the guarantee. It holds regardless of how fast or concurrent the writers are. Postgres' MVCC ensures the `status='open'` predicate is evaluated inside the same atomic write.

If you want to get more aggressive, use a shell loop:

```bash
# Terminal 1
for i in 1 2 3 4 5; do
  psql "$DATABASE_URL" -c "UPDATE auctions SET status='claimed', winner_agent_id='agent_yolanda' WHERE short_code='R$i' AND status='open' RETURNING *;" &
done

# Terminal 2 (same time)
for i in 1 2 3 4 5; do
  psql "$DATABASE_URL" -c "UPDATE auctions SET status='claimed', winner_agent_id='agent_marusa' WHERE short_code='R$i' AND status='open' RETURNING *;" &
done
```

Each `R1..R5` row ends up with exactly one winner. No dual-wins, no lost writes.

## Resetting between tests

```sql
-- Clear auctions and reset the test conversation.
DELETE FROM messages;
DELETE FROM auctions;
UPDATE conversations
SET mode='pending_assignment', assigned_agent_id=NULL
WHERE conversation_id='00000000-0000-0000-0000-000000000001';
```

Or nuke everything and re-seed:

```bash
make rollback
make setup
```

## Common gotchas

**"Invalid 'To' phone number"** — missing `whatsapp:` prefix somewhere. Every phone reaching a Twilio node must be `whatsapp:+E164`.

**"permission denied for table X"** — you're connecting as the `anon` or `authenticated` Supabase role. n8n should use the connection string from Project Settings → Database (which connects as `postgres`, bypassing RLS).

**"insert or update on table 'auctions' violates foreign key constraint"** — the `conversations` row for this `conversation_id` doesn't exist. The seed migration creates one with UUID `000…001` for testing; any other UUID needs a matching row first.

**Twilio sandbox messages aren't delivered** — each recipient needs to have sent the `join <two-words>` code to the Twilio sandbox number first. Check Twilio Console → Messaging → Try it Out → WhatsApp for the code.

**`notified_agents` is empty** — check `SELECT * FROM agents WHERE on_shift=true AND is_available=true;`. If empty, flip the flags on your seed rows.
