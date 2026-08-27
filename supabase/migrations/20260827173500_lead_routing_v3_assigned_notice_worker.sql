-- V3 assigned-notice worker and callback reconciliation.
-- Assignment is already durable before this worker runs; notification failure
-- never rolls back or reassigns the opportunity.

CREATE OR REPLACE FUNCTION public.claim_v3_assigned_notices(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS SETOF public.lead_routing_delivery_attempts
LANGUAGE sql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
  WITH candidates AS (
    SELECT a.attempt_id
    FROM public.lead_routing_delivery_attempts a
    JOIN public.lead_routing_opportunities o
      ON o.opportunity_id = a.opportunity_id
    WHERE a.delivery_kind = 'assigned_notice'
      AND a.status = 'requested'
      AND a.provider_message_id IS NULL
      AND o.v3_enabled
      AND o.state = 'assigned'
      AND o.assigned_agent_id = a.target_agent_id
      AND (a.lease_expires_at IS NULL OR a.lease_expires_at <= p_now)
    ORDER BY a.requested_at, a.attempt_id
    FOR UPDATE OF a SKIP LOCKED
    LIMIT p_limit
  )
  UPDATE public.lead_routing_delivery_attempts a
  SET claimed_at = p_now,
      lease_expires_at = p_now + INTERVAL '2 minutes',
      lease_token = gen_random_uuid()::TEXT
  FROM candidates c
  WHERE a.attempt_id = c.attempt_id
  RETURNING a.*;
$$;

CREATE OR REPLACE FUNCTION public.release_v3_assigned_notice_failure(
  p_attempt_id BIGINT,
  p_lease_token TEXT,
  p_reason TEXT,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_attempt public.lead_routing_delivery_attempts;
  v_key TEXT;
BEGIN
  IF p_attempt_id IS NULL OR NULLIF(BTRIM(p_lease_token), '') IS NULL
     OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid assigned notice failure input';
  END IF;
  SELECT * INTO v_attempt
  FROM public.lead_routing_delivery_attempts
  WHERE attempt_id = p_attempt_id
  FOR UPDATE;
  IF NOT FOUND OR v_attempt.delivery_kind <> 'assigned_notice'
     OR v_attempt.status <> 'requested'
     OR v_attempt.provider_message_id IS NOT NULL
     OR v_attempt.lease_token IS DISTINCT FROM p_lease_token
     OR v_attempt.lease_expires_at <= p_now THEN
    RETURN FALSE;
  END IF;
  v_key := 'v3-assigned-notice-failed:' || p_attempt_id::TEXT || ':'
           || encode(extensions.digest(p_lease_token, 'sha256'), 'hex');
  INSERT INTO public.lead_routing_events(
    opportunity_id, event_type, actor_id, idempotency_key, external_evidence
  ) VALUES (
    v_attempt.opportunity_id, 'assigned_notice_failed', v_attempt.target_agent_id,
    v_key,
    jsonb_build_object('reason', LEFT(COALESCE(NULLIF(BTRIM(p_reason), ''), 'provider_send_failed'), 120))
  ) ON CONFLICT (idempotency_key) DO NOTHING;
  UPDATE public.lead_routing_delivery_attempts
  SET claimed_at = NULL,
      lease_token = NULL,
      lease_expires_at = p_now + INTERVAL '1 minute'
  WHERE attempt_id = p_attempt_id
    AND status = 'requested'
    AND provider_message_id IS NULL
    AND lease_token = p_lease_token;
  RETURN FOUND;
END;
$$;

-- Preserve the established offer behavior and add a separate terminal branch
-- for buttonless assigned notices. Assigned-notice callbacks never reopen or
-- otherwise mutate an already-assigned opportunity.
CREATE OR REPLACE FUNCTION public.reconcile_delivery_callback(p_provider_message_id TEXT)
RETURNS public.lead_routing_opportunities AS $$
DECLARE
  v_attempt public.lead_routing_delivery_attempts;
  v_cb public.lead_routing_delivery_callbacks;
  v_opp public.lead_routing_opportunities;
  v_event public.lead_routing_events;
BEGIN
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts
  WHERE provider_message_id = p_provider_message_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO v_cb FROM public.lead_routing_delivery_callbacks
  WHERE provider_message_id = p_provider_message_id
  ORDER BY CASE delivery_status WHEN 'delivered' THEN 3 WHEN 'failed' THEN 2 WHEN 'sent' THEN 1 END DESC,
           received_at DESC, callback_id DESC
  LIMIT 1;
  IF NOT FOUND OR v_cb.delivery_status = 'sent' THEN RETURN NULL; END IF;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id = v_attempt.opportunity_id FOR UPDATE;

  IF v_attempt.delivery_kind = 'assigned_notice' THEN
    IF v_cb.delivery_status = 'delivered' THEN
      INSERT INTO public.lead_routing_events(
        opportunity_id, event_type, actor_id, idempotency_key, external_evidence
      ) VALUES (
        v_attempt.opportunity_id, 'assigned_notice_delivered', v_attempt.target_agent_id,
        'v3-assigned-notice:' || p_provider_message_id || ':delivered', v_cb.evidence
      ) ON CONFLICT (idempotency_key) DO NOTHING;
      UPDATE public.lead_routing_delivery_attempts
      SET status = 'delivered', delivered_at = COALESCE(delivered_at, v_cb.received_at)
      WHERE attempt_id = v_attempt.attempt_id AND status <> 'delivered';
    ELSIF v_attempt.status <> 'delivered' THEN
      INSERT INTO public.lead_routing_events(
        opportunity_id, event_type, actor_id, idempotency_key, external_evidence
      ) VALUES (
        v_attempt.opportunity_id, 'assigned_notice_failed', v_attempt.target_agent_id,
        'v3-assigned-notice:' || p_provider_message_id || ':failed', v_cb.evidence
      ) ON CONFLICT (idempotency_key) DO NOTHING;
      UPDATE public.lead_routing_delivery_attempts
      SET status = 'failed', failed_at = COALESCE(failed_at, v_cb.received_at)
      WHERE attempt_id = v_attempt.attempt_id AND status <> 'delivered';
    END IF;
    UPDATE public.lead_routing_delivery_callbacks
    SET reconciled_at = NOW()
    WHERE provider_message_id = p_provider_message_id AND reconciled_at IS NULL;
    RETURN v_opp;
  END IF;

  IF v_opp.current_delivery_attempt_id IS DISTINCT FROM v_attempt.attempt_id
     OR v_opp.routing_tier IS DISTINCT FROM v_attempt.routing_tier
     OR v_opp.state IN ('assigned','unassigned_alerted','closed_won','closed_lost') THEN
    RETURN v_opp;
  END IF;
  IF v_cb.delivery_status = 'delivered' THEN
    INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,external_evidence)
    VALUES(v_attempt.opportunity_id,'delivery_confirmed',v_attempt.routing_tier,
      'delivery:'||p_provider_message_id||':delivered',v_cb.evidence)
    ON CONFLICT(idempotency_key) DO NOTHING;
    SELECT * INTO v_event FROM public.lead_routing_events
    WHERE idempotency_key='delivery:'||p_provider_message_id||':delivered';
    IF v_event.opportunity_id IS DISTINCT FROM v_attempt.opportunity_id
       OR v_event.event_type<>'delivery_confirmed'
       OR v_event.routing_tier IS DISTINCT FROM v_attempt.routing_tier THEN
      RAISE EXCEPTION 'delivery event collision';
    END IF;
    UPDATE public.lead_routing_delivery_attempts
    SET status='delivered',delivered_at=COALESCE(delivered_at,v_cb.received_at)
    WHERE attempt_id=v_attempt.attempt_id AND status<>'delivered';
    UPDATE public.lead_routing_opportunities
    SET state=CASE v_attempt.routing_tier WHEN 'owner' THEN 'owner_open'
          WHEN 'primary_guard' THEN 'primary_guard_open' ELSE 'backup_guard_open' END,
        delivery_status='delivered',delivered_at=COALESCE(delivered_at,v_cb.received_at),
        expires_at=COALESCE(expires_at,v_cb.received_at+INTERVAL '5 minutes'),updated_at=NOW()
    WHERE opportunity_id=v_attempt.opportunity_id AND delivered_at IS NULL;
  ELSIF v_attempt.status<>'delivered' AND v_opp.delivered_at IS NULL THEN
    INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,external_evidence)
    VALUES(v_attempt.opportunity_id,'delivery_failed',v_attempt.routing_tier,
      'delivery:'||p_provider_message_id||':failed',v_cb.evidence)
    ON CONFLICT(idempotency_key) DO NOTHING;
    SELECT * INTO v_event FROM public.lead_routing_events
    WHERE idempotency_key='delivery:'||p_provider_message_id||':failed';
    IF v_event.opportunity_id IS DISTINCT FROM v_attempt.opportunity_id
       OR v_event.event_type<>'delivery_failed'
       OR v_event.routing_tier IS DISTINCT FROM v_attempt.routing_tier THEN
      RAISE EXCEPTION 'delivery failure event collision';
    END IF;
    UPDATE public.lead_routing_delivery_attempts
    SET status='failed',failed_at=COALESCE(failed_at,v_cb.received_at)
    WHERE attempt_id=v_attempt.attempt_id;
    UPDATE public.lead_routing_opportunities
    SET delivery_status='failed',expires_at=NULL,updated_at=NOW()
    WHERE opportunity_id=v_attempt.opportunity_id AND delivered_at IS NULL;
    PERFORM public.fallback_failed_owner_delivery(v_attempt.attempt_id,'provider_delivery_failed');
  END IF;
  UPDATE public.lead_routing_delivery_callbacks SET reconciled_at=NOW()
  WHERE provider_message_id=p_provider_message_id AND reconciled_at IS NULL;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=v_attempt.opportunity_id;
  RETURN v_opp;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

REVOKE ALL ON FUNCTION public.claim_v3_assigned_notices(INTEGER,TIMESTAMPTZ),
  public.release_v3_assigned_notice_failure(BIGINT,TEXT,TEXT,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_v3_assigned_notices(INTEGER,TIMESTAMPTZ),
  public.release_v3_assigned_notice_failure(BIGINT,TEXT,TEXT,TIMESTAMPTZ)
  TO service_role;
