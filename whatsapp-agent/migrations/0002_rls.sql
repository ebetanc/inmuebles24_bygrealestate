-- ============================================================================
-- 0002_rls.sql — Row-Level Security for Supabase
--
-- Why this matters: Supabase's default Postgres role for API access (`anon`,
-- `authenticated`) is subject to RLS. Any table without policies will REJECT
-- all queries from those roles — you'll see "permission denied for table X".
--
-- n8n connects as the `postgres` (superuser) role via the direct connection
-- string, which BYPASSES RLS entirely. So for n8n these policies are not
-- strictly required. BUT: we still want RLS enabled + restrictive policies
-- so that if anyone ever queries these tables via the Supabase REST API
-- (e.g. a future admin dashboard), they can't accidentally read/write lead
-- data without explicit grants.
--
-- If you want to query these tables from the Supabase SQL Editor as the
-- default user, run `SET ROLE postgres;` first, or disable RLS temporarily
-- for debugging.
-- ============================================================================

ALTER TABLE agents            ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversations     ENABLE ROW LEVEL SECURITY;
ALTER TABLE auctions          ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages          ENABLE ROW LEVEL SECURITY;
ALTER TABLE properties_cache  ENABLE ROW LEVEL SECURITY;

-- Default deny: no policies on `anon` or `authenticated` roles means
-- nothing gets through those roles. The postgres/service_role user bypasses
-- RLS and sees everything — that's what n8n uses.

-- If you later add an admin dashboard, you'll grant policies here. Example:
--
-- CREATE POLICY "admins_read_conversations" ON conversations
--   FOR SELECT TO authenticated
--   USING (auth.jwt() ->> 'role' = 'admin');
