-- 0035_unassigned_alert_effect_lease.sql
-- Atomic single-flight lease for WF3c WhatsApp unassigned alerts.
-- Rollback (maintenance window only):
--   DROP FUNCTION IF EXISTS public.complete_unassigned_alert_delivery(BIGINT, UUID, TEXT);
--   DROP FUNCTION IF EXISTS public.claim_unassigned_alerts(INTEGER, TIMESTAMPTZ, INTERVAL);
--   DROP INDEX IF EXISTS public.routing_v2_unassigned_alerts_claimable_idx;
--   ALTER TABLE public.routing_v2_unassigned_alerts
--     DROP COLUMN IF EXISTS attempts,
--     DROP COLUMN IF EXISTS lease_expires_at,
--     DROP COLUMN IF EXISTS lease_token;

ALTER TABLE public.routing_v2_unassigned_alerts
  ADD COLUMN IF NOT EXISTS lease_token UUID,
  ADD COLUMN IF NOT EXISTS lease_expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS attempts INTEGER NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS routing_v2_unassigned_alerts_claimable_idx
  ON public.routing_v2_unassigned_alerts (acknowledged, lease_expires_at, first_alerted_at, alert_id)
  WHERE NOT acknowledged;

CREATE OR REPLACE FUNCTION public.claim_unassigned_alerts(
  p_limit INTEGER DEFAULT 100,
  p_now TIMESTAMPTZ DEFAULT NOW(),
  p_lease_duration INTERVAL DEFAULT INTERVAL '2 minutes'
) RETURNS TABLE (
  alert_id BIGINT,
  opportunity_id BIGINT,
  property_id TEXT,
  lease_token UUID,
  lease_expires_at TIMESTAMPTZ,
  attempts INTEGER
) AS $$
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN
    RAISE EXCEPTION 'alert claim limit must be between 1 and 500';
  END IF;
  IF p_now IS NULL OR p_lease_duration IS NULL
     OR p_lease_duration <= INTERVAL '0 seconds'
     OR p_lease_duration > INTERVAL '15 minutes' THEN
    RAISE EXCEPTION 'invalid alert lease';
  END IF;

  RETURN QUERY
  WITH candidates AS MATERIALIZED (
    SELECT a.alert_id
    FROM public.routing_v2_unassigned_alerts a
    JOIN public.lead_routing_opportunities o USING (opportunity_id)
    WHERE NOT a.acknowledged
      AND (a.lease_token IS NULL OR a.lease_expires_at <= p_now)
      AND o.state = 'unassigned_alerted'
      AND o.assigned_agent_id IS NULL
    ORDER BY a.first_alerted_at, a.alert_id
    FOR UPDATE OF a SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    UPDATE public.routing_v2_unassigned_alerts a
    SET lease_token = gen_random_uuid(),
        lease_expires_at = p_now + p_lease_duration,
        attempts = a.attempts + 1
    FROM candidates c
    WHERE a.alert_id = c.alert_id
    RETURNING a.alert_id, a.opportunity_id, a.lease_token,
      a.lease_expires_at, a.attempts
  )
  SELECT c.alert_id, c.opportunity_id, o.property_id, c.lease_token,
    c.lease_expires_at, c.attempts
  FROM claimed c
  JOIN public.lead_routing_opportunities o USING (opportunity_id)
  ORDER BY c.alert_id;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public, extensions;

CREATE OR REPLACE FUNCTION public.complete_unassigned_alert_delivery(
  p_opportunity_id BIGINT,
  p_lease_token UUID,
  p_provider_message_id TEXT
) RETURNS public.routing_v2_unassigned_alerts AS $$
DECLARE
  v_row public.routing_v2_unassigned_alerts;
BEGIN
  IF p_opportunity_id IS NULL OR p_lease_token IS NULL
     OR NULLIF(btrim(p_provider_message_id), '') IS NULL THEN
    RAISE EXCEPTION 'invalid unassigned alert delivery evidence';
  END IF;

  UPDATE public.routing_v2_unassigned_alerts
  SET acknowledged = TRUE,
      acknowledged_at = NOW(),
      acknowledged_by = 'wf3c:whatsapp:' || p_provider_message_id,
      lease_token = NULL,
      lease_expires_at = NULL
  WHERE opportunity_id = p_opportunity_id
    AND NOT acknowledged
    AND lease_token = p_lease_token
    AND lease_expires_at > NOW()
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'stale or missing unassigned alert lease: %', p_opportunity_id;
  END IF;
  RETURN v_row;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.claim_unassigned_alerts(INTEGER, TIMESTAMPTZ, INTERVAL)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_unassigned_alerts(INTEGER, TIMESTAMPTZ, INTERVAL)
  TO service_role;
REVOKE ALL ON FUNCTION public.complete_unassigned_alert_delivery(BIGINT, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_unassigned_alert_delivery(BIGINT, UUID, TEXT)
  TO service_role;
