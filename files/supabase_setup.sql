-- ============================================================
-- INMUEBLES24 SCRAPER - SUPABASE DATABASE SETUP
-- ============================================================
-- Run this SQL in your Supabase SQL Editor (Dashboard > SQL Editor)
-- This creates all tables, indexes, and RLS policies needed
-- ============================================================

-- 1. LISTINGS TABLE - Stores all scraped property listings
-- ============================================================
CREATE TABLE IF NOT EXISTS public.listings (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_hash    TEXT NOT NULL UNIQUE,          -- SHA-256 hash for dedup (based on URL + title)
    title           TEXT,                           -- Property title
    price           TEXT,                           -- Price as displayed (e.g., "$3,500,000 MXN")
    price_numeric   NUMERIC,                        -- Parsed numeric price for filtering
    currency        TEXT DEFAULT 'MXN',             -- Currency code
    location        TEXT,                           -- Neighborhood / address
    city            TEXT DEFAULT 'Ciudad de México',
    url             TEXT,                           -- Full listing URL on inmuebles24
    property_type   TEXT,                           -- Casa, Departamento, Terreno, etc.
    operation_type  TEXT,                           -- Venta, Renta, Desarrollo
    bedrooms        INTEGER,
    bathrooms       INTEGER,
    area_m2         NUMERIC,                        -- Area in square meters
    description     TEXT,                           -- Short description
    image_url       TEXT,                           -- Main listing image
    source_page     INTEGER DEFAULT 1,              -- Which page it was scraped from
    raw_data        JSONB,                          -- Full raw scraped data for reference
    first_seen_at   TIMESTAMPTZ DEFAULT NOW(),      -- When we first discovered this listing
    last_seen_at    TIMESTAMPTZ DEFAULT NOW(),      -- Last time we saw it in scrape results
    is_active       BOOLEAN DEFAULT TRUE,           -- Whether listing is still live
    notified        BOOLEAN DEFAULT FALSE,          -- Whether notification was sent
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for fast lookups
CREATE INDEX IF NOT EXISTS idx_listings_hash ON public.listings (listing_hash);
CREATE INDEX IF NOT EXISTS idx_listings_url ON public.listings (url);
CREATE INDEX IF NOT EXISTS idx_listings_active ON public.listings (is_active);
CREATE INDEX IF NOT EXISTS idx_listings_notified ON public.listings (notified);
CREATE INDEX IF NOT EXISTS idx_listings_first_seen ON public.listings (first_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_listings_price ON public.listings (price_numeric);
CREATE INDEX IF NOT EXISTS idx_listings_location ON public.listings (location);

-- 2. SCRAPE_LOGS TABLE - Tracks every scrape run
-- ============================================================
CREATE TABLE IF NOT EXISTS public.scrape_logs (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          TEXT NOT NULL,                   -- Unique ID for each workflow execution
    started_at      TIMESTAMPTZ DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    status          TEXT DEFAULT 'running',          -- running, success, error
    total_scraped   INTEGER DEFAULT 0,               -- Total listings found in scrape
    new_listings    INTEGER DEFAULT 0,               -- New listings discovered
    duplicates      INTEGER DEFAULT 0,               -- Already-known listings
    pages_scraped   INTEGER DEFAULT 0,               -- Number of pages scraped
    error_message   TEXT,                            -- Error details if failed
    notifications_sent BOOLEAN DEFAULT FALSE,
    metadata        JSONB,                           -- Additional run metadata
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_scrape_logs_run ON public.scrape_logs (run_id);
CREATE INDEX IF NOT EXISTS idx_scrape_logs_status ON public.scrape_logs (status);
CREATE INDEX IF NOT EXISTS idx_scrape_logs_date ON public.scrape_logs (started_at DESC);

-- 3. NOTIFICATION_LOG TABLE - Tracks sent notifications
-- ============================================================
CREATE TABLE IF NOT EXISTS public.notification_log (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id      BIGINT REFERENCES public.listings(id),
    channel         TEXT NOT NULL,                   -- telegram, email, slack, webhook
    status          TEXT DEFAULT 'sent',             -- sent, failed, pending
    message_preview TEXT,                            -- First 200 chars of message
    error_message   TEXT,
    sent_at         TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notification_listing ON public.notification_log (listing_id);

-- 4. AUTO-UPDATE TRIGGER for updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER update_listings_updated_at
    BEFORE UPDATE ON public.listings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- 5. ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================
-- Disable RLS for service_role access (n8n uses service_role key)
-- If you want to enable RLS, create appropriate policies

ALTER TABLE public.listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scrape_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_log ENABLE ROW LEVEL SECURITY;

-- Allow full access for service_role (used by n8n)
CREATE POLICY "Service role full access on listings"
    ON public.listings
    FOR ALL
    USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

CREATE POLICY "Service role full access on scrape_logs"
    ON public.scrape_logs
    FOR ALL
    USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

CREATE POLICY "Service role full access on notification_log"
    ON public.notification_log
    FOR ALL
    USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

-- Allow anon read access to listings (for a potential dashboard)
CREATE POLICY "Anon read access on listings"
    ON public.listings
    FOR SELECT
    USING (true);

-- 6. HELPER FUNCTION: Get listing stats
-- ============================================================
CREATE OR REPLACE FUNCTION get_listing_stats()
RETURNS TABLE (
    total_listings BIGINT,
    active_listings BIGINT,
    new_today BIGINT,
    new_this_week BIGINT,
    avg_price NUMERIC,
    last_scrape TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        COUNT(*)::BIGINT AS total_listings,
        COUNT(*) FILTER (WHERE is_active)::BIGINT AS active_listings,
        COUNT(*) FILTER (WHERE first_seen_at >= CURRENT_DATE)::BIGINT AS new_today,
        COUNT(*) FILTER (WHERE first_seen_at >= CURRENT_DATE - INTERVAL '7 days')::BIGINT AS new_this_week,
        ROUND(AVG(price_numeric) FILTER (WHERE price_numeric > 0), 2) AS avg_price,
        MAX(sl.started_at) AS last_scrape
    FROM public.listings l
    LEFT JOIN (
        SELECT MAX(started_at) AS started_at FROM public.scrape_logs WHERE status = 'success'
    ) sl ON true;
END;
$$ LANGUAGE plpgsql;

-- 7. HELPER FUNCTION: Mark stale listings as inactive
-- ============================================================
CREATE OR REPLACE FUNCTION mark_stale_listings(days_threshold INTEGER DEFAULT 7)
RETURNS INTEGER AS $$
DECLARE
    affected_count INTEGER;
BEGIN
    UPDATE public.listings
    SET is_active = FALSE
    WHERE last_seen_at < NOW() - (days_threshold || ' days')::INTERVAL
      AND is_active = TRUE;
    GET DIAGNOSTICS affected_count = ROW_COUNT;
    RETURN affected_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- SETUP COMPLETE
-- ============================================================
-- After running this SQL:
-- 1. Go to Settings > API to get your project URL and service_role key
-- 2. Use the service_role key (NOT anon key) in n8n credentials
-- 3. The service_role key bypasses RLS for full access
-- ============================================================
