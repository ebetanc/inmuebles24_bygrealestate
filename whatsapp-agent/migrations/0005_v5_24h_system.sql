-- ============================================================================
-- 0005_v5_24h_system.sql -- Schema changes for v5 24/7 lead system
--
-- Changes:
--   1. Drop UNIQUE on conversations.lead_phone (allow recurring leads)
--   2. Add source + arrived_during columns to conversations
--   3. Add lead_email column to conversations (for returning lead detection)
--   4. Create agent_schedule table (Google Sheets sync)
--   5. Create night_queue table (overnight lead buffer)
--   6. Add shift_slot column to agents
--   7. Update conversations mode CHECK to include 'night_queued'
--   8. Add indexes for returning lead detection
--   9. Add helper function for CDMX time check
--  10. Seed the 6 BYG agents (placeholder phones — update before go-live)
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Drop UNIQUE on conversations.lead_phone
--    Allows same phone to have multiple conversations (different properties)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'conversations_lead_phone_key'
  ) THEN
    ALTER TABLE conversations DROP CONSTRAINT conversations_lead_phone_key;
    RAISE NOTICE 'Dropped UNIQUE constraint on conversations.lead_phone';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Add source column to conversations
--    Tracks which lead source originated this conversation
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'conversations' AND column_name = 'source'
  ) THEN
    ALTER TABLE conversations ADD COLUMN source TEXT DEFAULT 'inmuebles24'
      CHECK (source IN ('inmuebles24', 'easybroker', 'whatsapp_direct'));
    RAISE NOTICE 'Added source column to conversations';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Add arrived_during column to conversations
--    Distinguishes day vs night arrivals for routing and reporting
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'conversations' AND column_name = 'arrived_during'
  ) THEN
    ALTER TABLE conversations ADD COLUMN arrived_during TEXT DEFAULT 'day'
      CHECK (arrived_during IN ('day', 'night'));
    RAISE NOTICE 'Added arrived_during column to conversations';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Add lead_email column to conversations
--    Used for returning lead detection (phone OR email match)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'conversations' AND column_name = 'lead_email'
  ) THEN
    ALTER TABLE conversations ADD COLUMN lead_email TEXT;
    RAISE NOTICE 'Added lead_email column to conversations';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. Update mode CHECK constraint to include 'night_queued'
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  ALTER TABLE conversations DROP CONSTRAINT IF EXISTS conversations_mode_check;
  ALTER TABLE conversations ADD CONSTRAINT conversations_mode_check
    CHECK (mode IN ('pending_assignment', 'ai', 'human', 'night_queued'));
  RAISE NOTICE 'Updated mode CHECK constraint';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'mode CHECK update skipped: %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------------
-- 6. Add shift_slot column to agents
--    Tracks which shift slot this agent is assigned to today
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'agents' AND column_name = 'shift_slot'
  ) THEN
    ALTER TABLE agents ADD COLUMN shift_slot TEXT
      CHECK (shift_slot IS NULL OR shift_slot IN ('morning', 'afternoon'));
    RAISE NOTICE 'Added shift_slot column to agents';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 7. Create agent_schedule table
--    Populated daily from Google Sheets by WF6
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agent_schedule (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  schedule_date   DATE NOT NULL,
  shift           TEXT NOT NULL CHECK (shift IN ('morning', 'afternoon')),
  agent_id        TEXT NOT NULL REFERENCES agents(agent_id),
  synced_at       TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(schedule_date, shift, agent_id)
);

COMMENT ON TABLE agent_schedule IS
  'Guard duty calendar. Synced from Google Sheets daily at midnight + 2 PM CDMX.';
COMMENT ON COLUMN agent_schedule.shift IS
  'morning = 8:00-14:00 CDMX, afternoon = 14:00-21:00 CDMX';

CREATE INDEX IF NOT EXISTS idx_agent_schedule_date
  ON agent_schedule(schedule_date, shift);

ALTER TABLE agent_schedule ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 8. Create night_queue table
--    Buffers overnight leads for morning auto-TOMO at 8:05 AM
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS night_queue (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id UUID REFERENCES conversations(conversation_id),
  source          TEXT NOT NULL CHECK (source IN ('inmuebles24', 'easybroker', 'whatsapp_direct')),
  lead_phone      TEXT NOT NULL,
  lead_name       TEXT,
  property_id     TEXT,
  lead_email      TEXT,
  temperature     TEXT CHECK (temperature IS NULL OR temperature IN ('high', 'medium', 'low')),
  bot_summary     TEXT,
  queued_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed       BOOLEAN NOT NULL DEFAULT FALSE,
  processed_at    TIMESTAMPTZ,
  auction_id      UUID
);

COMMENT ON TABLE night_queue IS
  'Overnight leads waiting for 8:05 AM auto-TOMO. Processed by WF7 morning report.';
COMMENT ON COLUMN night_queue.temperature IS
  'Lead temperature from AI bot analysis (WhatsApp direct only). NULL for scraped/EasyBroker leads.';
COMMENT ON COLUMN night_queue.bot_summary IS
  'AI bot conversation summary for morning report. NULL if no bot interaction.';

CREATE INDEX IF NOT EXISTS idx_night_queue_pending
  ON night_queue(processed, queued_at) WHERE processed = FALSE;

ALTER TABLE night_queue ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 9. Indexes for returning lead detection
--    Fast lookup by phone + property for recurring lead check
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_conversations_lead_phone
  ON conversations(lead_phone);

CREATE INDEX IF NOT EXISTS idx_conversations_lead_email
  ON conversations(lead_email) WHERE lead_email IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_conversations_phone_property
  ON conversations(lead_phone, current_property);

-- ---------------------------------------------------------------------------
-- 10. Helper function: check if current CDMX time is day or night
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION is_daytime()
RETURNS BOOLEAN AS $$
DECLARE
  cdmx_hour INTEGER;
BEGIN
  cdmx_hour := EXTRACT(HOUR FROM NOW() AT TIME ZONE 'America/Mexico_City');
  -- Day = 8:00 to 20:59 (8 AM to 8:59 PM), Night = 21:00 to 7:59
  RETURN cdmx_hour >= 8 AND cdmx_hour < 21;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION is_daytime IS
  'Returns TRUE during business hours (8 AM - 9 PM CDMX). Used by day/night router.';

-- ---------------------------------------------------------------------------
-- 11. Helper function: get current CDMX time period
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_shift()
RETURNS TEXT AS $$
DECLARE
  cdmx_hour INTEGER;
BEGIN
  cdmx_hour := EXTRACT(HOUR FROM NOW() AT TIME ZONE 'America/Mexico_City');
  IF cdmx_hour >= 8 AND cdmx_hour < 14 THEN
    RETURN 'morning';
  ELSIF cdmx_hour >= 14 AND cdmx_hour < 21 THEN
    RETURN 'afternoon';
  ELSE
    RETURN 'night';
  END IF;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION current_shift IS
  'Returns current shift: morning (8-14), afternoon (14-21), or night (21-8) CDMX.';

-- ---------------------------------------------------------------------------
-- 12. Helper function: find returning lead
--     Returns existing conversation if same lead + same property
-- ---------------------------------------------------------------------------
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
  ORDER BY c.last_message_at DESC;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION find_returning_lead IS
  'Check if a lead has contacted before. Returns all matching conversations ordered by recency.';

-- ---------------------------------------------------------------------------
-- 13. Helper function: get on-shift agents for current time
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_on_shift_agents()
RETURNS TABLE (
  agent_id          TEXT,
  name              TEXT,
  whatsapp_number   TEXT
) AS $$
DECLARE
  v_shift TEXT;
  v_today DATE;
BEGIN
  v_shift := current_shift();
  v_today := (NOW() AT TIME ZONE 'America/Mexico_City')::DATE;

  -- If night, no agents on shift
  IF v_shift = 'night' THEN
    RETURN;
  END IF;

  -- First try agent_schedule (Google Sheets sync)
  RETURN QUERY
  SELECT a.agent_id, a.name, a.whatsapp_number
  FROM agent_schedule s
  JOIN agents a ON a.agent_id = s.agent_id
  WHERE s.schedule_date = v_today
    AND s.shift = v_shift
    AND a.is_available = TRUE;

  -- Fallback: if no schedule found, use agents.on_shift flag
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT a.agent_id, a.name, a.whatsapp_number
    FROM agents a
    WHERE a.on_shift = TRUE
      AND a.is_available = TRUE;
  END IF;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION get_on_shift_agents IS
  'Returns agents on shift right now. Uses agent_schedule first, falls back to on_shift flag.';

-- ---------------------------------------------------------------------------
-- 14. Seed BYG agents (placeholder phones — update before go-live)
--     Uses ON CONFLICT to be idempotent
-- ---------------------------------------------------------------------------
INSERT INTO agents (agent_id, name, whatsapp_number, on_shift, is_available)
VALUES
  ('agent_lupita',  'Lupita',  '5215500000001', false, true),
  ('agent_paty',    'Paty',    '5215500000002', false, true),
  ('agent_yol',     'Yol',     '5215500000003', false, true),
  ('agent_gina',    'Gina',    '5215500000004', false, true),
  ('agent_carol',   'Carol',   '5215500000005', false, true),
  ('agent_moni',    'Moni',    '5215500000006', false, true),
  ('agent_manager', 'Manager', '5215500000099', true,  true)
ON CONFLICT (agent_id) DO UPDATE SET
  name = EXCLUDED.name,
  is_available = EXCLUDED.is_available;
