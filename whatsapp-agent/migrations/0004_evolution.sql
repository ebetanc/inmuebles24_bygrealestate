-- ============================================================================
-- 0004_evolution.sql -- Migrate from Twilio to Evolution API
--
-- Changes:
--   1. Rename messages.twilio_sid -> msg_external_id (Evolution message IDs)
--   2. Add listings table (property data from scraper)
--   3. Add scrape_logs table (scraper audit trail)
--   4. Update comments to reflect Evolution API conventions
--   5. Add phone number helper function
--
-- Phone number convention (Evolution API):
--   Store WITHOUT '+' prefix: '5215512345678' (not '+5215512345678')
--   Evolution expects plain digits with country code, no prefix.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- 1. Rename twilio_sid -> msg_external_id in messages table
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'messages' AND column_name = 'twilio_sid'
  ) THEN
    ALTER TABLE messages RENAME COLUMN twilio_sid TO msg_external_id;
  END IF;
END $$;

COMMENT ON COLUMN messages.msg_external_id IS
  'Dedup key: Evolution message ID (key.id from webhook payload). Replaces former twilio_sid.';

-- 2. Update agent phone number convention comment
COMMENT ON COLUMN agents.whatsapp_number IS
  'Plain digits with country code, NO + prefix. Example: 5215598765432. Evolution API format.';

-- 3. Listings table (populated by scraper, read by AI bot)
CREATE TABLE IF NOT EXISTS listings (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  listing_hash    TEXT NOT NULL UNIQUE,
  title           TEXT,
  price           TEXT,
  price_numeric   NUMERIC,
  currency        TEXT DEFAULT 'MXN',
  location        TEXT,
  city            TEXT DEFAULT 'Ciudad de Mexico',
  url             TEXT,
  property_type   TEXT,
  operation_type  TEXT,
  bedrooms        INTEGER,
  bathrooms       INTEGER,
  area_m2         NUMERIC,
  description     TEXT,
  image_url       TEXT,
  source_page     INTEGER DEFAULT 1,
  raw_data        JSONB,
  first_seen_at   TIMESTAMPTZ DEFAULT NOW(),
  last_seen_at    TIMESTAMPTZ DEFAULT NOW(),
  is_active       BOOLEAN DEFAULT TRUE,
  notified        BOOLEAN DEFAULT FALSE,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_listings_hash ON listings(listing_hash);
CREATE INDEX IF NOT EXISTS idx_listings_active ON listings(is_active);
CREATE INDEX IF NOT EXISTS idx_listings_location ON listings(location);
CREATE INDEX IF NOT EXISTS idx_listings_price ON listings(price_numeric);

ALTER TABLE listings ENABLE ROW LEVEL SECURITY;

-- Auto-update trigger for listings.updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_listings_updated_at ON listings;
CREATE TRIGGER update_listings_updated_at
  BEFORE UPDATE ON listings
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- 4. Scrape logs table
CREATE TABLE IF NOT EXISTS scrape_logs (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id          TEXT NOT NULL,
  started_at      TIMESTAMPTZ DEFAULT NOW(),
  completed_at    TIMESTAMPTZ,
  status          TEXT DEFAULT 'running',
  total_scraped   INTEGER DEFAULT 0,
  new_listings    INTEGER DEFAULT 0,
  duplicates      INTEGER DEFAULT 0,
  pages_scraped   INTEGER DEFAULT 0,
  error_message   TEXT,
  notifications_sent BOOLEAN DEFAULT FALSE,
  metadata        JSONB,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_scrape_logs_run ON scrape_logs(run_id);
CREATE INDEX IF NOT EXISTS idx_scrape_logs_status ON scrape_logs(status);

ALTER TABLE scrape_logs ENABLE ROW LEVEL SECURITY;

-- 5. Helper: strip '+' from phone for Evolution API
CREATE OR REPLACE FUNCTION evolution_phone(phone TEXT)
RETURNS TEXT AS $$
BEGIN
  RETURN LTRIM(phone, '+');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION evolution_phone IS
  'Strips leading + from E.164 phone numbers for Evolution API compatibility.';

-- 6. Helper: classify an inbound message sender
-- Returns agent info + conversation info in one query
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
  LEFT JOIN conversations c ON c.lead_phone = input.phone
  LEFT JOIN agents aa ON aa.agent_id = c.assigned_agent_id;
END;
$$ LANGUAGE plpgsql STABLE;
