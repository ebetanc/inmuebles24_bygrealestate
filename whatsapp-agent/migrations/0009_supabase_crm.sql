-- ============================================================================
-- 0009_supabase_crm.sql -- Supabase as authoritative CRM (replaces EasyBroker routing)
--
-- Rationale: BYG client uses ONE shared EasyBroker login for 5 agents,
-- so EasyBroker cannot route leads per-agent. Move CRM functions to
-- Supabase + dashboard. EasyBroker becomes ledger-only.
--
-- Changes:
--   1. Add assignment_method, assigned_at, first_response_at, claimed_via to conversations
--   2. Create lead_status table (current pipeline stage per lead)
--   3. Create lead_status_history table (auditable stage transitions)
--   4. Create agent_metrics view (SLA + conversion per agent)
--   5. Create sla_breaches view (leads sin respuesta > 15 min)
--   6. RLS on new tables
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. New columns on conversations
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='conversations' AND column_name='assignment_method') THEN
    ALTER TABLE conversations
      ADD COLUMN assignment_method TEXT DEFAULT 'whatsapp_number'
        CHECK (assignment_method IN ('whatsapp_number','manual','easybroker_legacy'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='conversations' AND column_name='assigned_at') THEN
    ALTER TABLE conversations ADD COLUMN assigned_at TIMESTAMPTZ;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='conversations' AND column_name='first_response_at') THEN
    ALTER TABLE conversations ADD COLUMN first_response_at TIMESTAMPTZ;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name='conversations' AND column_name='claimed_via') THEN
    ALTER TABLE conversations ADD COLUMN claimed_via TEXT
      CHECK (claimed_via IS NULL OR claimed_via IN ('tomo_auction','night_queue','manual','escalation'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_conversations_assigned_at
  ON conversations(assigned_at) WHERE assigned_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_conversations_sla_pending
  ON conversations(assigned_at)
  WHERE first_response_at IS NULL AND assigned_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. lead_status (current pipeline stage)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lead_status (
  conversation_id   UUID PRIMARY KEY REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  stage             TEXT NOT NULL DEFAULT 'new'
    CHECK (stage IN ('new','contacted','qualified','visit_scheduled','offer','closed_won','closed_lost')),
  stage_changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  notes             TEXT,
  next_action       TEXT,
  next_action_at    TIMESTAMPTZ,
  updated_by        TEXT REFERENCES agents(agent_id),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE lead_status IS
  'Current CRM pipeline stage per lead. Replaces EasyBroker for assignment tracking.';

CREATE INDEX IF NOT EXISTS idx_lead_status_stage ON lead_status(stage);
CREATE INDEX IF NOT EXISTS idx_lead_status_next_action
  ON lead_status(next_action_at) WHERE next_action_at IS NOT NULL;

ALTER TABLE lead_status ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 3. lead_status_history (auditable transitions)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lead_status_history (
  id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id  UUID NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  from_stage       TEXT,
  to_stage         TEXT NOT NULL,
  changed_by       TEXT REFERENCES agents(agent_id),
  changed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  note             TEXT
);

COMMENT ON TABLE lead_status_history IS
  'Append-only audit log of all stage transitions.';

CREATE INDEX IF NOT EXISTS idx_lead_status_history_conv
  ON lead_status_history(conversation_id, changed_at DESC);

ALTER TABLE lead_status_history ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 4. Trigger: write history row + bump updated_at on lead_status changes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lead_status_log_change()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO lead_status_history (conversation_id, from_stage, to_stage, changed_by, note)
    VALUES (NEW.conversation_id, NULL, NEW.stage, NEW.updated_by, NEW.notes);
    NEW.stage_changed_at := NOW();
    NEW.updated_at := NOW();
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' AND OLD.stage IS DISTINCT FROM NEW.stage THEN
    INSERT INTO lead_status_history (conversation_id, from_stage, to_stage, changed_by, note)
    VALUES (NEW.conversation_id, OLD.stage, NEW.stage, NEW.updated_by, NEW.notes);
    NEW.stage_changed_at := NOW();
  END IF;
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_lead_status_history ON lead_status;
CREATE TRIGGER trg_lead_status_history
  BEFORE INSERT OR UPDATE ON lead_status
  FOR EACH ROW EXECUTE FUNCTION lead_status_log_change();

-- ---------------------------------------------------------------------------
-- 5. RPC: update stage atomically from dashboard
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_lead_stage(
  p_conversation_id UUID,
  p_stage           TEXT,
  p_agent_id        TEXT,
  p_note            TEXT DEFAULT NULL,
  p_next_action     TEXT DEFAULT NULL,
  p_next_action_at  TIMESTAMPTZ DEFAULT NULL
) RETURNS lead_status AS $$
DECLARE
  v_row lead_status;
BEGIN
  INSERT INTO lead_status (conversation_id, stage, updated_by, notes, next_action, next_action_at)
  VALUES (p_conversation_id, p_stage, p_agent_id, p_note, p_next_action, p_next_action_at)
  ON CONFLICT (conversation_id) DO UPDATE
    SET stage = EXCLUDED.stage,
        notes = COALESCE(EXCLUDED.notes, lead_status.notes),
        next_action = COALESCE(EXCLUDED.next_action, lead_status.next_action),
        next_action_at = COALESCE(EXCLUDED.next_action_at, lead_status.next_action_at),
        updated_by = EXCLUDED.updated_by
  RETURNING * INTO v_row;
  RETURN v_row;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION update_lead_stage IS
  'Atomic stage update used by dashboard. Trigger writes history automatically.';

-- ---------------------------------------------------------------------------
-- 6. View: agent_metrics
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW agent_metrics AS
SELECT
  a.agent_id,
  a.name,
  COUNT(c.conversation_id) FILTER (
    WHERE c.assigned_at >= NOW() - INTERVAL '30 days'
  ) AS leads_30d,
  COUNT(c.conversation_id) FILTER (
    WHERE c.assigned_at >= NOW() - INTERVAL '7 days'
  ) AS leads_7d,
  AVG(EXTRACT(EPOCH FROM (c.first_response_at - c.assigned_at)))
    FILTER (WHERE c.first_response_at IS NOT NULL
            AND c.assigned_at >= NOW() - INTERVAL '30 days') AS avg_response_sec_30d,
  COUNT(*) FILTER (WHERE ls.stage = 'visit_scheduled') AS visits_scheduled,
  COUNT(*) FILTER (WHERE ls.stage = 'closed_won')      AS closed_won,
  COUNT(*) FILTER (WHERE ls.stage = 'closed_lost')     AS closed_lost,
  COUNT(*) FILTER (
    WHERE c.first_response_at IS NULL
      AND c.assigned_at < NOW() - INTERVAL '15 minutes'
      AND COALESCE(ls.stage,'new') NOT IN ('closed_won','closed_lost')
  ) AS sla_breaches
FROM agents a
LEFT JOIN conversations c ON c.assigned_agent_id = a.agent_id
LEFT JOIN lead_status   ls ON ls.conversation_id = c.conversation_id
GROUP BY a.agent_id, a.name;

COMMENT ON VIEW agent_metrics IS
  'Per-agent KPIs: leads volume, avg response time, pipeline outcomes, SLA breaches.';

-- ---------------------------------------------------------------------------
-- 7. View: sla_breaches (current breaches, for WF11 + dashboard widget)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW sla_breaches AS
SELECT
  c.conversation_id,
  c.lead_name,
  c.lead_phone,
  c.assigned_agent_id,
  a.name AS agent_name,
  c.assigned_at,
  EXTRACT(EPOCH FROM (NOW() - c.assigned_at))::INT AS pending_seconds,
  COALESCE(ls.stage, 'new') AS stage
FROM conversations c
LEFT JOIN agents a       ON a.agent_id = c.assigned_agent_id
LEFT JOIN lead_status ls ON ls.conversation_id = c.conversation_id
WHERE c.first_response_at IS NULL
  AND c.assigned_at IS NOT NULL
  AND c.assigned_at < NOW() - INTERVAL '15 minutes'
  AND COALESCE(ls.stage,'new') NOT IN ('closed_won','closed_lost');

COMMENT ON VIEW sla_breaches IS
  'Leads with no agent reply > 15 min since assignment. Used by WF11 SLA monitor.';

-- ---------------------------------------------------------------------------
-- 8. RLS policies (read for authenticated, write via service_role / RPC only)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='lead_status' AND policyname='lead_status_read') THEN
    CREATE POLICY lead_status_read ON lead_status FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='lead_status_history' AND policyname='lead_status_history_read') THEN
    CREATE POLICY lead_status_history_read ON lead_status_history FOR SELECT USING (true);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 9. Backfill lead_status for existing conversations
-- ---------------------------------------------------------------------------
INSERT INTO lead_status (conversation_id, stage, updated_by)
SELECT c.conversation_id,
       CASE
         WHEN c.mode = 'human' THEN 'contacted'
         WHEN c.mode = 'ai'    THEN 'new'
         ELSE 'new'
       END,
       c.assigned_agent_id
FROM conversations c
ON CONFLICT (conversation_id) DO NOTHING;
