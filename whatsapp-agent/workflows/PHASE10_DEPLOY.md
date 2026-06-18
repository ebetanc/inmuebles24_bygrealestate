# Phase 10 — Agent Follow-Up: Activation Checklist (post-go-live)

Migration 0012 is already merged (additive, safe). Workflows are imported but INACTIVE.
Do NOT activate until ALL of the below pass.

## Preconditions
- [ ] Evolution bot number connected and stable (out of `device_removed` 401 cooldown).
- [ ] `agents.whatsapp_number` populated with each agent's real number (plain digits, no `+`).
- [ ] `MANAGER_PHONE` env set to the gerente's number.
- [ ] `OPENROUTER_API_KEY` / `OPENROUTER_MODEL` present (already used by WF4).

## Import + wire (n8n, CLI-only on VPS — see infra memory)
- [ ] Import WF14, WF15, WF16; set each node's Postgres credential to the real
      `Postgres - Supabase` credential ID (replaces `REPLACE_WITH_POSTGRES_CREDENTIAL_ID`).
- [ ] Set env `WF15_WORKFLOW_ID` to WF15's imported workflow ID.
- [ ] Re-import the edited WF1 (agent_followup_reply branch + Call WF15 node).

## Smoke test (manual, before activating crons)
- [ ] Manually create one pending followup row for a test agent + lead.
- [ ] From the test agent's WhatsApp, reply in free text → confirm WF15 advanced the
      stage in `lead_status`, marked the followup answered, and the agent got a ✅ confirmation.
- [ ] Send a correction within 15 min → confirm it re-updates the stage.
- [ ] Manually execute WF14 once → confirm it DMs the agent the right stage-based question.
- [ ] Manually execute WF16 once → confirm the gerente receives the report.

## Activate
- [ ] Activate WF14, WF15, WF16. Watch first business-day run.
