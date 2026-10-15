-- 2026-10-15 (Marusa, 13/14-oct): the owner keeps 5 exclusive minutes; then the
-- owner AND the guard share the offer until minute 65 (first Tomo wins). If the
-- guard is missing or is the owner herself, Sandy is the second recipient.
-- Nobody takes it by minute 65 -> Sandy (Mon-Fri 09:00-18:00 CDMX) or the BYG
-- phone (Marusa, agent_manager_2) any other time. Replaces 'unassigned' from
-- 20260912100000 for the timeout paths.
-- Also: a typed "tomo" (no button) claims the sender's single open offer.

-- Shared deadline: first offer request of this capture + 65 min.
CREATE OR REPLACE FUNCTION public.v3_shared_deadline(p_capture_event_id bigint)
RETURNS timestamptz LANGUAGE sql STABLE SET search_path TO 'pg_catalog','public' AS $$
  SELECT min(a.requested_at) + INTERVAL '65 minutes'
  FROM public.lead_routing_delivery_attempts a
  WHERE a.capture_event_id = p_capture_event_id
    AND a.delivery_kind = 'offer' AND a.routing_tier IN ('owner','primary_guard');
$$;

-- Who gets the lead nobody took: Sandy on weekdays 09:00-18:00 CDMX, else BYG phone (Marusa).
CREATE OR REPLACE FUNCTION public.v3_fallback_agent(p_now timestamptz)
RETURNS text LANGUAGE sql STABLE SET search_path TO 'pg_catalog','public' AS $$
  SELECT CASE
    WHEN EXTRACT(ISODOW FROM p_now AT TIME ZONE 'America/Mexico_City') BETWEEN 1 AND 5
     AND (p_now AT TIME ZONE 'America/Mexico_City')::time >= TIME '09:00'
     AND (p_now AT TIME ZONE 'America/Mexico_City')::time <  TIME '18:00'
    THEN 'agent_manager' ELSE 'agent_manager_2' END;
$$;

-- Second recipient at minute 5: the shift guard, or Sandy when there is no
-- guard or the guard is the owner. NULL when Sandy is that owner too.
CREATE OR REPLACE FUNCTION public.v3_second_offer_target(p_owner_agent_id text, p_now timestamptz)
RETURNS TABLE(agent_id text, whatsapp_number text) LANGUAGE plpgsql STABLE
SET search_path TO 'pg_catalog','public' AS $$
BEGIN
  RETURN QUERY SELECT g.agent_id, g.whatsapp_number FROM public.get_guard_coverage_slots(
    (p_now AT TIME ZONE 'America/Mexico_City')::DATE,
    CASE
      WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '08:00:00'
       AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '14:00:00' THEN 'morning'
      WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '14:00:00'
       AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '20:00:00' THEN 'afternoon'
      ELSE 'night'
    END) g
  WHERE g.coverage_role='primary' AND g.agent_id IS DISTINCT FROM p_owner_agent_id
  LIMIT 1;
  IF FOUND THEN RETURN; END IF;
  RETURN QUERY SELECT a.agent_id, a.whatsapp_number FROM public.agents a
  WHERE a.agent_id='agent_manager' AND a.is_available
    AND NULLIF(BTRIM(a.whatsapp_number),'') IS NOT NULL
    AND a.agent_id IS DISTINCT FROM p_owner_agent_id;
END $$;

-- v3_assign_sandy generalised to any manager/owner (Sandy or BYG phone).
CREATE OR REPLACE FUNCTION public.v3_assign_manager(p_opportunity_id bigint, p_agent_id text, p_reason text,
  p_capture_event_id bigint DEFAULT NULL, p_now timestamptz DEFAULT now())
RETURNS public.lead_routing_opportunities LANGUAGE plpgsql SET search_path TO 'pg_catalog','public' AS $$
DECLARE v_opp public.lead_routing_opportunities; v_agent public.agents;
BEGIN
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT v_opp.v3_enabled THEN RAISE EXCEPTION 'V3 opportunity unavailable'; END IF;
  SELECT * INTO v_agent FROM public.agents WHERE agent_id=p_agent_id AND role IN ('manager','owner');
  IF NOT FOUND THEN RAISE EXCEPTION 'fallback agent % unavailable', p_agent_id; END IF;
  IF v_opp.assigned_agent_id IS NULL AND v_opp.state NOT IN ('unassigned','closed_won','closed_lost') THEN
    UPDATE public.lead_routing_opportunities
    SET state='assigned', routing_tier=NULL, assigned_agent_id=v_agent.agent_id,
        assigned_at=COALESCE(assigned_at,p_now), expires_at=NULL, updated_at=p_now,
        external_evidence=COALESCE(external_evidence,'{}'::JSONB)
          || jsonb_build_object('v3_final_route','manager_fallback','agent_id',v_agent.agent_id,
               'reason',LEFT(COALESCE(p_reason,'fallback'),120))
    WHERE opportunity_id=p_opportunity_id AND assigned_agent_id IS NULL
    RETURNING * INTO v_opp;
    IF v_opp.conversation_id IS NOT NULL THEN
      UPDATE public.conversations SET assigned_agent_id=v_agent.agent_id,
        assigned_at=COALESCE(assigned_at,p_now), assignment_method='manager_escalation',
        claimed_via='v3_manager_fallback', routing_tier='manager', mode='ai'
      WHERE conversation_id=v_opp.conversation_id AND assigned_agent_id IS NULL;
    END IF;
    INSERT INTO public.lead_routing_events(opportunity_id,event_type,actor_id,idempotency_key,metadata)
    VALUES(p_opportunity_id,'manager_assigned',v_agent.agent_id,
      'v3-sandy-assigned:'||p_opportunity_id::TEXT,
      jsonb_build_object('reason',LEFT(COALESCE(p_reason,'fallback'),120)))
    ON CONFLICT (idempotency_key) DO NOTHING;
    IF p_capture_event_id IS NOT NULL THEN
      PERFORM public.v3_enqueue_assigned_notice(p_capture_event_id,v_agent.agent_id,v_agent.whatsapp_number);
    END IF;
  END IF;
  RETURN v_opp;
END $$;

CREATE OR REPLACE FUNCTION public.v3_advance_routing_tier(p_opportunity_id bigint, p_expected_tier text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_attempt public.lead_routing_delivery_attempts;
  v_second RECORD;
  v_attempt_id BIGINT;
  v_pending_claim JSONB;
  v_deadline TIMESTAMPTZ;
  v_fallback TEXT;
BEGIN
  IF NOT public.v3_day_allowed(NULL,p_opportunity_id,NULL) THEN
    RETURN jsonb_build_object('state','day_deadline_expired','opportunity_id',p_opportunity_id);
  END IF;
  IF p_expected_tier NOT IN ('owner','primary_guard') OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid V3 routing transition';
  END IF;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=p_opportunity_id FOR UPDATE;
  -- 'unassigned' is terminal: never re-process a lead nobody took.
  IF NOT FOUND OR NOT v_opp.v3_enabled OR v_opp.assigned_agent_id IS NOT NULL
     OR v_opp.state='unassigned' THEN
    RETURN jsonb_build_object('state',COALESCE(v_opp.state,'missing'),'opportunity_id',p_opportunity_id);
  END IF;
  IF v_opp.current_delivery_attempt_id IS NOT NULL THEN
    SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts
    WHERE attempt_id=v_opp.current_delivery_attempt_id FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('state','missing_delivery_attempt','opportunity_id',p_opportunity_id);
    END IF;
  ELSE
    RETURN jsonb_build_object('state','missing_delivery_attempt','opportunity_id',p_opportunity_id);
  END IF;
  IF v_attempt.capture_event_id IS NULL THEN
    RETURN jsonb_build_object('state','missing_capture_context','opportunity_id',p_opportunity_id);
  END IF;
  v_deadline := public.v3_shared_deadline(v_attempt.capture_event_id);
  IF v_attempt.delivered_at IS NOT NULL THEN
    IF v_opp.expires_at IS NULL THEN
      v_opp.expires_at := CASE WHEN v_attempt.routing_tier='owner'
        THEN v_attempt.delivered_at+INTERVAL '5 minutes' ELSE v_deadline END;
      UPDATE public.lead_routing_opportunities SET expires_at=v_opp.expires_at, updated_at=p_now
      WHERE opportunity_id=p_opportunity_id AND expires_at IS NULL;
    END IF;
    IF v_opp.expires_at>p_now THEN
      RETURN jsonb_build_object('state','open','opportunity_id',p_opportunity_id);
    END IF;
  END IF;
  IF v_attempt.delivered_at IS NULL
     AND COALESCE(v_attempt.provider_accepted_at,v_attempt.requested_at)
         +INTERVAL '2 minutes'>p_now THEN
    RETURN jsonb_build_object('state','awaiting_delivery_timeout','opportunity_id',p_opportunity_id);
  END IF;

  v_pending_claim := public.claim_pending_v3_webhook_for_attempt(
    p_opportunity_id,
    v_attempt.attempt_id
  );
  IF v_pending_claim->>'outcome' IN ('claimed', 'already_assigned') THEN
    RETURN jsonb_build_object(
      'state', 'assigned',
      'tier', 'verified_claim',
      'opportunity_id', p_opportunity_id,
      'attempt_id', v_attempt.attempt_id,
      'capture_event_id', v_attempt.capture_event_id,
      'assigned_agent_id', v_pending_claim->>'assigned_agent_id',
      'webhook_event_id', v_pending_claim->>'webhook_event_id'
    );
  END IF;

  -- Minute 65: nobody took it.
  IF p_now >= v_deadline THEN
    v_fallback := public.v3_fallback_agent(p_now);
    PERFORM public.v3_assign_manager(p_opportunity_id, v_fallback, 'shared_window_expired',
      v_attempt.capture_event_id, p_now);
    RETURN jsonb_build_object('state','assigned','tier','manager_fallback',
      'opportunity_id',p_opportunity_id,'assigned_agent_id',v_fallback,
      'capture_event_id',v_attempt.capture_event_id);
  END IF;

  -- Minute 5: owner's exclusive window is over; add the second recipient
  -- without closing the owner's offer (both claimable until v_deadline).
  IF p_expected_tier='owner' AND v_opp.routing_tier='owner' THEN
    SELECT * INTO v_second FROM public.v3_second_offer_target(v_attempt.target_agent_id, p_now);
    IF FOUND THEN
      UPDATE public.lead_routing_opportunities
      SET state='guard_delivery_pending',routing_tier='primary_guard',delivery_status=NULL,
          current_delivery_attempt_id=NULL,delivered_at=NULL,expires_at=v_deadline,updated_at=p_now
      WHERE opportunity_id=p_opportunity_id;
      v_attempt_id := public.v3_request_offer(
        v_attempt.capture_event_id,
        'primary_guard',
        'v3:guard:'||p_opportunity_id::TEXT||':'||v_attempt.capture_event_id::TEXT,
        v_second.agent_id,
        v_second.whatsapp_number
      );
      RETURN jsonb_build_object(
        'state','guard_delivery_requested','tier','primary_guard',
        'attempt_id',v_attempt_id,'opportunity_id',p_opportunity_id,
        'capture_event_id',v_attempt.capture_event_id
      );
    END IF;
  END IF;

  -- No second recipient, or the guard offer was not delivered: keep the open
  -- offer(s) claimable until minute 65.
  UPDATE public.lead_routing_opportunities SET expires_at=v_deadline, updated_at=p_now
  WHERE opportunity_id=p_opportunity_id;
  RETURN jsonb_build_object('state','open','opportunity_id',p_opportunity_id);
END;
$function$;

-- Guard-first leads (no owner): second-recipient rule + shared hour.
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

-- Claim: any open offer of the current capture (owner's stays claimable after
-- minute 5), deadline = shared hour.
CREATE OR REPLACE FUNCTION public.claim_v3_delivery(p_opportunity_id bigint, p_attempt_id bigint, p_capture_event_id bigint, p_sender_agent_id text, p_sender_number text, p_reply_to_wamid text DEFAULT NULL::text, p_context_wamid text DEFAULT NULL::text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_attempt public.lead_routing_delivery_attempts;
  v_agent public.agents;
  v_capture public.i24_capture_events;
  v_conversation_assigned_agent_id TEXT;
  v_wamid TEXT := NULLIF(BTRIM(COALESCE(p_reply_to_wamid, p_context_wamid)), '');
  v_sender_number TEXT := NULLIF(BTRIM(p_sender_number), '');
  v_target_number TEXT;
  v_agent_number TEXT;
  v_deadline TIMESTAMPTZ;
  v_delivery_proven BOOLEAN := FALSE;
  v_updated_count INTEGER := 0;
  v_assigned_agent_id TEXT;
  v_event_key TEXT;
BEGIN
  IF NOT public.v3_day_allowed(p_capture_event_id,p_opportunity_id,NULL) THEN
    RETURN jsonb_build_object('ok',FALSE,'outcome','late');
  END IF;
  IF p_opportunity_id IS NULL OR p_attempt_id IS NULL OR p_capture_event_id IS NULL
     OR NULLIF(BTRIM(p_sender_agent_id), '') IS NULL OR p_now IS NULL
     OR (p_reply_to_wamid IS NULL AND p_context_wamid IS NULL)
     OR (p_reply_to_wamid IS NOT NULL AND p_context_wamid IS NOT NULL
         AND BTRIM(p_reply_to_wamid) <> BTRIM(p_context_wamid)) THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'invalid_input');
  END IF;

  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id = p_opportunity_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', FALSE, 'outcome', 'opportunity_not_found'); END IF;
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts
  WHERE attempt_id = p_attempt_id FOR UPDATE;
  IF NOT FOUND OR v_attempt.opportunity_id <> p_opportunity_id THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'attempt_mismatch');
  END IF;
  IF v_opp.assigned_agent_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', TRUE,
      'outcome', CASE WHEN v_opp.assigned_agent_id = BTRIM(p_sender_agent_id)
                      THEN 'already_assigned' ELSE 'already_assigned_other' END,
      'opportunity_id', p_opportunity_id, 'assigned_agent_id', v_opp.assigned_agent_id);
  END IF;
  IF v_opp.current_delivery_attempt_id IS DISTINCT FROM v_attempt.attempt_id
     AND NOT EXISTS (SELECT 1 FROM public.lead_routing_delivery_attempts cur
       WHERE cur.attempt_id = v_opp.current_delivery_attempt_id
         AND cur.capture_event_id = v_attempt.capture_event_id) THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'attempt_not_current');
  END IF;
  IF NOT v_opp.v3_enabled OR v_attempt.delivery_kind IS DISTINCT FROM 'offer'
     OR v_attempt.capture_event_id IS DISTINCT FROM p_capture_event_id
     OR v_attempt.routing_tier NOT IN ('owner', 'primary_guard')
     OR v_opp.routing_tier NOT IN ('owner', 'primary_guard') THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'attempt_not_v3_offer');
  END IF;
  SELECT * INTO v_capture FROM public.i24_capture_events
  WHERE capture_event_id = p_capture_event_id AND opportunity_id = p_opportunity_id
    AND contactado_status = 'verified' AND disposition = 'created_new'
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'capture_not_verified');
  END IF;
  IF v_attempt.target_agent_id IS NULL OR v_attempt.target_agent_id <> BTRIM(p_sender_agent_id) THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender');
  END IF;
  SELECT * INTO v_agent FROM public.agents WHERE agent_id = BTRIM(p_sender_agent_id);
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', FALSE, 'outcome', 'sender_not_found'); END IF;
  v_target_number := NULLIF(BTRIM(v_attempt.target_number), '');
  v_agent_number := NULLIF(BTRIM(v_agent.whatsapp_number), '');
  IF v_sender_number IS NULL OR v_sender_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$'
     OR v_target_number IS NULL OR v_target_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$'
     OR v_agent_number IS NULL OR v_agent_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$' THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender_number');
  END IF;
  v_sender_number := REGEXP_REPLACE(v_sender_number, '[ +()-]', '', 'g');
  v_target_number := REGEXP_REPLACE(v_target_number, '[ +()-]', '', 'g');
  v_agent_number := REGEXP_REPLACE(v_agent_number, '[ +()-]', '', 'g');
  IF v_sender_number !~ '^[1-9][0-9]{7,14}$'
     OR v_target_number !~ '^[1-9][0-9]{7,14}$'
     OR v_agent_number !~ '^[1-9][0-9]{7,14}$'
     OR v_target_number IS DISTINCT FROM v_sender_number
     OR v_agent_number IS DISTINCT FROM v_target_number THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender_number');
  END IF;
  IF v_attempt.provider_message_id IS NULL OR v_wamid IS DISTINCT FROM v_attempt.provider_message_id THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_context');
  END IF;

  v_delivery_proven := (v_attempt.status = 'delivered' AND v_attempt.delivered_at IS NOT NULL)
    OR EXISTS (SELECT 1 FROM public.lead_routing_delivery_callbacks c
      WHERE c.provider_message_id = v_attempt.provider_message_id
        AND c.delivery_status = 'delivered')
    OR EXISTS (SELECT 1 FROM public.lead_routing_meta_webhook_inbox i
      WHERE i.wamid = v_attempt.provider_message_id AND i.event_kind = 'status'
        AND i.status_name IN ('delivered', 'read') AND i.hmac_verified);
  IF NOT v_delivery_proven THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'delivery_not_confirmed');
  END IF;

  -- The shared hour is the sole authority; WF3b cannot extend it.
  v_deadline := public.v3_shared_deadline(p_capture_event_id);
  IF v_deadline IS NULL THEN RETURN jsonb_build_object('ok', FALSE, 'outcome', 'missing_deadline'); END IF;
  IF p_now >= v_deadline THEN RETURN jsonb_build_object('ok', FALSE, 'outcome', 'late'); END IF;
  IF v_opp.conversation_id IS NOT NULL THEN
    SELECT assigned_agent_id INTO v_conversation_assigned_agent_id
    FROM public.conversations WHERE conversation_id = v_opp.conversation_id FOR UPDATE;
    IF v_conversation_assigned_agent_id IS NOT NULL
       AND v_conversation_assigned_agent_id <> BTRIM(p_sender_agent_id) THEN
      RETURN jsonb_build_object('ok', FALSE, 'outcome', 'conversation_already_assigned_other',
        'opportunity_id', p_opportunity_id,
        'assigned_agent_id', v_conversation_assigned_agent_id);
    END IF;
  END IF;
  IF v_opp.state NOT IN ('owner_open', 'primary_guard_open', 'delivered',
                         'guard_delivery_pending', 'delivery_requested') THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'state_not_claimable');
  END IF;

  -- First-wins: the opportunity row lock plus this NULL predicate makes the
  -- assignment and its event one durable transaction.
  UPDATE public.lead_routing_opportunities
  SET assigned_agent_id = BTRIM(p_sender_agent_id), assigned_at = p_now,
      accepted_at = COALESCE(accepted_at, p_now), state = 'assigned',
      updated_at = p_now
  WHERE opportunity_id = p_opportunity_id AND assigned_agent_id IS NULL;
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count = 0 THEN
    SELECT assigned_agent_id INTO v_assigned_agent_id
    FROM public.lead_routing_opportunities WHERE opportunity_id = p_opportunity_id;
    RETURN jsonb_build_object('ok', TRUE, 'outcome', 'already_assigned_other',
      'opportunity_id', p_opportunity_id, 'assigned_agent_id', v_assigned_agent_id);
  END IF;
  UPDATE public.lead_routing_delivery_attempts
  SET claimed_at = COALESCE(claimed_at, p_now)
  WHERE attempt_id = p_attempt_id;
  IF v_opp.conversation_id IS NOT NULL THEN
    UPDATE public.conversations SET assigned_agent_id = BTRIM(p_sender_agent_id),
      assigned_at = COALESCE(assigned_at, p_now), assignment_method = 'v3_response_claim',
      claimed_via = 'v3_meta_webhook', mode = 'ai'
    WHERE conversation_id = v_opp.conversation_id AND assigned_agent_id IS NULL;
  END IF;
  v_event_key := 'v3-delivery-claim:' || p_attempt_id::TEXT || ':' || v_wamid;
  INSERT INTO public.lead_routing_events(
    opportunity_id, event_type, routing_tier, actor_id, idempotency_key,
    external_evidence, metadata
  ) VALUES (
    p_opportunity_id, 'accepted', v_attempt.routing_tier, BTRIM(p_sender_agent_id), v_event_key,
    jsonb_build_object('provider_message_id', v_wamid, 'sender_number', v_sender_number),
    jsonb_build_object('first_wins', TRUE, 'attempt_id', p_attempt_id)
  ) ON CONFLICT (idempotency_key) DO NOTHING;
  RETURN jsonb_build_object('ok', TRUE, 'outcome', 'claimed',
    'opportunity_id', p_opportunity_id, 'assigned_agent_id', BTRIM(p_sender_agent_id),
    'attempt_id', p_attempt_id, 'provider_message_id', v_wamid);
END;
$function$;

CREATE OR REPLACE FUNCTION public.claim_v3_delivery_from_webhook(p_webhook_event_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_webhook public.lead_routing_meta_webhook_inbox;
  v_event JSONB;
  v_message_type TEXT;
  v_button_payload TEXT;
  v_claim_parts TEXT[];
  v_opportunity_id BIGINT;
  v_attempt_id BIGINT;
  v_opp public.lead_routing_opportunities;
  v_attempt public.lead_routing_delivery_attempts;
  v_capture public.i24_capture_events;
  v_agent public.agents;
  v_event_wamid TEXT;
  v_context_wamid TEXT;
  v_sender_number TEXT;
  v_target_number TEXT;
  v_agent_number TEXT;
  v_result JSONB;
  v_open BIGINT[];
BEGIN
  IF p_webhook_event_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'invalid_webhook_event_id');
  END IF;

  SELECT i.* INTO v_webhook
  FROM public.lead_routing_meta_webhook_inbox i
  WHERE i.webhook_event_id = p_webhook_event_id;
  IF NOT FOUND OR v_webhook.event_kind IS DISTINCT FROM 'message'
     OR v_webhook.hmac_verified IS DISTINCT FROM TRUE
     OR v_webhook.created_at IS NULL
     OR jsonb_typeof(v_webhook.sanitized_payload) IS DISTINCT FROM 'object'
     OR jsonb_typeof(v_webhook.sanitized_payload->'event') IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'verified_webhook_not_found');
  END IF;

  v_event := v_webhook.sanitized_payload->'event';
  v_message_type := NULLIF(v_event->>'type', '');
  v_event_wamid := NULLIF(BTRIM(v_event->>'id'), '');
  v_context_wamid := NULLIF(BTRIM(v_event #>> '{context,id}'), '');
  v_sender_number := NULLIF(BTRIM(v_event->>'from'), '');
  v_button_payload := CASE v_message_type
    WHEN 'button' THEN NULLIF(BTRIM(v_event #>> '{button,payload}'), '')
    WHEN 'interactive' THEN NULLIF(BTRIM(v_event #>> '{interactive,button_reply,id}'), '')
    ELSE NULL
  END;

  IF v_message_type = 'text' AND v_event #>> '{text,body}' ~* '^\s*tomo[^[:alnum:]]*$' THEN
    -- Typed "tomo": the quoted offer if it is a reply, else the sender's only open offer.
    IF v_event_wamid IS NULL OR v_event_wamid IS DISTINCT FROM v_webhook.wamid
       OR v_sender_number IS NULL THEN
      RETURN jsonb_build_object('ok', FALSE, 'outcome', 'verified_webhook_mismatch');
    END IF;
    SELECT array_agg(a.attempt_id ORDER BY a.requested_at) INTO v_open
    FROM public.lead_routing_delivery_attempts a
    JOIN public.lead_routing_opportunities o ON o.opportunity_id = a.opportunity_id
    JOIN public.lead_routing_delivery_attempts cur ON cur.attempt_id = o.current_delivery_attempt_id
    WHERE a.delivery_kind = 'offer' AND a.routing_tier IN ('owner','primary_guard')
      AND a.provider_message_id IS NOT NULL
      AND (v_context_wamid IS NULL OR a.provider_message_id = v_context_wamid)
      AND REGEXP_REPLACE(a.target_number, '[ +()-]', '', 'g')
          = REGEXP_REPLACE(v_sender_number, '[ +()-]', '', 'g')
      AND cur.capture_event_id = a.capture_event_id
      AND o.v3_enabled AND o.assigned_agent_id IS NULL
      AND o.routing_tier IN ('owner','primary_guard')
      AND a.requested_at <= v_webhook.created_at
      AND v_webhook.created_at < public.v3_shared_deadline(a.capture_event_id);
    IF v_open IS NULL THEN
      RETURN jsonb_build_object('ok', FALSE, 'outcome', 'no_open_offer');
    ELSIF cardinality(v_open) > 1 THEN
      RETURN jsonb_build_object('ok', FALSE, 'outcome', 'ambiguous_text_claim',
        'open_offers', cardinality(v_open));
    END IF;
    v_attempt_id := v_open[1];
    SELECT a.opportunity_id, a.provider_message_id INTO v_opportunity_id, v_context_wamid
    FROM public.lead_routing_delivery_attempts a WHERE a.attempt_id = v_attempt_id;
  ELSE
    IF v_event_wamid IS NULL OR v_event_wamid IS DISTINCT FROM v_webhook.wamid
       OR v_context_wamid IS NULL
       OR v_webhook.sanitized_payload->>'context_id' IS DISTINCT FROM v_context_wamid
       OR v_sender_number IS NULL OR v_button_payload IS NULL THEN
      RETURN jsonb_build_object('ok', FALSE, 'outcome', 'verified_webhook_mismatch');
    END IF;

    v_claim_parts := regexp_match(
      v_button_payload,
      '^claim:v3:([1-9][0-9]{0,17}):([1-9][0-9]{0,17})$'
    );
    IF v_claim_parts IS NULL THEN
      RETURN jsonb_build_object('ok', FALSE, 'outcome', 'invalid_claim_payload');
    END IF;
    v_opportunity_id := v_claim_parts[1]::BIGINT;
    v_attempt_id := v_claim_parts[2]::BIGINT;
  END IF;

  SELECT o.* INTO v_opp
  FROM public.lead_routing_opportunities o
  WHERE o.opportunity_id = v_opportunity_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'opportunity_not_found');
  END IF;

  SELECT a.* INTO v_attempt
  FROM public.lead_routing_delivery_attempts a
  WHERE a.attempt_id = v_attempt_id
  FOR UPDATE;
  IF NOT FOUND OR v_attempt.opportunity_id IS DISTINCT FROM v_opportunity_id
     OR v_attempt.delivery_kind IS DISTINCT FROM 'offer'
     OR v_attempt.routing_tier NOT IN ('owner', 'primary_guard')
     OR v_attempt.capture_event_id IS NULL
     OR v_attempt.requested_at IS NULL
     OR v_attempt.target_agent_id IS NULL
     OR v_attempt.provider_message_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'attempt_mismatch');
  END IF;
  IF v_opp.assigned_agent_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', TRUE,
      'outcome', CASE WHEN v_opp.assigned_agent_id = v_attempt.target_agent_id
                      THEN 'already_assigned' ELSE 'already_assigned_other' END,
      'opportunity_id', v_opportunity_id, 'assigned_agent_id', v_opp.assigned_agent_id);
  END IF;
  IF v_opp.routing_tier NOT IN ('owner', 'primary_guard')
     OR (v_opp.current_delivery_attempt_id IS DISTINCT FROM v_attempt_id
         AND NOT EXISTS (SELECT 1 FROM public.lead_routing_delivery_attempts cur
           WHERE cur.attempt_id = v_opp.current_delivery_attempt_id
             AND cur.capture_event_id = v_attempt.capture_event_id)) THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'late');
  END IF;

  SELECT c.* INTO v_capture
  FROM public.i24_capture_events c
  WHERE c.capture_event_id = v_attempt.capture_event_id
    AND c.opportunity_id = v_opportunity_id
    AND c.contactado_status = 'verified'
    AND c.disposition = 'created_new';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'capture_not_verified');
  END IF;

  SELECT ag.* INTO v_agent
  FROM public.agents ag
  WHERE ag.agent_id = v_attempt.target_agent_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'sender_not_found');
  END IF;

  v_target_number := NULLIF(BTRIM(v_attempt.target_number), '');
  v_agent_number := NULLIF(BTRIM(v_agent.whatsapp_number), '');
  IF v_sender_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$'
     OR v_target_number IS NULL
     OR v_target_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$'
     OR v_agent_number IS NULL
     OR v_agent_number !~ '^\+?[1-9][0-9 ()-]{6,18}[0-9]$' THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender_number');
  END IF;
  v_sender_number := REGEXP_REPLACE(v_sender_number, '[ +()-]', '', 'g');
  v_target_number := REGEXP_REPLACE(v_target_number, '[ +()-]', '', 'g');
  v_agent_number := REGEXP_REPLACE(v_agent_number, '[ +()-]', '', 'g');
  IF v_sender_number !~ '^[1-9][0-9]{7,14}$'
     OR v_target_number IS DISTINCT FROM v_sender_number
     OR v_agent_number IS DISTINCT FROM v_sender_number THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender_number');
  END IF;

  IF v_context_wamid IS DISTINCT FROM v_attempt.provider_message_id THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_context');
  END IF;
  IF v_webhook.created_at < v_attempt.requested_at
     OR v_webhook.created_at >= public.v3_shared_deadline(v_attempt.capture_event_id) THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'late');
  END IF;

  v_result := public.claim_v3_delivery(
    v_opportunity_id,
    v_attempt_id,
    v_attempt.capture_event_id,
    v_attempt.target_agent_id,
    v_sender_number,
    v_context_wamid,
    NULL,
    v_webhook.created_at
  );

  IF v_result->>'outcome' = 'claimed' THEN
    -- The canonical business timestamps remain the immutable ingress time;
    -- only this maintenance timestamp records delayed processing.
    UPDATE public.lead_routing_opportunities
    SET updated_at = clock_timestamp()
    WHERE opportunity_id = v_opportunity_id;
  END IF;

  IF v_result->>'outcome' IN ('claimed', 'already_assigned') THEN
    INSERT INTO public.lead_routing_events(
      opportunity_id, event_type, routing_tier, actor_id, occurred_at,
      idempotency_key, external_evidence, metadata
    ) VALUES (
      v_opportunity_id,
      'claim_webhook_verified',
      v_attempt.routing_tier,
      v_attempt.target_agent_id,
      v_webhook.created_at,
      'v3-verified-webhook-claim:' || p_webhook_event_id::TEXT,
      jsonb_build_object(
        'webhook_event_id', p_webhook_event_id,
        'inbound_wamid', v_event_wamid,
        'context_wamid', v_context_wamid,
        'claim_ingress_at', v_webhook.created_at,
        'capture_event_id', v_attempt.capture_event_id
      ),
      jsonb_build_object(
        'verified_webhook_time', TRUE,
        'attempt_id', v_attempt_id,
        'claim_outcome', v_result->>'outcome',
        'typed_text', v_message_type = 'text'
      )
    ) ON CONFLICT (idempotency_key) DO NOTHING;
  END IF;

  RETURN v_result || jsonb_build_object(
    'webhook_event_id', p_webhook_event_id,
    'claim_ingress_at', v_webhook.created_at,
    'inbound_wamid', v_event_wamid
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.v3_shared_deadline(bigint), public.v3_fallback_agent(timestamptz),
  public.v3_second_offer_target(text, timestamptz),
  public.v3_assign_manager(bigint, text, text, bigint, timestamptz) FROM PUBLIC, anon, authenticated;
