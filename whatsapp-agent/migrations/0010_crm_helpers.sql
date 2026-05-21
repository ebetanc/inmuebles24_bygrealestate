-- ============================================================================
-- 0010_crm_helpers.sql -- RPC helpers for n8n workflow integration
--
-- Builds on 0009. Provides safe, atomic mutation entry points so n8n nodes
-- can write CRM state via single Postgres calls (no JSON-editing the
-- workflow internals).
--
-- Functions:
--   mark_assigned(conv_id, agent_id, via)   -- set assignment + assigned_at
--   mark_first_response(conv_id)            -- stamp first_response_at once
--   record_sla_breach(conv_id)              -- escalate stage + manager hook
--   get_sla_breaches()                      -- WF11 polling helper
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. mark_assigned
--    Called by WF3b (claim handler) and WF3a (auction launcher) when an
--    agent claims or is auto-assigned a lead.
--    Sets assigned_agent_id, assigned_at, assignment_method, claimed_via.
--    Bumps lead_status to 'contacted' if currently 'new'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_assigned(
  p_conversation_id UUID,
  p_agent_id        TEXT,
  p_claimed_via     TEXT DEFAULT 'tomo_auction'
) RETURNS conversations AS $$
DECLARE
  v_conv conversations;
BEGIN
  IF p_claimed_via NOT IN ('tomo_auction','night_queue','manual','escalation') THEN
    RAISE EXCEPTION 'invalid claimed_via: %', p_claimed_via;
  END IF;

  UPDATE conversations
     SET assigned_agent_id   = p_agent_id,
         assigned_at         = COALESCE(assigned_at, NOW()),
         assignment_method   = 'whatsapp_number',
         claimed_via         = p_claimed_via,
         mode                = CASE WHEN mode = 'ai' THEN 'human' ELSE mode END
   WHERE conversation_id = p_conversation_id
   RETURNING * INTO v_conv;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'conversation not found: %', p_conversation_id;
  END IF;

  -- Bump stage to 'contacted' if not already further along
  INSERT INTO lead_status (conversation_id, stage, updated_by)
  VALUES (p_conversation_id, 'contacted', p_agent_id)
  ON CONFLICT (conversation_id) DO UPDATE
    SET stage = CASE
                  WHEN lead_status.stage = 'new' THEN 'contacted'
                  ELSE lead_status.stage
                END,
        updated_by = EXCLUDED.updated_by;

  RETURN v_conv;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION mark_assigned IS
  'Atomic lead claim. Used by WF3a/WF3b. Sets assigned_at once, bumps stage.';

-- ---------------------------------------------------------------------------
-- 2. mark_first_response
--    Called by WF1 (inbound router) the first time an outbound human message
--    leaves the system on a conversation. Stamps first_response_at exactly
--    once -- subsequent calls are no-ops.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_first_response(
  p_conversation_id UUID
) RETURNS TIMESTAMPTZ AS $$
DECLARE
  v_ts TIMESTAMPTZ;
BEGIN
  UPDATE conversations
     SET first_response_at = NOW()
   WHERE conversation_id = p_conversation_id
     AND first_response_at IS NULL
   RETURNING first_response_at INTO v_ts;

  RETURN v_ts; -- NULL if already stamped (idempotent)
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION mark_first_response IS
  'Stamps first_response_at once. Idempotent. Used by WF1 on first agent outbound.';

-- ---------------------------------------------------------------------------
-- 3. record_sla_breach
--    Called by WF11 when a lead crosses the 15-min no-response threshold.
--    Escalates stage path and inserts a history note. Does NOT change
--    assigned_agent_id -- that's a manual / WF3c decision.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_sla_breach(
  p_conversation_id UUID,
  p_note            TEXT DEFAULT 'SLA breach: 15min sin respuesta'
) RETURNS VOID AS $$
BEGIN
  INSERT INTO lead_status_history (conversation_id, from_stage, to_stage, changed_by, note)
  SELECT p_conversation_id,
         COALESCE(ls.stage, 'new'),
         COALESCE(ls.stage, 'new'),  -- not a stage change, just an audit note
         NULL,
         p_note
  FROM (SELECT 1) _
  LEFT JOIN lead_status ls ON ls.conversation_id = p_conversation_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION record_sla_breach IS
  'Logs SLA breach to history without mutating current stage. Used by WF11.';

-- ---------------------------------------------------------------------------
-- 4. get_sla_breaches (WF11 helper -- returns rows for processing loop)
--    Equivalent to SELECT * FROM sla_breaches but as a function for n8n
--    Postgres node convenience (function call vs raw query in workflow JSON).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_sla_breaches()
RETURNS TABLE (
  conversation_id    UUID,
  lead_name          TEXT,
  lead_phone         TEXT,
  assigned_agent_id  TEXT,
  agent_name         TEXT,
  assigned_at        TIMESTAMPTZ,
  pending_seconds    INT,
  stage              TEXT
) AS $$
  SELECT * FROM sla_breaches;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION get_sla_breaches IS
  'Wrapper over sla_breaches view for WF11 (cleaner n8n Postgres node call).';

-- ---------------------------------------------------------------------------
-- 5. Grants -- service_role uses these; anon stays read-only on views
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION mark_assigned(UUID, TEXT, TEXT)   TO service_role;
GRANT EXECUTE ON FUNCTION mark_first_response(UUID)         TO service_role;
GRANT EXECUTE ON FUNCTION record_sla_breach(UUID, TEXT)     TO service_role;
GRANT EXECUTE ON FUNCTION get_sla_breaches()                TO service_role, anon, authenticated;
