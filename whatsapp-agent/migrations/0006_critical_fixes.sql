-- ============================================================================
-- 0006_critical_fixes.sql -- Fix critical bugs identified in validation audit
--
-- Fixes:
--   C1: classify_sender() returns multiple rows for recurring leads
--       → Use LATERAL JOIN with ORDER BY last_message_at DESC LIMIT 1
--   C5: Calendar editor delete+insert is not atomic
--       → Create save_month_schedule() PL/pgSQL function with SECURITY DEFINER
--
-- Idempotent: safe to re-run (uses CREATE OR REPLACE).
-- ============================================================================

-- C1: Fix classify_sender() to return exactly 1 row for recurring leads.
-- After migration 0005 dropped UNIQUE on conversations.lead_phone,
-- the LEFT JOIN can return N rows. This uses LATERAL + LIMIT 1 to always
-- return the most recent conversation (by last_message_at).
CREATE OR REPLACE FUNCTION classify_sender(sender_phone TEXT)
RETURNS TABLE (
  is_agent        BOOLEAN,
  agent_id        TEXT,
  agent_name      TEXT,
  conversation_id UUID,
  conv_mode       TEXT,
  assigned_agent_id TEXT,
  current_property TEXT,
  assigned_agent_phone TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    (a.agent_id IS NOT NULL)::BOOLEAN AS is_agent,
    a.agent_id,
    a.name AS agent_name,
    c.conversation_id,
    c.mode AS conv_mode,
    c.assigned_agent_id,
    c.current_property,
    aa.whatsapp_number AS assigned_agent_phone
  FROM (SELECT sender_phone AS phone) AS input
  LEFT JOIN agents a ON a.whatsapp_number = input.phone
  LEFT JOIN LATERAL (
    SELECT * FROM conversations conv
    WHERE conv.lead_phone = input.phone
    ORDER BY conv.last_message_at DESC NULLS LAST
    LIMIT 1
  ) c ON TRUE
  LEFT JOIN agents aa ON aa.agent_id = c.assigned_agent_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- C5: Atomic calendar save function.
-- Wraps DELETE + INSERT in a single transaction (PL/pgSQL body is atomic).
-- Uses SECURITY DEFINER to bypass RLS regardless of which key the dashboard uses.
CREATE OR REPLACE FUNCTION save_month_schedule(
  p_first_date DATE,
  p_last_date DATE,
  p_rows JSONB -- [{schedule_date, shift, agent_id}, ...]
)
RETURNS INTEGER AS $$
DECLARE
  inserted INTEGER;
BEGIN
  -- Delete existing entries for this date range
  DELETE FROM agent_schedule
  WHERE schedule_date >= p_first_date
    AND schedule_date <= p_last_date;

  -- Insert new entries from JSONB array
  INSERT INTO agent_schedule (schedule_date, shift, agent_id)
  SELECT
    (r->>'schedule_date')::DATE,
    r->>'shift',
    r->>'agent_id'
  FROM jsonb_array_elements(p_rows) AS r;

  GET DIAGNOSTICS inserted = ROW_COUNT;
  RETURN inserted;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
