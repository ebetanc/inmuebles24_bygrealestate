# Twilio WhatsApp Rework — Plan

Date: 2026-06-19
Branch: `feat/twilio-whatsapp`

## Why
Evolution/Baileys (consumer WhatsApp link) repeatedly hits `conflict / device_removed`
401 and drops on send — unusable for production. Switch outbound + inbound to the
**Twilio WhatsApp API** (official BSP, no QR, no device_removed). The system was Twilio
originally (`files (1)/` workflows, migration `0004_evolution.sql` was the swap to
Evolution) so there is precedent to convert back to.

## Approach
Use the n8n native **`n8n-nodes-base.twilio`** node (credential-based) for every outbound
send, matching the old `files (1)/WF3a` pattern. Rewrite WF1 inbound parsing for Twilio's
form-encoded webhook. Phone format becomes `whatsapp:+<E164>`.

## Changes (n8n workflows — all 14 active)
Outbound: replace each Evolution `httpRequest` send
(`{{$env.EVOLUTION_API_URL}}/message/sendText/{{$env.EVOLUTION_INSTANCE}}`,
apikey header, body `{number,text}`) with a `twilio` node:
- `from = {{$env.TWILIO_WHATSAPP_FROM}}` (e.g. `whatsapp:+52155...`)
- `to   = whatsapp:+<digits>` (prefix the stored agent/lead number)
- `message = <text>`
- credential `twilioApi` (n8n credential `Twilio - BYG`)
- `continueOnFail=true` on fan-outs so one failed send doesn't abort the batch.

Affected send nodes: WF1 (forward + pending), WF2, WF3a (fan-out), WF3b (×2 confirm+lead),
WF3c (escalation), WF4 (AI reply), WF5 (handoff), WF7 (×2 reports), WF8, WF10 (×2),
WF13 (owner — N/A, TOMO path), WF14, WF15, WF16.

Inbound (WF1 "Parse Evolution Payload" → "Parse Twilio Payload"):
- Twilio posts `application/x-www-form-urlencoded`: `From=whatsapp:+5215...`, `Body`,
  `ProfileName`, `WaId`, `MessageSid`, `To`.
- Extract `phone = From.replace('whatsapp:+','')`; `text = Body`; `pushName = ProfileName`;
  `messageId = MessageSid`. Feed the existing `Dedup + Classify Sender` unchanged.
- Webhook still `evolution-webhook` path (rename optional) — Twilio's inbound webhook for
  the WA sender points here. Twilio expects a 200 / TwiML; respond empty 200.

Number format helper: stored numbers are bare digits (`5215554132332`, `33628457768`).
Twilio `to` = `whatsapp:+` + digits. Inbound strips `whatsapp:+`.

## n8n env (add)
`TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` (or n8n Twilio credential),
`TWILIO_WHATSAPP_FROM=whatsapp:+<twilio MX number>`. Keep `MANAGER_PHONE` etc. Evolution
vars can stay (unused) or be removed.

## Templates (proactive messages)
Business-initiated sends outside the 24h customer window REQUIRE approved WhatsApp
templates: TOMO auction notify (WF3a), follow-up prompts (WF14), reports (WF7/WF16),
manager escalation (WF3c). Within 24h of an inbound agent message, free-form Body works.
For the first test, have the agent message the bot first (opens 24h window) → free-form OK.
Production: register templates in Twilio Content Template Builder and switch proactive
sends to `contentSid` + variables.

## Prerequisites (user)
1. Twilio account → Account SID + Auth Token.
2. Buy a Twilio MX number; register it as a **WhatsApp sender** (Twilio Console →
   Messaging → Senders → WhatsApp senders) — needs Meta Business Manager + display name;
   approval can take hours–days.
2b. Point the sender's inbound webhook to `https://n8n.srv856940.hstgr.cloud/webhook/evolution-webhook`.
3. Provide SID, token, the `whatsapp:+` From number.
4. Approve templates (later, for production proactive sends).

## Sequencing
User does (1)(2) — the long pole. I convert workflows on this branch in parallel. Integrate
+ test once the Twilio sender is live (sandbox can validate the n8n wiring sooner).

## PIVOT 2026-06-19: target is Meta Cloud API (not Twilio), clean native rework

Channel PROVEN working (see [[whatsapp-cloud-api]]). n8n env already set
(`WA_PHONE_NUMBER_ID`, `WA_ACCESS_TOKEN`, `WA_VERIFY_TOKEN=byg_wa_verify_2026`,
`WA_API_VERSION=v21.0`). User chose **clean native rework** (no adapter shim).
Live WF1 export backed up at VPS `/root/wa-rework/wf1.bak.json`.

### Exact transforms
**Send nodes (httpRequest, Evolution → Cloud API):**
- URL `={{ "https://graph.facebook.com/" + $env.WA_API_VERSION + "/" + $env.WA_PHONE_NUMBER_ID + "/messages" }}`
- Headers: `Authorization: Bearer {{$env.WA_ACCESS_TOKEN}}`, `Content-Type: application/json`
- Body (json): `{ "messaging_product":"whatsapp", "to": <existing number expr, bare digits>, "type":"text", "text": { "body": <existing text expr> } }`
- Keep `continueOnFail` on fan-outs. `to` = bare digits (NO `whatsapp:` prefix; that's Twilio).
- Capture returned `messages[0].id` (wamid) where the old flow logged the Evolution id.

**WF1 inbound (webhook `snF6Sr9CBJIevMVD`, path `evolution-webhook`):**
- Webhook node → `multipleMethods: true`, `httpMethod: ["GET","POST"]`,
  `responseMode: "responseNode"`.
- After webhook, IF `{{$json.query?.['hub.mode']}}` present (GET verify):
  - true → Respond to Webhook, body `={{$json.query['hub.challenge']}}` (verify
    `query['hub.verify_token'] === $env.WA_VERIFY_TOKEN` first).
  - false → Respond 200 (fast ack) → "Parse Meta Payload" → existing Dedup+Classify.
- "Parse Meta Payload" (replaces Parse Evolution Payload): read
  `body.entry[0].changes[0].value`; if `.messages?.[0]`: `phone = messages[0].from`
  (bare digits), `text = messages[0].text?.body`, `messageId = messages[0].id`,
  `pushName = value.contacts?.[0]?.profile?.name`. If `.statuses` instead → ignore
  (delivery status). Keep group/self filters (Cloud API inbound has no fromMe/g.us;
  drop those checks).

### Webhook wiring (after WF1 reworked)
1. Meta App → WhatsApp → Configuration: Callback URL
   `https://n8n.srv856940.hstgr.cloud/webhook/evolution-webhook`, Verify token
   `byg_wa_verify_2026`, click Verify (WF1 must answer GET), subscribe field `messages`.
2. `POST /{WABA_ID}/subscribed_apps` with the token to subscribe the app.
3. Gives inbound + delivery statuses.

### Templates (proactive: TOMO WF3a, follow-up WF14, reports WF7/WF16, escalation WF3c)
Create + submit in WhatsApp Manager → Message templates; switch those sends to
`type:"template"` with `template.name`+`language`+`components`. Free-form works only
within 24h of an inbound user msg. Blocked on display name "BYG Phone" approval
(PENDING_REVIEW) for reliable proactive delivery.

### Deploy gotchas
`n8n execute --id` fails (port 5679 in use while server runs). `import:workflow` resets
`active=false` → after import run `update:workflow --id=<id> --active=true`; some changes
need `docker compose restart n8n`. Build JSONs as files + import with backups; do NOT
blind-sed live workflows.

## Teardown of Evolution test (later)
Remove `agent_test_fr`, restore `agent_manager` (Sandy) `on_shift=true`, delete test
conversation `544cad05…` + its auction/lead_followups/lead_status rows.
