-- 2026-10-16 (Marusa): "si es cliente es el mismo asesor, si es asesor va
-- cambiando". A person (same email or phone) that an agent took in the last 90
-- days goes straight to that agent with the lead_asignado_v3 notice, no offer.
-- Brokers come through EasyBroker's MLS and keep the normal offer per property.
-- BYG's own numbers (agents' phones) never count as a client.

-- ponytail: earliest assignment inside the 90-day window wins; a person taken
-- by two agents in the window stays with the first one.
CREATE OR REPLACE FUNCTION public.v3_returning_client_agent(p_opportunity_id bigint, p_now timestamptz DEFAULT now())
RETURNS TABLE(agent_id text, whatsapp_number text, previous_opportunity_id bigint)
LANGUAGE sql STABLE SET search_path TO 'pg_catalog','public' AS $$
  SELECT a.agent_id, a.whatsapp_number, prev.opportunity_id
  FROM public.lead_routing_opportunities o
  JOIN public.lead_routing_opportunities prev
    ON prev.v3_enabled AND prev.opportunity_id <> o.opportunity_id
   AND prev.assigned_agent_id IS NOT NULL
   AND prev.assigned_at >= p_now - INTERVAL '90 days' AND prev.assigned_at < p_now
   AND ((o.normalized_email IS NOT NULL AND prev.normalized_email = o.normalized_email)
     OR (o.e164_phone IS NOT NULL AND prev.e164_phone = o.e164_phone))
  JOIN public.agents a ON a.agent_id = prev.assigned_agent_id
   AND a.is_available AND NULLIF(BTRIM(a.whatsapp_number),'') IS NOT NULL
  WHERE o.opportunity_id = p_opportunity_id
    AND COALESCE(o.v3_offer_context->>'portal','') !~* '^\s*mls\s*$'
    AND NOT EXISTS (SELECT 1 FROM public.agents b
      WHERE NULLIF(BTRIM(b.whatsapp_number),'') IS NOT NULL AND o.e164_phone IS NOT NULL
        AND right(regexp_replace(b.whatsapp_number,'\D','','g'),10) = right(regexp_replace(o.e164_phone,'\D','','g'),10))
  ORDER BY prev.assigned_at, prev.opportunity_id
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.v3_returning_client_agent(bigint, timestamptz) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.v3_route_ready_opportunity(p_opportunity_id bigint, p_capture_event_id bigint, p_property_tags text[] DEFAULT ARRAY[]::text[], p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
  v_returning RECORD;
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

  -- Returning client (Marusa 16-oct): a portal lead from a person some agent
  -- already took in the last 90 days goes straight to that agent. MLS leads
  -- are other brokers and go through the normal offer.
  SELECT * INTO v_returning FROM public.v3_returning_client_agent(p_opportunity_id, p_now);
  IF FOUND THEN
    UPDATE public.lead_routing_opportunities
    SET state='assigned', routing_tier=NULL, assigned_agent_id=v_returning.agent_id,
        assigned_at=p_now, expires_at=NULL, updated_at=p_now,
        external_evidence=COALESCE(external_evidence,'{}'::JSONB)
          || jsonb_build_object('v3_final_route','returning_client','agent_id',v_returning.agent_id,
               'previous_opportunity_id',v_returning.previous_opportunity_id)
    WHERE opportunity_id=p_opportunity_id AND assigned_agent_id IS NULL;
    INSERT INTO public.lead_routing_events(opportunity_id,event_type,actor_id,idempotency_key,metadata)
    VALUES(p_opportunity_id,'returning_client_assigned',v_returning.agent_id,
      'v3-returning-client:'||p_opportunity_id::TEXT,
      jsonb_build_object('previous_opportunity_id',v_returning.previous_opportunity_id))
    ON CONFLICT (idempotency_key) DO NOTHING;
    v_attempt_id := public.v3_enqueue_assigned_notice(p_capture_event_id,v_returning.agent_id,v_returning.whatsapp_number);
    RETURN jsonb_build_object('state','direct_assigned','disposition','returning_client',
      'assigned_agent_id',v_returning.agent_id,'attempt_id',v_attempt_id,
      'opportunity_id',p_opportunity_id,'capture_event_id',p_capture_event_id);
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

  SELECT * INTO v_guard FROM public.v3_second_offer_target(NULL, p_now);
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
  UPDATE public.lead_routing_opportunities SET expires_at=public.v3_shared_deadline(p_capture_event_id)
  WHERE opportunity_id=p_opportunity_id AND assigned_agent_id IS NULL;
  RETURN jsonb_build_object('state','guard_delivery_requested','tier','primary_guard','attempt_id',v_attempt_id,'opportunity_id',p_opportunity_id,'capture_event_id',p_capture_event_id);
END;
$function$;
