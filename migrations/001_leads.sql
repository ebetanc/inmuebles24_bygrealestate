-- Migration 001: Leads table for Inmuebles24 scraped data
-- Run against Postgres/Supabase

CREATE TABLE IF NOT EXISTS leads (
    id              SERIAL PRIMARY KEY,
    lead_id         TEXT UNIQUE NOT NULL,
    name            TEXT,
    email           TEXT,
    phone           TEXT,
    message         TEXT,
    listing_id      TEXT,
    address         TEXT,
    price           TEXT,
    listing_type    TEXT,
    property_type   TEXT,
    source_tab      TEXT,
    scraped_at      TIMESTAMPTZ,
    synced_to_crm   BOOLEAN DEFAULT FALSE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Index for CRM sync retry workflow
CREATE INDEX IF NOT EXISTS idx_leads_crm_sync
    ON leads(synced_to_crm) WHERE synced_to_crm = FALSE;

-- Index for WhatsApp bot listing queries
CREATE INDEX IF NOT EXISTS idx_leads_listing_type
    ON leads(listing_type);

CREATE INDEX IF NOT EXISTS idx_leads_address
    ON leads USING gin(to_tsvector('spanish', coalesce(address, '')));
