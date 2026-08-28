-- Forward fix: qualify the ledger's unique conflict target by constraint.
-- This avoids PL/pgSQL output-column ambiguity for future installations.

CREATE OR REPLACE FUNCTION public.claim_v3_easybroker_request_creations(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW(),
  p_lease_duration INTERVAL DEFAULT INTERVAL '2 minutes'
) RETURNS TABLE(
  capture_event_id BIGINT,
  opportunity_id BIGINT,
  i24_lead_id TEXT,
  property_public_id TEXT,
  offer_context JSONB,
  normalized_email TEXT,
  e164_phone TEXT,
  correlation_window_start_at TIMESTAMPTZ,
  correlation_horizon_at TIMESTAMPTZ,
  remote_request_id BIGINT,
  lease_token UUID,
  lease_expires_at TIMESTAMPTZ,
  post_allowed BOOLEAN
)
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200
     OR p_now IS NULL OR p_lease_duration IS NULL
     OR p_lease_duration <= INTERVAL '0'
     OR p_lease_duration > INTERVAL '15 minutes' THEN
    RAISE EXCEPTION 'invalid EasyBroker creation lease input';
  END IF;

  INSERT INTO public.easybroker_contact_request_creation_ledger(
    capture_event_id, account_key, external_event_id, i24_lead_id,
    opportunity_id, property_public_id
  )
  SELECT e.capture_event_id, e.account_key, e.external_event_id,
         e.external_event_id, e.opportunity_id,
         UPPER(BTRIM(e.property_public_id))
  FROM public.i24_capture_events e
  JOIN public.lead_routing_opportunities o ON o.opportunity_id=e.opportunity_id
  JOIN public.agents a ON a.agent_id=o.assigned_agent_id
  WHERE (e.capture_event_id IN (107,108)
         OR e.happened_at >= TIMESTAMPTZ '2026-08-28T17:00:05.020Z')
    AND e.disposition='created_new'
    AND e.contactado_status='verified'
    AND e.route_dispatch_status='dispatched'
    AND o.v3_enabled
    AND o.state IN ('assigned','closed_won')
    AND o.assigned_agent_id IS NOT NULL
    AND NULLIF(BTRIM(a.name),'') IS NOT NULL
    AND NULLIF(BTRIM(e.property_public_id),'') IS NOT NULL
    AND UPPER(BTRIM(e.property_public_id)) ~ '^EB-[A-Z0-9]{4,}$'
    AND (e.normalized_email IS NOT NULL OR e.e164_phone IS NOT NULL)
    AND NULLIF(BTRIM(e.external_event_id),'') IS NOT NULL
    AND NULLIF(BTRIM(COALESCE(e.offer_context->>'name', e.offer_context->>'lead_name')),'') IS NOT NULL
  ON CONFLICT ON CONSTRAINT easybroker_creation_lead_uniq DO NOTHING;

  RETURN QUERY
  WITH candidates AS (
    SELECT l.capture_event_id
    FROM public.easybroker_contact_request_creation_ledger l
    JOIN public.i24_capture_events e ON e.capture_event_id=l.capture_event_id
    WHERE l.state IN ('pending','recovery')
      AND (l.lease_expires_at IS NULL OR l.lease_expires_at <= p_now)
    ORDER BY l.capture_event_id
    FOR UPDATE OF l SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    UPDATE public.easybroker_contact_request_creation_ledger l
    SET lease_token=gen_random_uuid(),
        lease_expires_at=p_now+p_lease_duration, updated_at=p_now
    FROM candidates c
    WHERE l.capture_event_id=c.capture_event_id
    RETURNING l.*
  )
  SELECT l.capture_event_id, l.opportunity_id, e.external_event_id,
         l.property_public_id, e.offer_context, e.normalized_email,
         e.e164_phone, e.correlation_window_start_at,
         e.correlation_horizon_at, l.remote_request_id, l.lease_token,
         l.lease_expires_at, l.post_attempt_count=0
  FROM claimed l
  JOIN public.i24_capture_events e ON e.capture_event_id=l.capture_event_id;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_v3_easybroker_request_creations(INTEGER,TIMESTAMPTZ,INTERVAL)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_v3_easybroker_request_creations(INTEGER,TIMESTAMPTZ,INTERVAL)
  TO service_role;
