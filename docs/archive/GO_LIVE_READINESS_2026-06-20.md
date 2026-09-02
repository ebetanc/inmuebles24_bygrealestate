# Go-Live Readiness Audit — 2026-06-20 (afternoon target)

Scope of "fully live": Pi scrapes every 15 min → WhatsApp auctions each lead owner-first → guard on no-answer → claimer gets everything to contact + follow up to close → weekly report to Marusa.

## VERDICT
- **Unattended fully-live TODAY: NO-GO.** One hard blocker (proactive WhatsApp templates) + three setup gaps.
- **Supervised LIVE DEMO with your phone TODAY: GO** — via the 24h-window workaround (below). This is what to show the client.

Live system of record = `wa-rework/out/*` (Meta Cloud API, deployed live `fae1c7b`). The `whatsapp-agent/workflows/*` tree is stale Evolution — ignore.

---

## BLOCKERS (unattended live)

### 1. [HARD BLOCKER] Proactive auction messages need approved Meta templates
- Every agent-notify / auction / follow-up / report send is Cloud API `type:"text"` (session message). **16 text sends, 0 templates.**
- Meta only delivers free-form text within **24h of the agent's last inbound** message. Outside that window → error **131047**, message NOT delivered. Node has `continueOnFail:true` → **failure is silent**, lead rots, dashboard logs it as "notified."
- No approved templates exist; display-name/business verification was PENDING.
- Impact: an agent who hasn't messaged the bot in 24h never sees the lead. Kills unattended auctioning.
- Fix: create + get Meta approval for templates (auction-notify w/ params property + lead + TOMO code; follow-up; report; escalation), switch those nodes to `type:"template"`. Keep `text` only for in-window replies. ETA = Meta approval (hours–days).

### 2. [BLOCKER] Pi schedule is 2h, not 15 min — and may not be enabled
- Repo timer = every 2h business hours; `TODO.md` shows even that not yet enabled. 15-min not configured anywhere.
- Scraper code/POST/dedup/retry are production-ready and E2E-proven; only the schedule is missing.
- Fix on the Pi: confirm `gost-proxy` up + `.env` (creds, WEBHOOK_URL, CHROME_PROXY); set timer `OnCalendar=*-*-* *:00/15:00`; `daemon-reload && enable --now`; watch first runs.

### 3. [BLOCKER] No guard schedule + no real agents on shift
- DB now: `on_shift=1` (only the TEST agent, Esteban), `guard_today=0`, `guard_next7=0`.
- Owner routing has coverage (8 agents, 14 aliases ✓) but the **guard fallback tier has nobody**, and no agent is on_shift for the auction.
- Fix: client decides who is on shift this afternoon → set `on_shift=true` for them + populate `/calendario` guard rows for today. (Needs client input — can't guess.)

### 4. [VERIFY] Weekly report recipient = Marusa
- WF16 sends to `$env.MANAGER_PHONE`; repo has a placeholder. Marusa = `5215583377338`.
- Fix: confirm the live n8n env `MANAGER_PHONE` resolves to Marusa before activating WF16 (cron Mon 08:00 — also pin timezone).

### 5. [VERIFY] Confirm all workflows imported + active in live n8n
- wa-rework/out is the deployed Cloud API set, but confirm in the running n8n: WF10/12/13/3a/3b/3c/14/15/16 all `active`, and `*_WORKFLOW_ID` env vars + Postgres credential bound. Needs n8n API/UI.

---

## WHAT'S SOLID (verified)
- **Claimer gets the lead's phone** — WF3b post-claim message includes lead name + `📱 lead_phone` + property. The #1 message-content requirement passes.
- Owner→guard→manager **timing design**: owner 2 min → guard 5 min → manager, sweeper every 1 min.
- **Follow-up self-terminates** on `closed_won`/`closed_lost` (view `leads_needing_followup`).
- Scraper field names match WF10 intake exactly; dedup on `lead_id` prevents 15-min re-flooding.
- Owner alias coverage: 8 agents / 14 tags.
- Inbound WF1 is POST + parses Meta payload → agent replies open their 24h window.

## NICE-TO-HAVE (not launch-blocking)
- Post-claim message shows `property_id` only; could add price, listing link, intention (venta/renta), and a suggested first-contact line — `property_payload` is already fetched but unused.

---

## LIVE n8n STATE (verified via API 2026-06-20 pm)
Active (Cloud API; names say "(Evolution)" but send to graph.facebook.com): WF1, WF2, WF3a, WF3b, WF3c, WF4, WF5, WF6, WF7, WF10, WF12, WF14, WF15, WF16. Off: WF8. Also running on this n8n: a separate **Kommo CRM** stack ("CRM 360 Sync", "The Dispatcher") — unrelated to BYG, confirm it's not double-handling leads.

### NEW BLOCKER 0 — Owner-first routing is NOT deployed
- Live `WF10` (id Obr38705ZZYS3FB8) goes: `Webhook → Create Day Conversation → Prepare Auction → Call WF3a (TOMO Auction)`. It **never calls WF12 (Owner Resolver)**, and **WF13 (Owner Notify) does not exist** in the deployed set.
- `WF12` is active but **orphaned** (nothing calls it). 
- `WF3a` "Fetch Agent Pool" = `WHERE on_shift=true AND is_available=true OR agent_id=$1` → flat fan-out to on-shift agents, first-reply-wins. No "owner del inmueble primero → guardia si no contesta" cascade.
- The owner-first source EXISTS in the repo (`whatsapp-agent/workflows/WF10/WF12/WF13`) but was NOT carried into the live Cloud-API deploy. To meet the requirement, owner-first must be (re)built + deployed in Cloud-API form: deploy WF13, rewire WF10 → WF12 → WF13 (owner 2 min) → fallback WF3a (guard). Substantial; do NOT rush it hours before a client demo.

## SUPERVISED LIVE DEMO PLAN (today, with your phone)
Works WITHOUT templates by opening the 24h window manually.

Pre-flight:
1. Add your phone as an on-shift agent (or reuse `agent_test_fr`) and give it an owner alias so owner-routing targets it.
2. From your phone, **send any WhatsApp to the bot** → opens your 24h window (bypasses the template blocker).
3. Confirm WF10 + the routing chain are active in n8n.

Run:
4. POST one test lead to the WF10 webhook (synthetic, marked) whose property tag = your alias.
5. Owner tier DMs your phone the lead + `TOMO-XXXX`. Reply `TOMO-XXXX`.
6. You receive the claim confirmation **with the lead's phone** → show client the agent now has everything to contact.
7. (Optional) trigger a follow-up prompt; reply to show stage advance.
8. Clean up the synthetic lead after.

Risk during demo: only your in-window phone is safe to notify. Do NOT let it fan out to real agents/Marusa unless their windows are open (they aren't). Constrain routing to your phone only.
