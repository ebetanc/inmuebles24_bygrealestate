# WhatsApp Agent Setup Guide (Evolution API)

Complete setup for the 7-workflow WhatsApp lead management system.

## Prerequisites

- Evolution API instance running (Hostinger VPS)
- n8n instance running (https://n8n.srv856940.hstgr.cloud/)
- Supabase project (free tier is fine)

---

## Step 1: Supabase Database

1. Create a project at [supabase.com](https://supabase.com)
2. Go to **SQL Editor** and run migrations in order:
   - `migrations/0001_init.sql` (base tables: agents, conversations, auctions, messages, properties_cache)
   - `migrations/0002_rls.sql` (row-level security)
   - `migrations/0004_evolution.sql` (Evolution adaptations + listings table)
3. **Skip** `0003_seed_dev.sql` for now (it has test data with fake numbers)
4. Get your connection string: **Settings > Database > Connection string > URI**
   - Use the **Session pooler** (port 5432), NOT Transaction pooler
   - Format: `postgresql://postgres.[ref]:[password]@aws-0-[region].pooler.supabase.com:5432/postgres`

### Seed your real agents

Run this in Supabase SQL Editor with your real agent data:

```sql
INSERT INTO agents (agent_id, name, whatsapp_number, on_shift, is_available)
VALUES
  ('agent_1', 'Agent Name 1', '5215500000001', true, true),
  ('agent_2', 'Agent Name 2', '5215500000002', true, true),
  ('agent_3', 'Agent Name 3', '5215500000003', true, true),
  ('agent_4', 'Agent Name 4', '5215500000004', true, true),
  ('agent_5', 'Agent Name 5', '5215500000005', true, true)
ON CONFLICT (agent_id) DO NOTHING;
```

**Phone number format**: Plain digits with country code, NO `+` prefix.
Example: `5215598765432` (Mexico: 52 country, 1 for mobile, then 10 digits)

---

## Step 2: Evolution API Configuration

### 2a. Get your Evolution API details

From your Evolution dashboard/API:
- **API URL**: The base URL (e.g., `https://evolution.yourdomain.com`)
- **Instance name**: The name you gave your instance (e.g., `inmobiliaria24`)
- **API key**: Global or instance-level API key

### 2b. Connect your WhatsApp number

If not done already:
```bash
# Check instance status
curl -X GET "https://YOUR_EVOLUTION_URL/instance/connectionState/YOUR_INSTANCE" \
  -H "apikey: YOUR_API_KEY"
```

If status is `close`, generate QR code:
```bash
curl -X GET "https://YOUR_EVOLUTION_URL/instance/connect/YOUR_INSTANCE" \
  -H "apikey: YOUR_API_KEY"
```

Scan the QR code with the WhatsApp phone you want to use for the bot.

### 2c. Configure the webhook

Set Evolution to send message events to your n8n webhook:

```bash
curl -X POST "https://YOUR_EVOLUTION_URL/webhook/set/YOUR_INSTANCE" \
  -H "apikey: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://n8n.srv856940.hstgr.cloud/webhook/evolution-webhook",
    "webhook_by_events": false,
    "webhook_base64": false,
    "events": [
      "MESSAGES_UPSERT"
    ]
  }'
```

Verify the webhook is set:
```bash
curl -X GET "https://YOUR_EVOLUTION_URL/webhook/find/YOUR_INSTANCE" \
  -H "apikey: YOUR_API_KEY"
```

---

## Step 3: n8n Setup

### 3a. Create Postgres credential

1. Go to n8n > **Credentials > Add Credential > Postgres**
2. Name: `Postgres - Supabase`
3. Fill in from your Supabase connection string:
   - Host: `aws-0-[region].pooler.supabase.com`
   - Database: `postgres`
   - User: `postgres.[ref]`
   - Password: your password
   - Port: `5432`
   - SSL: Enable (set to `Allow`)

### 3b. Set environment variables

In n8n: **Settings > Environment Variables** (or via docker env):

```
EVOLUTION_API_URL=https://your-evolution-url.com
EVOLUTION_INSTANCE=inmobiliaria24
EVOLUTION_API_KEY=your_api_key
MANAGER_PHONE=5215500000099
OPENROUTER_API_KEY=your_openrouter_key
OPENROUTER_MODEL=anthropic/claude-sonnet-4
```

### 3c. Import workflows (in this order)

Import from **Workflows > Import from File**:

1. `WF3c_expiry_sweeper.json`
2. `WF3a_auction_launcher.json`
3. `WF3b_claim_handler.json`
4. `WF5_human_handoff.json`
5. `WF4_ai_conversation.json`
6. `WF2_lead_intake.json`
7. `WF1_inbound_router.json`

### 3d. Note workflow IDs and set env vars

After importing each workflow, note its ID from the URL bar (the number after `/workflow/`).

Add these environment variables:

```
WF2_WORKFLOW_ID=<id of WF2>
WF3A_WORKFLOW_ID=<id of WF3a>
WF3B_WORKFLOW_ID=<id of WF3b>
WF4_WORKFLOW_ID=<id of WF4>
WF5_WORKFLOW_ID=<id of WF5>
```

### 3e. Fix credential references

For EACH imported workflow:
1. Open the workflow
2. Click on every **Postgres** node
3. Select your `Postgres - Supabase` credential from the dropdown
4. Save

### 3f. Activate workflows

1. **WF1** (Inbound Router) — Activate (webhook must be active to receive)
2. **WF3c** (Expiry Sweeper) — Activate (schedule trigger)
3. WF2, WF3a, WF3b, WF4, WF5 — Do NOT need activation (called by other workflows)

---

## Step 4: Test the System

### Test 1: Evolution webhook connectivity

Send a WhatsApp message to your bot number from a non-agent phone.
Check n8n executions — WF1 should fire and route to WF2.

### Test 2: Full auction flow

1. Send "Hola, me interesa la propiedad" from a test phone
2. WF1 should classify as `new_lead` and call WF2
3. WF2 creates conversation, sends acknowledgment, calls WF3a
4. WF3a sends TOMO codes to all on-shift agents
5. An agent replies `TOMO-XXXX` from their phone
6. WF1 routes to WF3b, atomic claim happens
7. Winner gets confirmation, lead gets AI greeting

### Test 3: AI conversation

After an auction is claimed:
1. Send a property question from the lead phone: "Cuantas recamaras tiene?"
2. WF1 routes to WF4 (mode=ai)
3. WF4 calls OpenRouter, sends AI response

### Test 4: Human handoff

1. From the lead phone, send: "Quiero agendar una visita"
2. WF4 should detect handoff need, call WF5
3. Agent gets conversation summary
4. Lead gets "connecting you with agent" message
5. Subsequent messages from lead get forwarded to agent (mode=human)

---

## Troubleshooting

### "No executions firing when I send a message"
- Check Evolution webhook URL is correct: `https://n8n.srv856940.hstgr.cloud/webhook/evolution-webhook`
- Check WF1 is **activated** (toggle must be ON)
- Check Evolution instance is connected (connectionState = open)
- Check Evolution webhook events include `MESSAGES_UPSERT`

### "Message sending fails (Evolution API error)"
- Verify `EVOLUTION_API_URL`, `EVOLUTION_INSTANCE`, `EVOLUTION_API_KEY` env vars
- Test manually: `curl -X POST "$EVOLUTION_API_URL/message/sendText/$EVOLUTION_INSTANCE" -H "apikey: $EVOLUTION_API_KEY" -H "Content-Type: application/json" -d '{"number":"YOUR_PHONE","text":"test"}'`
- Phone numbers must be plain digits with country code (no + prefix)

### "Auction notifications not reaching agents"
- Check `SELECT * FROM agents WHERE on_shift=true AND is_available=true;`
- Verify agent phone numbers are in correct format (no + prefix)
- Check WF3a execution logs for errors

### "AI responses are empty or error"
- Verify `OPENROUTER_API_KEY` is valid
- Check `OPENROUTER_MODEL` is a valid model name
- Look at WF4 execution details — the "Call OpenRouter LLM" node output

### "Duplicate messages"
- The dedup in WF1 uses Evolution's message ID (msg_external_id)
- If you see duplicates, check if Evolution is sending the same event multiple times
- Check the messages table: `SELECT * FROM messages ORDER BY created_at DESC LIMIT 10;`
