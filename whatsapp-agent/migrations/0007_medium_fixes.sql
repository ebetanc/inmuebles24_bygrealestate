-- ============================================================================
-- 0007_medium_fixes.sql -- Fix medium bugs identified in validation audit
--
-- Fixes:
--   M2: TOMO short_code has only 65K combos (hex) + blanket UNIQUE blocks reuse
--       → Wider alphabet (30 chars), partial UNIQUE on open auctions only
--   M4: find_returning_lead() email match can link wrong leads
--       → Prioritize phone matches over email matches in ORDER BY
--   M5: WF2 ILIKE search too broad with short terms
--       → Handled at workflow level (min 5 chars for ILIKE), no SQL change needed
--
-- M1 already fixed by C3. M3/M6 are workflow-level fixes (no SQL).
-- Idempotent: safe to re-run.
-- ============================================================================

-- M2a: Generate TOMO code with wider alphabet (30^4 = 810,000 combos)
-- Excludes I, O, 0, 1 for readability
CREATE OR REPLACE FUNCTION generate_tomo_code()
RETURNS TEXT AS $$
DECLARE
  chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  result TEXT := '';
  i INTEGER;
BEGIN
  FOR i IN 1..4 LOOP
    result := result || substr(chars, floor(random() * length(chars) + 1)::int, 1);
  END LOOP;
  RETURN result;
END;
$$ LANGUAGE plpgsql VOLATILE;

-- M2b: Replace blanket UNIQUE with partial UNIQUE on open auctions only.
-- Expired/claimed/cancelled auctions can reuse codes freely.
ALTER TABLE auctions DROP CONSTRAINT IF EXISTS auctions_short_code_key;

CREATE UNIQUE INDEX IF NOT EXISTS idx_auctions_short_code_open
  ON auctions(short_code)
  WHERE status = 'open';

-- M4: Prioritize phone matches over email matches in find_returning_lead()
CREATE OR REPLACE FUNCTION find_returning_lead(
  p_phone TEXT,
  p_email TEXT DEFAULT NULL,
  p_property TEXT DEFAULT NULL
)
RETURNS TABLE (
  conversation_id    UUID,
  assigned_agent_id  TEXT,
  current_property   TEXT,
  same_property      BOOLEAN,
  mode               TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.conversation_id,
    c.assigned_agent_id,
    c.current_property,
    (c.current_property = p_property AND p_property IS NOT NULL)::BOOLEAN AS same_property,
    c.mode
  FROM conversations c
  WHERE c.lead_phone = p_phone
     OR (p_email IS NOT NULL AND c.lead_email = p_email)
  ORDER BY
    CASE WHEN c.lead_phone = p_phone THEN 0 ELSE 1 END,
    c.last_message_at DESC;
END;
$$ LANGUAGE plpgsql STABLE;
