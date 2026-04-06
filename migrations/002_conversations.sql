-- Migration 002: Conversations table for WhatsApp bot memory
-- Run against Postgres/Supabase

CREATE TABLE IF NOT EXISTS conversations (
    id              SERIAL PRIMARY KEY,
    phone_number    TEXT NOT NULL,
    role            TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
    message         TEXT NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Fast lookup: recent messages per phone number
CREATE INDEX IF NOT EXISTS idx_conversations_phone
    ON conversations(phone_number, created_at DESC);
