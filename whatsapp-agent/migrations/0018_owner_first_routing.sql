-- 0018: Owner-first tiered routing (applied to prod Supabase 2026-07-04 via MCP
-- migration `owner_first_routing_eb_owner`).
--
-- Tier 1: the property's owner agent gets a 2-min directed TOMO DM (WF13).
-- Tier 2: no claim -> guard auction among on-shift agents + manager (WF3a, 5 min).
-- Tier 3: no claim -> auto-assign to manager (WF3c).
--
-- The owner comes from EasyBroker's property LIST endpoint, whose `agent`
-- field carries the individual asesor name (the detail endpoint still returns
-- only the company account). n8n WF18 syncs it here daily at 7:45 CDMX;
-- label -> agent_id resolution happens at read time via property_agent_alias
-- (see 0011), so alias fixes apply immediately without a re-sync.

CREATE TABLE IF NOT EXISTS eb_property_owner (
  public_id   text PRIMARY KEY,
  agent_label text NOT NULL,
  synced_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE eb_property_owner ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS eb_property_owner_read ON eb_property_owner;
CREATE POLICY eb_property_owner_read ON eb_property_owner FOR SELECT USING (true);

-- The scraper extracts the EB code (EB-XXXX) from the lead detail page;
-- stored on the conversation so night-queue leads can still resolve an owner
-- at the 8:05 AM batch.
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS property_public_id text;

-- Full-name aliases for the labels EasyBroker returns today.
-- resolve_agent_from_tags() also receives the first word as fallback, but the
-- explicit full names are cheap insurance.
INSERT INTO property_agent_alias (tag_normalized, agent_id) VALUES
  ('marusa bobadilla', 'agent_manager_2'),
  ('patricia ferreiro', 'agent_paty'),
  ('gina prieto', 'agent_gina'),
  ('yolanda serrano', 'agent_yol')
ON CONFLICT (tag_normalized) DO NOTHING;
