-- ============================================================================
-- 0019_gate_followup_on_i24_note.sql -- Gate i24 follow-ups on portal note
--
-- Inmuebles24 leads must not surface in leads_needing_followup until the
-- note-back bot has written the assignment note in the i24 portal
-- (conversations.i24_note_added=true), so the agent's WhatsApp prompt and the
-- portal note don't race/duplicate. Fallback: if 24h passed since assigned_at
-- and the note still isn't written (scraper down), the lead surfaces anyway so
-- the advisor is never blocked by a broken bot.
--
-- Non-i24 leads (easybroker, etc.) are unaffected: c.source <> 'inmuebles24'
-- short-circuits the guard to true for them.
--
-- Same view as 0012_agent_followups.sql with one guard added to the base CTE
-- WHERE clause. Idempotent: safe to re-run.
-- ============================================================================
CREATE OR REPLACE VIEW leads_needing_followup AS
WITH base AS (
  SELECT
    c.conversation_id,
    c.lead_name,
    c.lead_phone,
    c.assigned_agent_id              AS agent_id,
    a.name                           AS agent_name,
    a.whatsapp_number                AS agent_number,
    c.assigned_at,
    c.first_response_at,
    c.current_property,
    COALESCE(ls.stage,'new')         AS stage,
    ls.stage_changed_at,
    ls.next_action_at,
    COALESCE(pc.payload->>'title', c.current_property, 'la propiedad') AS property_title,
    NULLIF(pc.payload->>'operation_type','')                          AS operation
  FROM conversations c
  JOIN agents a            ON a.agent_id = c.assigned_agent_id
  LEFT JOIN lead_status ls ON ls.conversation_id = c.conversation_id
  LEFT JOIN properties_cache pc ON pc.property_id = c.current_property
  WHERE c.assigned_agent_id IS NOT NULL
    AND COALESCE(ls.stage,'new') NOT IN ('closed_won','closed_lost')
    AND NOT EXISTS (
      SELECT 1 FROM lead_followups f
      WHERE f.conversation_id = c.conversation_id AND f.status = 'pending'
    )
    AND (c.source <> 'inmuebles24' OR c.i24_note_added OR c.assigned_at <= NOW() - INTERVAL '24 hours')
)
-- new_2h: assigned >2h ago, agent never replied, not yet asked
SELECT b.*, 'new_2h'::text AS prompt_kind FROM base b
WHERE b.stage IN ('new','contacted')
  AND b.first_response_at IS NULL
  AND b.assigned_at <= NOW() - INTERVAL '2 hours'
  AND NOT EXISTS (SELECT 1 FROM lead_followups f
                  WHERE f.conversation_id=b.conversation_id AND f.prompt_kind='new_2h')
UNION ALL
-- new_24h: 24h escalation. Only AFTER a new_2h was already recorded, so the two
-- arms never emit together in one view eval (which would double-send and trip the
-- one-pending unique index).
SELECT b.*, 'new_24h' FROM base b
WHERE b.stage IN ('new','contacted')
  AND b.first_response_at IS NULL
  AND b.assigned_at <= NOW() - INTERVAL '24 hours'
  AND EXISTS (SELECT 1 FROM lead_followups f
              WHERE f.conversation_id=b.conversation_id AND f.prompt_kind='new_2h')
  AND NOT EXISTS (SELECT 1 FROM lead_followups f
                  WHERE f.conversation_id=b.conversation_id AND f.prompt_kind='new_24h')
UNION ALL
-- stalled: in-progress stage with no change in 2 days, not nudged in last 2 days
SELECT b.*, 'stalled' FROM base b
WHERE b.stage IN ('contacted','qualified','offer')
  AND b.stage_changed_at <= NOW() - INTERVAL '2 days'
  AND NOT EXISTS (SELECT 1 FROM lead_followups f
                  WHERE f.conversation_id=b.conversation_id AND f.prompt_kind='stalled'
                    AND f.prompt_sent_at > NOW() - INTERVAL '2 days')
UNION ALL
-- visit_day: visit scheduled for today, not yet reminded today
SELECT b.*, 'visit_day' FROM base b
WHERE b.stage = 'visit_scheduled'
  AND b.next_action_at::date = CURRENT_DATE
  AND NOT EXISTS (SELECT 1 FROM lead_followups f
                  WHERE f.conversation_id=b.conversation_id AND f.prompt_kind='visit_day'
                    AND f.prompt_sent_at::date = CURRENT_DATE);

COMMENT ON VIEW leads_needing_followup IS
  'Stage-based cadence: emits (lead, agent, prompt_kind) rows due for a follow-up DM. i24 leads gated on portal note (or 24h fallback).';
