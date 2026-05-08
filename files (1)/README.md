# WF3 — Auction Subsystem (Twilio edition)

This package implements the **first-reply-wins** auction. It's three n8n workflows plus one SQL migration.

## What's in here

| File | What it does |
|------|---|
| `01_schema.sql` | Creates `agents`, `conversations`, `auctions`, `messages`, `properties_cache` tables. Safe to re-run. |
| `WF3a_auction_launcher.json` | Called by WF2 when a new lead arrives. Creates auction row, fans out WhatsApp to the agent pool. |
| `WF3b_claim_handler.json` | Called by WF1 when an agent replies `TOMO-XXXX`. Atomic claim; notifies winner, lead, and losers. |
| `WF3c_expiry_sweeper.json` | Scheduled every minute. Expires unclaimed auctions and pings a manager. |

## Install order

1. **Run the SQL migration** against your application Postgres:
   ```bash
   psql "$DATABASE_URL" -f 01_schema.sql
   ```

2. **Create two n8n credentials** in the UI:
   - **Postgres - App State** → points at the DB where you ran the schema
   - **Twilio** → Account SID + Auth Token

3. **Set these environment variables** on your n8n container:
   ```
   TWILIO_WHATSAPP_FROM=whatsapp:+14155238886     # your Twilio WA sender, incl. prefix
   MANAGER_WHATSAPP_TO=whatsapp:+5215500000099    # manager's number for escalations
   ```
   (If sandbox, `TWILIO_WHATSAPP_FROM` is the sandbox number Twilio gave you.)

4. **Import the three workflow JSON files** (Workflows → Import from File).

5. **Fix the credential references.** Every node that talks to Postgres or Twilio references credentials by ID, and import preserves my placeholder IDs. For each imported workflow, open each Postgres and Twilio node, select your actual credential from the dropdown, save.

6. **Seed real agents.** The schema includes three test rows. Replace them with real agent_ids, names, and WhatsApp numbers. **Store numbers in E.164 WITHOUT the `whatsapp:` prefix** (e.g. `+5215598765432`) — the workflows add the prefix when sending.

7. **Activate** WF3b and WF3c. WF3a doesn't need to be activated — it's only called by WF2 via Execute Workflow, not triggered on its own.

## Testing WF3a manually (before WF2 exists)

In n8n, open `WF3a - Auction Launcher`, click the "When Called by Another Workflow" trigger, and paste this as the test input:

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

Before running, insert the conversation row manually so the FK constraint is satisfied:
```sql
INSERT INTO conversations (conversation_id, lead_phone, lead_name, current_property)
VALUES ('00000000-0000-0000-0000-000000000001', '+5215512345678', 'María García', 'EB-12345')
ON CONFLICT (lead_phone) DO NOTHING;
```

Run it. You should see three Twilio calls fire (one per seeded agent) and an `auctions` row appear:
```sql
SELECT auction_id, short_code, status, notified_agents FROM auctions ORDER BY created_at DESC LIMIT 1;
```

Note the `short_code` (e.g. `AB12`) — you'll use it in the next test.

## Testing WF3b manually

Open `WF3b - Claim Handler`, paste this input using the short_code from above:

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

Run it. The `auctions` row should flip to `status='claimed'`, `winner_agent_id='agent_yolanda'`. Three Twilio sends fire: winner confirmation to Yolanda, greeting to the lead, "already taken" to Marusa and Gina.

## **Proving first-reply-wins actually works** (the important test)

You can't easily race two n8n executions by hand, but you can prove the DB-level race safety directly. Open two psql sessions. In **both** sessions, paste this but don't press Enter:

```sql
UPDATE auctions
SET status='claimed', winner_agent_id='agent_yolanda', claimed_at=NOW()
WHERE short_code='AB12' AND status='open'
RETURNING *;
```

In session 2, change `agent_yolanda` to `agent_marusa`.

Press Enter in session 1 first, then session 2 immediately. Session 1 returns one row, session 2 returns **zero rows**. That's the guarantee. It holds under any amount of concurrent traffic because the `WHERE status='open'` clause is evaluated inside the same atomic operation as the UPDATE — Postgres ensures only one transaction sees `open` and wins.

## Things to watch for

**"Invalid 'To' phone number"** — you forgot the `whatsapp:` prefix somewhere. Check every `to_phone` / `from` field reaching the Twilio node; it must be `whatsapp:+E164`, never plain `+E164`.

**"insert or update on table violates foreign key constraint"** — the conversation doesn't exist yet. WF2 is supposed to create it before calling WF3a. In manual tests you have to insert it yourself.

**Twilio message not delivered in sandbox** — the recipient hasn't sent the join code to the sandbox number yet. Each agent and each test lead needs to send that one-time `join <two-words>` message to activate.

**`notified_agents` is empty on the auction row** — probably means the `Fetch Notification Pool` query returned zero agents. Check `SELECT * FROM agents WHERE on_shift=true AND is_available=true;`. During testing, make sure at least your test agents have `on_shift=true`.

**Meta's 24-hour window (applies even through Twilio)** — outside the sandbox, you can only freely message a user within 24h of their last message to you. Agent fan-out messages need **approved Content Templates** in Twilio Console once you're out of sandbox. That's the one thing Twilio doesn't spare you from; templates still need to be submitted. Sandbox bypasses this entirely for development.

## What's next (not in this package)

- **WF1** — inbound router that parses Twilio webhooks and routes to WF3b when body matches `/^TOMO-([A-Z0-9]{4})$/i`
- **WF2** — lead intake that populates `conversations` and `properties_cache`, then calls WF3a
- **WF4** — AI conversation agent (only runs when `conversations.mode = 'ai'`)
- **WF5** — human handoff (flips `conversations.mode = 'human'`)

Build order: WF1 + WF2 next, because without them WF3 has no way to be triggered in production. Then WF4 (AI), then WF5 (handoff).
