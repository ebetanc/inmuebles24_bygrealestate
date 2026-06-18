-- ============================================================================
-- 0012_agent_followups.sql -- Agent lead follow-up tracker (Phase 10)
--
-- Adds a pending-prompt tracker so the follow-up sweeper (WF14) can ask agents
-- about ONE lead at a time and map each free-text reply (WF15) back to the
-- correct lead. Also adds the stage-based cadence view, reply-matching helpers,
-- and a weekly-report summary view.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- 1. tracker table -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS lead_followups (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id UUID NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  agent_id        TEXT NOT NULL REFERENCES agents(agent_id),
  prompt_kind     TEXT NOT NULL
                  CHECK (prompt_kind IN ('new_2h','new_24h','stalled','visit_day')),
  prompt_sent_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  answered_at     TIMESTAMPTZ,
  response_text   TEXT,
  parsed_stage    TEXT,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','answered','expired'))
);
COMMENT ON TABLE lead_followups IS
  'One row per follow-up question sent to an agent. Maps agent reply -> lead; feeds weekly report.';

CREATE INDEX IF NOT EXISTS idx_followups_agent_active
  ON lead_followups(agent_id, prompt_sent_at DESC)
  WHERE status IN ('pending','answered');
CREATE INDEX IF NOT EXISTS idx_followups_conv
  ON lead_followups(conversation_id, status);
-- Hard backstop: at most ONE pending prompt per lead at a time (no pile-up).
CREATE UNIQUE INDEX IF NOT EXISTS idx_followups_one_pending
  ON lead_followups(conversation_id)
  WHERE status = 'pending';

ALTER TABLE lead_followups ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE tablename='lead_followups' AND policyname='followups_read') THEN
    CREATE POLICY followups_read ON lead_followups FOR SELECT USING (true);
  END IF;
END $$;

-- 2. cadence view: which (lead, prompt_kind) are due right now -----------------
-- Owning agent = conversations.assigned_agent_id (lead already claimed).
-- Excludes closed leads and any lead that currently has a pending prompt.
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
)
-- new_2h: assigned >2h ago, agent never replied, not yet asked
SELECT b.*, 'new_2h'::text AS prompt_kind FROM base b
WHERE b.stage IN ('new','contacted')
  AND b.first_response_at IS NULL
  AND b.assigned_at <= NOW() - INTERVAL '2 hours'
  AND NOT EXISTS (SELECT 1 FROM lead_followups f
                  WHERE f.conversation_id=b.conversation_id AND f.prompt_kind='new_2h')
UNION ALL
-- new_24h: same, but 24h escalation
SELECT b.*, 'new_24h' FROM base b
WHERE b.stage IN ('new','contacted')
  AND b.first_response_at IS NULL
  AND b.assigned_at <= NOW() - INTERVAL '24 hours'
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
  'Stage-based cadence: emits (lead, agent, prompt_kind) rows due for a follow-up DM.';

-- 3a. record a sent prompt (called by WF14 after a successful send) -----------
CREATE OR REPLACE FUNCTION record_followup_sent(
  p_conversation_id uuid, p_agent_id text, p_kind text
) RETURNS bigint AS $$
  INSERT INTO lead_followups (conversation_id, agent_id, prompt_kind)
  VALUES (p_conversation_id, p_agent_id, p_kind)
  RETURNING id;
$$ LANGUAGE sql;

-- 3b. find the active followup for an agent (WF15) ----------------------------
-- Returns the pending prompt if any; else the most-recently-answered prompt
-- within 15 min (a correction window). is_correction tells WF15 which it is.
CREATE OR REPLACE FUNCTION get_active_followup(p_agent_id text)
RETURNS TABLE(
  followup_id bigint, conversation_id uuid, lead_name text,
  prompt_kind text, current_stage text, is_correction boolean
) AS $$
  SELECT f.id, f.conversation_id, c.lead_name, f.prompt_kind,
         COALESCE(ls.stage,'new'), (f.status='answered') AS is_correction
  FROM lead_followups f
  JOIN conversations c     ON c.conversation_id = f.conversation_id
  LEFT JOIN lead_status ls ON ls.conversation_id = f.conversation_id
  WHERE f.agent_id = p_agent_id
    AND (f.status='pending'
         OR (f.status='answered' AND f.answered_at > NOW() - INTERVAL '15 minutes'))
  ORDER BY (f.status='pending') DESC, f.prompt_sent_at DESC
  LIMIT 1;
$$ LANGUAGE sql STABLE;

-- 3c. mark a followup answered (WF15, after update_lead_stage) -----------------
CREATE OR REPLACE FUNCTION answer_followup(
  p_followup_id bigint, p_response text, p_stage text
) RETURNS void AS $$
  UPDATE lead_followups
  SET status='answered', answered_at=NOW(), response_text=p_response, parsed_stage=p_stage
  WHERE id = p_followup_id;
$$ LANGUAGE sql;

-- 3d. weekly summary of unanswered follow-ups (WF16) --------------------------
CREATE OR REPLACE VIEW weekly_followup_summary AS
SELECT
  a.agent_id,
  a.name AS agent_name,
  count(*) FILTER (WHERE f.status='pending')  AS pending_count,
  count(*) FILTER (WHERE f.status='expired'
                   AND f.prompt_sent_at >= NOW() - INTERVAL '7 days') AS expired_7d,
  count(*) FILTER (WHERE f.status='answered'
                   AND f.answered_at >= NOW() - INTERVAL '7 days')    AS answered_7d
FROM agents a
LEFT JOIN lead_followups f ON f.agent_id = a.agent_id
GROUP BY a.agent_id, a.name;

COMMENT ON VIEW weekly_followup_summary IS
  'Per-agent follow-up responsiveness for the weekly gerente report (WF16).';
