-- ============================================================================
-- Schema for WF3 (Auction) and dependencies
-- Run this once against your application Postgres database before importing
-- the n8n workflow. Safe to re-run (uses IF NOT EXISTS).
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- gen_random_uuid()

-- --- Agents pool ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agents (
  agent_id          TEXT PRIMARY KEY,            -- match EasyBroker agent_id when possible
  name              TEXT NOT NULL,
  whatsapp_number   TEXT NOT NULL UNIQUE,         -- STORE in E.164 WITHOUT 'whatsapp:' prefix, e.g. '+5215598765432'
  on_shift          BOOLEAN NOT NULL DEFAULT false,
  is_available      BOOLEAN NOT NULL DEFAULT true,
  easybroker_email  TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- --- Conversations ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS conversations (
  conversation_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_phone         TEXT NOT NULL UNIQUE,        -- E.164 without 'whatsapp:' prefix
  lead_name          TEXT,
  current_property   TEXT,                        -- EasyBroker public_id
  assigned_agent_id  TEXT REFERENCES agents(agent_id),
  mode               TEXT NOT NULL DEFAULT 'pending_assignment'
                     CHECK (mode IN ('pending_assignment','ai','human')),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_message_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- --- Auctions (the heart of WF3) -------------------------------------------
CREATE TABLE IF NOT EXISTS auctions (
  auction_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  short_code         TEXT NOT NULL UNIQUE,        -- 4-char claim token, e.g. 'AB12'
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

-- Partial index: fast lookups for the only status we query a lot.
CREATE INDEX IF NOT EXISTS idx_auctions_open
  ON auctions(status, expires_at) WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_auctions_conversation
  ON auctions(conversation_id);

-- --- Messages log (WF3 writes outbound rows here for audit) ----------------
CREATE TABLE IF NOT EXISTS messages (
  message_id        BIGSERIAL PRIMARY KEY,
  conversation_id   UUID REFERENCES conversations(conversation_id),
  direction         TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  sender_type       TEXT NOT NULL CHECK (sender_type IN ('lead','agent','ai','system')),
  recipient_phone   TEXT,
  body              TEXT,
  twilio_sid        TEXT UNIQUE,                 -- dedup key for inbound
  metadata          JSONB,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation
  ON messages(conversation_id, created_at DESC);

-- --- Properties cache ------------------------------------------------------
CREATE TABLE IF NOT EXISTS properties_cache (
  property_id       TEXT PRIMARY KEY,
  payload           JSONB NOT NULL,
  fetched_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================================
-- Seed data for testing. Replace with real agents before going live.
-- ============================================================================
INSERT INTO agents (agent_id, name, whatsapp_number, on_shift, is_available)
VALUES
  ('agent_yolanda', 'Yolanda',  '+5215500000001', true, true),
  ('agent_marusa',  'Marusa',   '+5215500000002', true, true),
  ('agent_gina',    'Gina',     '+5215500000003', true, true)
ON CONFLICT (agent_id) DO NOTHING;
