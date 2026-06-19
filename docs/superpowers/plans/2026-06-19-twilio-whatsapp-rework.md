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

## Teardown of Evolution test (later)
Remove `agent_test_fr`, restore `agent_manager` (Sandy) `on_shift=true`, delete test
conversation `544cad05…` + its auction/lead_followups/lead_status rows.
