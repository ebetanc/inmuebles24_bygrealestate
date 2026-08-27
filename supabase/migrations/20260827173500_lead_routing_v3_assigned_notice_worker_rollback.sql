DROP FUNCTION IF EXISTS public.release_v3_assigned_notice_failure(BIGINT,TEXT,TEXT,TIMESTAMPTZ);
DROP FUNCTION IF EXISTS public.claim_v3_assigned_notices(INTEGER,TIMESTAMPTZ);
-- reconcile_delivery_callback is intentionally not dropped: it predates V3.
-- Restore it from whatsapp-agent/migrations/0030_delivery_attempts.sql when a
-- full migration rollback is explicitly required.
