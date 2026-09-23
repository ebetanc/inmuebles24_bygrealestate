-- Keep the unassigned terminal closed when WF10 retries route dispatch.
CREATE OR REPLACE FUNCTION public.v3_route_ready_opportunity(p_opportunity_id bigint, p_capture_event_id bigint, p_property_tags text[] DEFAULT ARRAY[]::text[], p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_owner RECORD;
  v_guard RECORD;
  v_attempt_id BIGINT;
  v_owner_resolved BOOLEAN := FALSE;
  v_owner_agent_id TEXT;
  v_owner_number TEXT;
  v_guard_found BOOLEAN := FALSE;
  v_capture_status TEXT;
  v_capture_disposition TEXT;
  v_is_night BOOLEAN;
BEGIN
  IF NOT public.v3_day_allowed(p_capture_event_id,p_opportunity_id,NULL) THEN
    RETURN jsonb_build_object('state','blocked','reason','day_deadline_expired','opportunity_id',p_opportunity_id);
  END IF;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT v_opp.v3_enabled THEN RAISE EXCEPTION 'V3 opportunity unavailable'; END IF;
  SELECT e.contactado_status, e.disposition
    INTO v_capture_status, v_capture_disposition
  FROM public.i24_capture_events e
  WHERE e.capture_event_id=p_capture_event_id AND e.opportunity_id=p_opportunity_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'capture event does not belong to opportunity';
  END IF;
  IF v_capture_status IS DISTINCT FROM 'verified' THEN
    RETURN jsonb_build_object('state','blocked','reason','contactado_not_verified','opportunity_id',p_opportunity_id);
  END IF;
  IF v_capture_disposition <> 'created_new' THEN
    IF v_capture_disposition='active_duplicate' THEN
      RETURN jsonb_build_object('state','no_action','disposition','active_duplicate',
        'opportunity_id',p_opportunity_id,'capture_event_id',p_capture_event_id);
    END IF;
    IF v_capture_disposition='returning_assigned' THEN
      SELECT a.whatsapp_number INTO v_owner_number FROM public.agents a
      WHERE a.agent_id=v_opp.assigned_agent_id;
      v_attempt_id := public.v3_enqueue_assigned_notice(p_capture_event_id,
        v_opp.assigned_agent_id,v_owner_number);
      RETURN jsonb_build_object('state','direct_assigned','disposition','returning_assigned',
        'assigned_agent_id',v_opp.assigned_agent_id,'attempt_id',v_attempt_id,
        'capture_event_id',p_capture_event_id);
    END IF;
    RETURN jsonb_build_object('state','no_action','disposition',v_capture_disposition,
      'opportunity_id',p_opportunity_id);
  END IF;
  IF v_opp.state = 'unassigned' THEN
    RETURN jsonb_build_object('state','unassigned','opportunity_id',p_opportunity_id);
  END IF;
  v_is_night := ((p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '20:00:00'
    OR (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '08:00:00');
  IF v_is_night OR v_opp.state='queued_night' THEN
    UPDATE public.lead_routing_opportunities SET state='queued_night', v3_night_queued_at=COALESCE(v3_night_queued_at,p_now), updated_at=p_now
    WHERE opportunity_id=p_opportunity_id AND assigned_agent_id IS NULL;
    RETURN jsonb_build_object('state','night_queued','opportunity_id',p_opportunity_id,'release_at','08:05 America/Mexico_City');
  END IF;
  IF v_opp.assigned_agent_id IS NOT NULL OR v_opp.state IN ('closed_won','closed_lost') THEN
    RETURN jsonb_build_object('state',v_opp.state,'disposition','returning_assigned','opportunity_id',p_opportunity_id);
  END IF;

  IF v_opp.property_id IS NOT NULL AND COALESCE(CARDINALITY(p_property_tags),0)=1 THEN
    SELECT * INTO v_owner FROM public.resolve_first_property_tag(v_opp.property_id,p_property_tags) LIMIT 1;
    IF FOUND THEN
      v_owner_resolved := COALESCE(v_owner.resolved,FALSE);
      IF v_owner_resolved THEN
        v_owner_agent_id := v_owner.owner_agent_id;
        v_owner_number := v_owner.owner_number;
      END IF;
    END IF;
    -- The legacy resolver excludes managers, but the V3 contract explicitly
    -- permits Sandy as the owner when the unique property tag maps to her
    -- stable agent_id. Keep this exception exact and phone-validated.
    IF NOT v_owner_resolved THEN
      SELECT a.agent_id,
             regexp_replace(btrim(a.whatsapp_number), '[ +()-]', '', 'g')
        INTO v_owner_agent_id, v_owner_number
      FROM public.property_agent_alias alias
      JOIN public.agents a ON a.agent_id=alias.agent_id
      WHERE alias.tag_normalized=LOWER(BTRIM(p_property_tags[1]))
        AND a.agent_id='agent_manager' AND a.role='manager' AND a.is_available
        AND btrim(a.whatsapp_number) ~ '^[+]?[1-9][0-9 ()-]{6,13}[0-9]$'
        AND regexp_replace(btrim(a.whatsapp_number), '[ +()-]', '', 'g') ~ '^[1-9][0-9]{7,14}$';
      IF FOUND THEN v_owner_resolved := TRUE; END IF;
    END IF;
  END IF;
  IF v_owner_resolved THEN
    UPDATE public.lead_routing_opportunities SET state='resolved', routing_tier=NULL, updated_at=p_now
    WHERE opportunity_id=p_opportunity_id AND state IN ('captured','queued_night','resolved');
    v_attempt_id := public.v3_request_offer(p_capture_event_id,'owner',
      'v3:owner:'||p_opportunity_id::TEXT||':'||p_capture_event_id::TEXT,
      v_owner_agent_id,v_owner_number);
    RETURN jsonb_build_object('state','owner_delivery_requested','tier','owner','attempt_id',v_attempt_id,'opportunity_id',p_opportunity_id,'capture_event_id',p_capture_event_id);
  END IF;

  SELECT * INTO v_guard FROM public.get_guard_coverage_slots(
    (p_now AT TIME ZONE 'America/Mexico_City')::DATE,
    CASE
      WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '08:00:00'
       AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '14:00:00' THEN 'morning'
      WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '14:00:00'
       AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '20:00:00' THEN 'afternoon'
      ELSE 'night'
    END
  ) WHERE coverage_role='primary' LIMIT 1;
  v_guard_found := FOUND;
  IF NOT v_guard_found THEN
    PERFORM public.v3_mark_unassigned(p_opportunity_id,'guard_unavailable',p_capture_event_id,p_now);
    RETURN jsonb_build_object('state','unassigned','tier',NULL,'opportunity_id',p_opportunity_id);
  END IF;
  UPDATE public.lead_routing_opportunities SET state='guard_delivery_pending', routing_tier='primary_guard', updated_at=p_now
  WHERE opportunity_id=p_opportunity_id AND assigned_agent_id IS NULL;
  v_attempt_id := public.v3_request_offer(p_capture_event_id,'primary_guard',
    'v3:guard:'||p_opportunity_id::TEXT||':'||p_capture_event_id::TEXT,
    v_guard.agent_id,v_guard.whatsapp_number);
  RETURN jsonb_build_object('state','guard_delivery_requested','tier','primary_guard','attempt_id',v_attempt_id,'opportunity_id',p_opportunity_id,'capture_event_id',p_capture_event_id);
END;
$$;


-- Preserve new overnight leads while excluding pre-cutover and stale captures from automatic creation.
CREATE OR REPLACE FUNCTION public.claim_v3_easybroker_request_creations(p_limit integer DEFAULT 20, p_now timestamp with time zone DEFAULT now(), p_lease_duration interval DEFAULT '00:02:00'::interval)
 RETURNS TABLE(capture_event_id bigint, opportunity_id bigint, i24_lead_id text, property_public_id text, offer_context jsonb, normalized_email text, e164_phone text, correlation_window_start_at timestamp with time zone, correlation_horizon_at timestamp with time zone, remote_request_id bigint, lease_token uuid, lease_expires_at timestamp with time zone, post_allowed boolean)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $$
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
    AND public.v3_day_allowed(e.capture_event_id,NULL,NULL)
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
    WHERE public.v3_day_allowed(e.capture_event_id,NULL,NULL)
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
         l.lease_expires_at, l.post_attempt_count=0
  FROM claimed l
  JOIN public.i24_capture_events e ON e.capture_event_id=l.capture_event_id
  LEFT JOIN refreshed r ON r.capture_event_id=l.capture_event_id;
END;
$$;


