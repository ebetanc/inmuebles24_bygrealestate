-- ============================================================================
-- 0001_init.sql — base schema for EasyBroker × WhatsApp agent
--
-- Run via: psql "$DATABASE_URL" -f migrations/0001_init.sql
-- Or paste into Supabase Dashboard → SQL Editor and click Run.
--
-- Idempotent: safe to re-run.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- --- agents ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agents (
  agent_id          TEXT PRIMARY KEY,             -- match EasyBroker agent_id when available
  name              TEXT NOT NULL,
  whatsapp_number   TEXT NOT NULL UNIQUE,          -- STORE in E.164 WITHOUT 'whatsapp:' prefix
  on_shift          BOOLEAN NOT NULL DEFAULT false,
  is_available      BOOLEAN NOT NULL DEFAULT true,
  easybroker_email  TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  agents                  IS 'Sales agents pool. Rotates via on_shift flag.';
COMMENT ON COLUMN agents.whatsapp_number  IS 'E.164 without the whatsapp: prefix. Prefix is added by workflows at send time.';

-- --- conversations ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS conversations (
  conversation_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_phone         TEXT NOT NULL UNIQUE,
  lead_name          TEXT,
  current_property   TEXT,                         -- EasyBroker public_id
  assigned_agent_id  TEXT REFERENCES agents(agent_id),
  mode               TEXT NOT NULL DEFAULT 'pending_assignment'
                     CHECK (mode IN ('pending_assignment','ai','human')),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_message_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON COLUMN conversations.mode IS
  'pending_assignment = auction in flight; ai = WF4 drives replies; human = assigned agent drives replies.';

-- --- auctions (the heart of WF3) -------------------------------------------
CREATE TABLE IF NOT EXISTS auctions (
  auction_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  short_code         TEXT NOT NULL UNIQUE,         -- 4-char claim token, e.g. 'AB12'
  conversation_id    UUID NOT NULL REFERENCES conversations(conversation_id),
  property_id        TEXT NOT NULL,
  status             TEXT NOT NULL DEFAULT 'open'
                     CHECK (status IN ('open','claimed','expired','cancelled')),
  winner_agent_id    TEXT REFERENCES agents(agent_id),
  notified_agents    TEXT[] NOT NULL DEFAULT '{}',
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  claimed_at         TIMESTAMPTZ,
  expires_at         TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_auctions_open
  ON auctions(status, expires_at) WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_auctions_conversation
  ON auctions(conversation_id);

COMMENT ON TABLE auctions IS
  'First-reply-wins assignment auctions. Claims happen via atomic UPDATE ... WHERE status=open.';

-- --- messages (full audit log) ---------------------------------------------
CREATE TABLE IF NOT EXISTS messages (
  message_id        BIGSERIAL PRIMARY KEY,
  conversation_id   UUID REFERENCES conversations(conversation_id),
  direction         TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  sender_type       TEXT NOT NULL CHECK (sender_type IN ('lead','agent','ai','system')),
  recipient_phone   TEXT,
  body              TEXT,
  twilio_sid        TEXT UNIQUE,                   -- dedup key for inbound Twilio webhooks
  metadata          JSONB,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation
  ON messages(conversation_id, created_at DESC);

-- --- properties_cache ------------------------------------------------------
CREATE TABLE IF NOT EXISTS properties_cache (
  property_id       TEXT PRIMARY KEY,
  payload           JSONB NOT NULL,
  fetched_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE properties_cache IS
  'Cache of EasyBroker property payloads. Refreshed periodically by WF6 (or on cache miss).';
