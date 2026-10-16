-- 2026-10-16 (opp 1263, ~8/week): EasyBroker merges our POSTed request into a
-- contact it already had, so the request carries that contact's older email or
-- phone and correlation refused it as an identity contradiction. A request on
-- the same property that appears within [POST - 5 s, POST + 2 min] now needs
-- only one matching identifier. The claim exposes post_attempted_at so the Pi
-- applies the same rule before correlating.

CREATE OR REPLACE FUNCTION public.correlate_easybroker_request(p_exact_request_id bigint, p_i24_capture_event_id bigint, p_opportunity_id bigint, p_idempotency_key text, p_evidence jsonb, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  e public.i24_capture_events;
  q public.easybroker_contact_request_inbox;
  candidate BIGINT;
  candidates INTEGER;
  state TEXT;
  basis TEXT;
  v_post_at TIMESTAMPTZ;
BEGIN
  IF p_i24_capture_event_id IS NULL
     OR NULLIF(BTRIM(p_idempotency_key), '') IS NULL OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid capture correlation input';
  END IF;
  PERFORM pg_advisory_xact_lock(p_i24_capture_event_id);
  SELECT * INTO e FROM public.i24_capture_events
  WHERE capture_event_id = p_i24_capture_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'capture event not found'; END IF;

  IF p_opportunity_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.lead_routing_opportunities o
    WHERE o.opportunity_id = p_opportunity_id
      AND o.v3_enabled
      AND UPPER(NULLIF(BTRIM(o.property_id), '')) =
          UPPER(NULLIF(BTRIM(e.property_public_id), ''))
  ) THEN
    RAISE EXCEPTION 'contextual opportunity property mismatch';
  END IF;

  IF p_exact_request_id IS NULL THEN
    state := CASE WHEN NOT EXISTS (
      SELECT 1 FROM public.easybroker_ingestion_checkpoints cp
      WHERE cp.account_key = e.account_key AND cp.source = 'easybroker'
        AND cp.watermark_at >= e.correlation_horizon_at
    ) THEN 'awaiting_eb_request' ELSE 'manual_review:no_eb_request' END;
    UPDATE public.i24_capture_events
    SET correlation_state = state, correlation_reason = state, correlated_at = p_now
    WHERE capture_event_id = p_i24_capture_event_id;
    RETURN jsonb_build_object('ok', FALSE, 'state', state, 'correlated_at', p_now);
  END IF;

  SELECT * INTO q FROM public.easybroker_contact_request_inbox
  WHERE eb_request_id = p_exact_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'exact request not found'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.easybroker_i24_request_links l
    WHERE l.eb_request_id = p_exact_request_id
  ) THEN
    IF EXISTS (
      SELECT 1 FROM public.easybroker_i24_request_links l
      WHERE l.eb_request_id = p_exact_request_id
        AND l.i24_capture_event_id = p_i24_capture_event_id
        AND (p_opportunity_id IS NULL OR l.opportunity_id = p_opportunity_id)
    ) THEN
      UPDATE public.easybroker_contact_request_inbox
      SET correlation_state = 'already_linked', correlation_reason = 'already_linked',
          correlated_at = p_now
      WHERE eb_request_id = p_exact_request_id;
      UPDATE public.i24_capture_events
      SET correlation_state = 'already_linked', correlation_reason = 'already_linked',
          correlated_at = p_now
      WHERE capture_event_id = p_i24_capture_event_id;
      RETURN jsonb_build_object('ok', TRUE, 'state', 'already_linked',
        'correlated_at', p_now);
    END IF;
    UPDATE public.easybroker_contact_request_inbox
    SET correlation_state = 'conflict', correlation_reason = 'conflict', correlated_at = p_now
    WHERE eb_request_id = p_exact_request_id;
    UPDATE public.i24_capture_events
    SET correlation_state = 'conflict', correlation_reason = 'conflict', correlated_at = p_now
    WHERE capture_event_id = p_i24_capture_event_id;
    RETURN jsonb_build_object('ok', FALSE, 'state', 'conflict', 'correlated_at', p_now);
  END IF;

  SELECT l.post_attempted_at INTO v_post_at
  FROM public.easybroker_contact_request_creation_ledger l
  WHERE l.capture_event_id = p_i24_capture_event_id;

  SELECT COUNT(DISTINCT i.eb_request_id)::INTEGER, MIN(i.eb_request_id)
  INTO candidates, candidate
  FROM public.easybroker_contact_request_inbox i
  WHERE i.account_key = e.account_key
    AND UPPER(NULLIF(BTRIM(i.property_public_id), '')) =
        UPPER(NULLIF(BTRIM(e.property_public_id), ''))
    AND i.happened_at BETWEEN e.correlation_window_start_at AND e.correlation_horizon_at
    AND (
      (e.normalized_email IS NOT NULL AND i.normalized_email IS NOT NULL
       AND LOWER(BTRIM(e.normalized_email)) = LOWER(BTRIM(i.normalized_email)))
      OR
      (e.e164_phone IS NOT NULL AND i.e164_phone IS NOT NULL
       AND BTRIM(e.e164_phone) = BTRIM(i.e164_phone))
    )
    AND (NOT (
      (e.normalized_email IS NOT NULL AND i.normalized_email IS NOT NULL
       AND LOWER(BTRIM(e.normalized_email)) <> LOWER(BTRIM(i.normalized_email)))
      OR
      (e.e164_phone IS NOT NULL AND i.e164_phone IS NOT NULL
       AND BTRIM(e.e164_phone) <> BTRIM(i.e164_phone))
    )
    -- EB merged our POST into a contact it already had (other email/phone):
    -- the request shows up at our POST second, so one matching id is enough.
    OR i.happened_at BETWEEN v_post_at - INTERVAL '5 seconds' AND v_post_at + INTERVAL '2 minutes');

  IF candidates = 1 AND candidate = p_exact_request_id THEN
    basis := CASE
      WHEN LOWER(BTRIM(e.normalized_email)) = LOWER(BTRIM(q.normalized_email))
       AND BTRIM(e.e164_phone) = BTRIM(q.e164_phone) THEN 'email+phone'
      WHEN LOWER(BTRIM(e.normalized_email)) = LOWER(BTRIM(q.normalized_email)) THEN 'email'
      ELSE 'phone' END;
    INSERT INTO public.easybroker_i24_request_links(
      eb_request_id, i24_capture_event_id, opportunity_id, idempotency_key,
      evidence, match_basis, delta, linked_at
    ) VALUES (
      p_exact_request_id, p_i24_capture_event_id, p_opportunity_id,
      p_idempotency_key, COALESCE(p_evidence, '{}'::JSONB), basis, '{}'::JSONB, p_now
    );
    state := 'linked';
  ELSIF candidates > 1 THEN
    state := 'manual_review:ambiguous';
  ELSE
    state := 'manual_review:identity_contradiction';
  END IF;
  UPDATE public.easybroker_contact_request_inbox
  SET correlation_state = state, correlation_reason = state, correlated_at = p_now
  WHERE eb_request_id = p_exact_request_id;
  UPDATE public.i24_capture_events
  SET correlation_state = state, correlation_reason = state, correlated_at = p_now
  WHERE capture_event_id = p_i24_capture_event_id;
  RETURN jsonb_build_object('ok', state = 'linked', 'state', state,
    'eb_request_id', p_exact_request_id, 'opportunity_id', p_opportunity_id,
    'match_basis', basis, 'candidate_count', candidates, 'correlated_at', p_now);
EXCEPTION WHEN unique_violation THEN
  UPDATE public.easybroker_contact_request_inbox
  SET correlation_state = 'conflict', correlation_reason = 'unique_link_conflict',
      correlated_at = p_now
  WHERE eb_request_id = p_exact_request_id;
  UPDATE public.i24_capture_events
  SET correlation_state = 'conflict', correlation_reason = 'unique_link_conflict',
      correlated_at = p_now
  WHERE capture_event_id = p_i24_capture_event_id;
  RETURN jsonb_build_object('ok', FALSE, 'state', 'conflict',
    'eb_request_id', p_exact_request_id, 'candidate_count', candidates,
    'correlated_at', p_now);
END;
$function$;

DROP FUNCTION public.claim_v3_easybroker_request_creations(integer, timestamptz, interval);
CREATE OR REPLACE FUNCTION public.claim_v3_easybroker_request_creations(p_limit integer DEFAULT 20, p_now timestamp with time zone DEFAULT now(), p_lease_duration interval DEFAULT '00:02:00'::interval)
 RETURNS TABLE(capture_event_id bigint, opportunity_id bigint, i24_lead_id text, property_public_id text, offer_context jsonb, normalized_email text, e164_phone text, correlation_window_start_at timestamp with time zone, correlation_horizon_at timestamp with time zone, remote_request_id bigint, lease_token uuid, lease_expires_at timestamp with time zone, post_allowed boolean, post_attempted_at timestamp with time zone)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
  LEFT JOIN public.agents a ON a.agent_id=o.assigned_agent_id
  WHERE (e.capture_event_id IN (107,108)
         OR e.happened_at >= TIMESTAMPTZ '2026-08-28T17:00:05.020Z')
    AND public.v3_day_not_held(e.capture_event_id,NULL,NULL)
    AND e.happened_at >= p_now - INTERVAL '24 hours'
    AND e.happened_at >= TIMESTAMPTZ '2026-09-23T02:00:00Z'
    AND e.disposition='created_new'
    AND e.contactado_status='verified'
    AND e.route_dispatch_status='dispatched'
    AND o.v3_enabled
    AND (
      (o.state IN ('assigned','closed_won')
       AND o.assigned_agent_id IS NOT NULL
       AND NULLIF(BTRIM(a.name),'') IS NOT NULL)
      OR (o.state='unassigned' AND o.assigned_agent_id IS NULL)
    )
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
    WHERE public.v3_day_not_held(e.capture_event_id,NULL,NULL)
      AND e.happened_at >= p_now - INTERVAL '24 hours'
      AND e.happened_at >= TIMESTAMPTZ '2026-09-23T02:00:00Z'
      AND l.state IN ('pending','recovery')
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
  ), refreshed AS (
    -- easybroker_creation_claim_window_v1
    -- Only a never-posted claim receives a fresh bounded window. Recovery
    -- claims after the one allowed POST cannot extend the horizon forever.
    UPDATE public.i24_capture_events e
    SET correlation_window_start_at=LEAST(
          COALESCE(e.correlation_window_start_at,p_now-INTERVAL '5 minutes'),
          p_now-INTERVAL '5 minutes'
        ),
        correlation_horizon_at=GREATEST(
          COALESCE(e.correlation_horizon_at,p_now+INTERVAL '24 hours'),
          p_now+INTERVAL '24 hours'
        )
    FROM claimed l
    WHERE e.capture_event_id=l.capture_event_id
      AND l.post_attempt_count=0
    RETURNING e.capture_event_id, e.correlation_window_start_at,
              e.correlation_horizon_at
  )
  SELECT l.capture_event_id, l.opportunity_id, e.external_event_id,
         l.property_public_id, e.offer_context, e.normalized_email,
         e.e164_phone,
         COALESCE(r.correlation_window_start_at,e.correlation_window_start_at),
         COALESCE(r.correlation_horizon_at,e.correlation_horizon_at),
         l.remote_request_id, l.lease_token,
         l.lease_expires_at, l.post_attempt_count=0, l.post_attempted_at
  FROM claimed l
  JOIN public.i24_capture_events e ON e.capture_event_id=l.capture_event_id
  LEFT JOIN refreshed r ON r.capture_event_id=l.capture_event_id;
END;
$function$;
REVOKE ALL ON FUNCTION public.claim_v3_easybroker_request_creations(integer, timestamptz, interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_v3_easybroker_request_creations(integer, timestamptz, interval) TO service_role;
NOTIFY pgrst, 'reload schema';
