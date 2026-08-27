-- V3 production hardening: claim only the current, still-unassigned offer.
-- The original 20260827154900 migration is immutable because it is already
-- applied in project wkaeutndwawkdhswisqe. This forward migration prevents a
-- stale delivery attempt from being leased or sent after assignment/rerouting.

CREATE OR REPLACE FUNCTION public.v3_claim_delivery_attempts(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS SETOF public.lead_routing_delivery_attempts
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  WITH candidates AS (
    SELECT a.attempt_id
    FROM public.lead_routing_delivery_attempts AS a
    JOIN public.lead_routing_opportunities AS o
      ON o.opportunity_id = a.opportunity_id
    WHERE p_limit BETWEEN 1 AND 200
      AND p_now IS NOT NULL
      AND a.delivery_kind = 'offer'
      AND a.status = 'requested'
      AND (a.lease_expires_at IS NULL OR a.lease_expires_at <= p_now)
      AND o.v3_enabled IS TRUE
      AND o.assigned_agent_id IS NULL
      AND o.current_delivery_attempt_id = a.attempt_id
      AND o.routing_tier = a.routing_tier
    ORDER BY a.requested_at, a.attempt_id
    LIMIT p_limit
    FOR UPDATE OF a SKIP LOCKED
  )
  UPDATE public.lead_routing_delivery_attempts AS a
  SET claimed_at = p_now,
      lease_expires_at = p_now + INTERVAL '2 minutes',
      lease_token = pg_catalog.gen_random_uuid()::TEXT
  FROM candidates AS c
  WHERE a.attempt_id = c.attempt_id
  RETURNING a.*;
$$;

REVOKE ALL ON FUNCTION public.v3_claim_delivery_attempts(INTEGER, TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v3_claim_delivery_attempts(INTEGER, TIMESTAMPTZ)
  TO service_role;
