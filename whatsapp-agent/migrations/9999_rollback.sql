-- ============================================================================
-- 9999_rollback.sql — tear down everything this repo creates
--
-- Dev use only. WIPES ALL DATA in the tables below.
-- ============================================================================

DROP TABLE IF EXISTS messages          CASCADE;
DROP TABLE IF EXISTS auctions          CASCADE;
DROP TABLE IF EXISTS conversations     CASCADE;
DROP TABLE IF EXISTS agents            CASCADE;
DROP TABLE IF EXISTS properties_cache  CASCADE;
