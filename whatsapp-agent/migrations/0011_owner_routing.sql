-- ============================================================================
-- 0011_owner_routing.sql -- Property-owner-first tiered lead routing
--
-- Replaces the competitive TOMO fan-out (route to all on-shift) with
-- owner-first routing: the asesor who owns a property gets the lead first,
-- then the guard auction, then the manager.
--
-- Adds:
--   1. property_agent_alias  -- EasyBroker tag -> agent_id mapping
--   2. seed of known aliases (spelling variants -> canonical agent)
--   3. resolve_agent_from_tags(text[]) -- tag array -> owner agent_id
--   4. conversations: owner_agent_id, routing_tier, tier_notified_at
--   5. claimed_via allows 'owner'
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. alias table: EasyBroker tag (lowercased, trimmed) -> agent_id
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS property_agent_alias (
  tag_normalized TEXT PRIMARY KEY,
  agent_id       TEXT NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE property_agent_alias IS
  'Maps EasyBroker property tag (lowercased, trimmed) -> agent_id for owner-first routing.';

ALTER TABLE property_agent_alias ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE tablename='property_agent_alias' AND policyname='alias_read') THEN
    CREATE POLICY alias_read ON property_agent_alias FOR SELECT USING (true);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. seed known aliases (tag spelling variants -> canonical agent)
--    NOTE: 'sandra'->Sandy and 'marusa'->Marusa are MANAGERS; real owner
--    tags should resolve to non-manager agents. Reconcile with BYG.
-- ---------------------------------------------------------------------------
INSERT INTO property_agent_alias (tag_normalized, agent_id) VALUES
  ('carol','agent_carol'),
  ('gina','agent_gina'),
  ('lupita','agent_lupita'),
  ('glozoya','agent_lupita'),
  ('marusa','agent_manager_2'),
  ('moni','agent_moni'),
  ('monica','agent_moni'),
  ('mónica','agent_moni'),
  ('paty','agent_paty'),
  ('patricia','agent_paty'),
  ('yol','agent_yol'),
  ('yolanda','agent_yol'),
  ('sandy','agent_manager'),
  ('sandra','agent_manager')
ON CONFLICT (tag_normalized) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. resolver: first agent matching any property tag, else NULL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION resolve_agent_from_tags(p_tags text[])
RETURNS text AS $$
  SELECT a.agent_id
  FROM unnest(p_tags) WITH ORDINALITY AS t(tag, ord)
  JOIN property_agent_alias al ON al.tag_normalized = lower(btrim(t.tag))
  JOIN agents a ON a.agent_id = al.agent_id
  ORDER BY t.ord
  LIMIT 1;
$$ LANGUAGE sql STABLE;
COMMENT ON FUNCTION resolve_agent_from_tags IS
  'Returns first agent_id matching any property tag via property_agent_alias, else NULL.';

-- ---------------------------------------------------------------------------
-- 4. conversations tier columns
-- ---------------------------------------------------------------------------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='conversations' AND column_name='owner_agent_id') THEN
    ALTER TABLE conversations ADD COLUMN owner_agent_id TEXT REFERENCES agents(agent_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='conversations' AND column_name='routing_tier') THEN
    ALTER TABLE conversations ADD COLUMN routing_tier TEXT
      CHECK (routing_tier IS NULL OR routing_tier IN ('owner','guard','manager'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='conversations' AND column_name='tier_notified_at') THEN
    ALTER TABLE conversations ADD COLUMN tier_notified_at TIMESTAMPTZ;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_conversations_tier_pending
  ON conversations(tier_notified_at)
  WHERE routing_tier IN ('owner','guard') AND assigned_agent_id IS NULL;

-- ---------------------------------------------------------------------------
-- 5. allow claimed_via='owner'
-- ---------------------------------------------------------------------------
DO $$ BEGIN
  ALTER TABLE conversations DROP CONSTRAINT IF EXISTS conversations_claimed_via_check;
  ALTER TABLE conversations ADD CONSTRAINT conversations_claimed_via_check
    CHECK (claimed_via IS NULL OR
           claimed_via IN ('tomo_auction','night_queue','manual','escalation','owner'));
END $$;
