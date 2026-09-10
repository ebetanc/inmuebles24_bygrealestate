-- V3: leads nobody claims stay UNASSIGNED instead of landing on Sandy.
--
-- Client decision (2026-09-10): when no agent taps "Tomo", the opportunity
-- reaches the terminal state 'unassigned'; no WhatsApp goes to the manager and
-- EasyBroker receives the note "RESPONSABLE: SIN ASIGNACION" but is NOT marked
-- Atendida.
--
-- v3_assign_sandy stays defined (unused) so the rollback is a single re-create
-- of v3_route_ready_opportunity / v3_advance_routing_tier from
-- 20260907152702_v3_day_deadline.sql.

-- 1. When the lead was left unassigned.
ALTER TABLE public.lead_routing_opportunities
  ADD COLUMN IF NOT EXISTS unassigned_at timestamptz;

-- 2. New terminal state.
ALTER TABLE public.lead_routing_opportunities
  DROP CONSTRAINT IF EXISTS lead_routing_opportunities_state_check;
ALTER TABLE public.lead_routing_opportunities
  ADD CONSTRAINT lead_routing_opportunities_state_check CHECK (state IN (
    'captured','deduplicated','resolved','delivery_requested','guard_delivery_pending',
    'delivered','owner_open','primary_guard_open','backup_guard_open','assigned',
    'unassigned','unassigned_alerted','queued_night','manual_non_deduplicable','safe_mode',
    'closed_won','closed_lost'));

-- 3. EasyBroker ledger: a responsible without an agent, and a skipped Atendida.
ALTER TABLE public.easybroker_effect_ledger
  DROP CONSTRAINT IF EXISTS easybroker_effect_ledger_attended_state_check;
ALTER TABLE public.easybroker_effect_ledger
  ADD CONSTRAINT easybroker_effect_ledger_attended_state_check
  CHECK (attended_state IN ('pending','succeeded','failed','skipped'));

ALTER TABLE public.easybroker_effect_ledger
  DROP CONSTRAINT IF EXISTS easybroker_effect_ledger_check;
ALTER TABLE public.easybroker_effect_ledger
  ADD CONSTRAINT easybroker_effect_ledger_check
  CHECK (close_state = 'awaiting_responsible'
         OR NULLIF(BTRIM(responsible_first_name), '') IS NOT NULL);

ALTER TABLE public.easybroker_effect_ledger
  DROP CONSTRAINT IF EXISTS easybroker_effect_ledger_check1;
ALTER TABLE public.easybroker_effect_ledger
  ADD CONSTRAINT easybroker_effect_ledger_check1
  CHECK (close_state <> 'completed'
         OR (note_state = 'succeeded' AND attended_state IN ('succeeded','skipped')));

-- 4. Terminal "nobody took it". Mirrors v3_assign_sandy's guards, but assigns
-- nobody, notifies nobody, and never touches public.conversations (V3
-- opportunities carry conversation_id IS NULL and the legacy conversation
-- CHECKs reject V3 values).
CREATE OR REPLACE FUNCTION public.v3_mark_unassigned(
  p_opportunity_id BIGINT,
  p_reason TEXT,
  p_capture_event_id BIGINT DEFAULT NULL,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE v_opp public.lead_routing_opportunities; v_rows INTEGER := 0;
BEGIN
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT v_opp.v3_enabled THEN RAISE EXCEPTION 'V3 opportunity unavailable'; END IF;
  IF v_opp.assigned_agent_id IS NOT NULL
     OR v_opp.state IN ('unassigned','closed_won','closed_lost') THEN
    RETURN FALSE;
  END IF;
  UPDATE public.lead_routing_opportunities
  SET state='unassigned', routing_tier=NULL, assigned_agent_id=NULL,
      unassigned_at=p_now, expires_at=NULL, current_delivery_attempt_id=NULL,
      updated_at=p_now,
      external_evidence=COALESCE(external_evidence,'{}'::JSONB)
        || jsonb_build_object('v3_final_route','unassigned',
             'reason',LEFT(COALESCE(p_reason,'fallback'),120))
  WHERE opportunity_id=p_opportunity_id AND assigned_agent_id IS NULL
    AND state NOT IN ('unassigned','closed_won','closed_lost');
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN RETURN FALSE; END IF;
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,actor_id,idempotency_key,metadata)
  VALUES(p_opportunity_id,'left_unassigned',NULL,
    'v3-unassigned:'||p_opportunity_id::TEXT,
    jsonb_build_object('reason',LEFT(COALESCE(p_reason,'fallback'),120),
      'capture_event_id',p_capture_event_id))
  ON CONFLICT (idempotency_key) DO NOTHING;
  RETURN TRUE;
END;
$$;

COMMENT ON FUNCTION public.v3_mark_unassigned(BIGINT,TEXT,BIGINT,TIMESTAMPTZ)
  IS 'Terminal V3 route when nobody claims: leaves the lead unassigned, no manager notice.';

-- 5. Routing: the Sandy fallback becomes the unassigned terminal.
--    Verbatim from 20260907152702_v3_day_deadline.sql except the fallback branches.
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

CREATE OR REPLACE FUNCTION public.v3_advance_routing_tier(p_opportunity_id bigint, p_expected_tier text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_attempt public.lead_routing_delivery_attempts;
  v_guard RECORD;
  v_guard_found BOOLEAN := FALSE;
  v_attempt_id BIGINT;
  v_pending_claim JSONB;
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
  IF v_attempt.delivered_at IS NOT NULL THEN
    IF v_opp.expires_at IS NULL THEN
      UPDATE public.lead_routing_opportunities
      SET expires_at=v_attempt.delivered_at+INTERVAL '5 minutes', updated_at=p_now
      WHERE opportunity_id=p_opportunity_id AND expires_at IS NULL;
      v_opp.expires_at := v_attempt.delivered_at+INTERVAL '5 minutes';
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

  IF p_expected_tier='owner' THEN
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
    IF NOT v_guard_found OR v_guard.agent_id IS NOT DISTINCT FROM v_attempt.target_agent_id THEN
      PERFORM public.v3_mark_unassigned(
        p_opportunity_id,
        CASE WHEN NOT v_guard_found THEN 'guard_unavailable' ELSE 'owner_equals_guard' END,
        v_attempt.capture_event_id,
        p_now
      );
      RETURN jsonb_build_object('state','unassigned','tier',NULL,'opportunity_id',p_opportunity_id);
    END IF;
    UPDATE public.lead_routing_opportunities
    SET state='guard_delivery_pending',routing_tier='primary_guard',delivery_status=NULL,
        current_delivery_attempt_id=NULL,delivered_at=NULL,expires_at=NULL,updated_at=p_now
    WHERE opportunity_id=p_opportunity_id;
    v_attempt_id := public.v3_request_offer(
      v_attempt.capture_event_id,
      'primary_guard',
      'v3:guard:'||p_opportunity_id::TEXT||':'||v_attempt.capture_event_id::TEXT,
      v_guard.agent_id,
      v_guard.whatsapp_number
    );
    RETURN jsonb_build_object(
      'state','guard_delivery_requested','tier','primary_guard',
      'attempt_id',v_attempt_id,'opportunity_id',p_opportunity_id,
      'capture_event_id',v_attempt.capture_event_id
    );
  END IF;
  PERFORM public.v3_mark_unassigned(
    p_opportunity_id,
    'guard_expired',
    v_attempt.capture_event_id,
    p_now
  );
  RETURN jsonb_build_object('state','unassigned','tier',NULL,'opportunity_id',p_opportunity_id);
END;
$$;

-- 6. EasyBroker request creation also runs for the unassigned terminal: without
-- a request there is nothing to write the "RESPONSABLE: SIN ASIGNACIÓN" note on.
-- The creation ledger stores no responsible (see
-- easybroker_contact_request_creation_ledger); the agent join is only an
-- eligibility gate, so an unassigned lead skips it entirely and the responsible
-- is resolved later by claim_v3_easybroker_effects.
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
    AND e.disposition='created_new'
    AND e.contactado_status='verified'
    AND e.route_dispatch_status='dispatched'
    AND o.v3_enabled
    AND (
      (o.state IN ('assigned','closed_won')
       AND o.assigned_agent_id IS NOT NULL
       AND NULLIF(BTRIM(a.name),'') IS NOT NULL)
      OR o.state='unassigned'
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

-- 7. Ledger promotion: the unassigned terminal resolves to "SIN ASIGNACION"
-- with no agent, so the Atendida step is never due.
CREATE OR REPLACE FUNCTION public.claim_v3_easybroker_effects(p_limit integer, p_now timestamp with time zone, p_lease_duration interval)
 RETURNS TABLE(eb_request_id bigint, opportunity_id bigint, responsible_first_name text, note_state text, attended_state text, lease_token uuid, lease_expires_at timestamp with time zone, note_due boolean, attended_due boolean, note_idempotency_key text, attended_idempotency_key text)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $$
DECLARE
  r public.easybroker_effect_ledger;
  v_note_due BOOLEAN;
  v_attended_due BOOLEAN;
  v_token UUID;
  v_expires TIMESTAMPTZ;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500
     OR p_now IS NULL OR p_lease_duration IS NULL
     OR p_lease_duration <= INTERVAL '0'
     OR p_lease_duration > INTERVAL '15 minutes' THEN
    RAISE EXCEPTION 'invalid effect lease input';
  END IF;

  -- Assignment and EasyBroker correlation can complete in either order.  On
  -- every worker pass, atomically promote exact linked ledgers whose final
  -- responsible is now known; no second correlation or external retry is
  -- required to make the request actionable.  A lead nobody took resolves to
  -- the literal responsible 'SIN ASIGNACIÓN' with no agent behind it.
  UPDATE public.easybroker_effect_ledger e
  SET responsible_agent_id = o.assigned_agent_id,
      responsible_first_name = CASE WHEN o.state='unassigned' THEN 'SIN ASIGNACIÓN'
        ELSE split_part(regexp_replace(BTRIM(a.name), '\s+', ' ', 'g'), ' ', 1) END,
      close_state = 'pending',
      note_next_retry_at = p_now,
      attended_next_retry_at = p_now,
      next_retry_at = p_now,
      updated_at = p_now
  FROM public.lead_routing_opportunities o
  LEFT JOIN public.agents a ON a.agent_id = o.assigned_agent_id
  WHERE e.opportunity_id = o.opportunity_id
    AND e.close_state = 'awaiting_responsible'
    AND (
      (o.state IN ('assigned','closed_won')
       AND o.assigned_agent_id IS NOT NULL
       AND NULLIF(BTRIM(a.name), '') IS NOT NULL)
      OR o.state = 'unassigned'
    );

  FOR r IN
    SELECT e.*
    FROM public.easybroker_effect_ledger e
    WHERE public.v3_day_allowed(NULL,e.opportunity_id,e.eb_request_id)
      AND e.close_state IN ('pending','retrying','exhausted')
      AND (e.lease_expires_at IS NULL OR e.lease_expires_at <= p_now)
      AND (
        (e.note_state IN ('pending','failed')
         AND e.note_next_retry_at IS NOT NULL AND e.note_next_retry_at <= p_now)
        OR
        (e.attended_state IN ('pending','failed')
         AND e.note_state = 'succeeded'
         AND e.attended_next_retry_at IS NOT NULL AND e.attended_next_retry_at <= p_now)
      )
    ORDER BY e.next_retry_at, e.eb_request_id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_note_due := r.note_state IN ('pending','failed')
      AND r.note_next_retry_at IS NOT NULL AND r.note_next_retry_at <= p_now;
    -- No agent behind the note means EasyBroker is never marked Atendida.
    v_attended_due := r.responsible_agent_id IS NOT NULL
      AND r.attended_state IN ('pending','failed')
      AND r.note_state = 'succeeded'
      AND r.attended_next_retry_at IS NOT NULL AND r.attended_next_retry_at <= p_now;
    v_token := gen_random_uuid();
    v_expires := p_now + p_lease_duration;

    UPDATE public.easybroker_effect_ledger e
    SET lease_token = v_token, lease_expires_at = v_expires, updated_at = p_now
    WHERE e.eb_request_id = r.eb_request_id;

    IF v_note_due THEN
      INSERT INTO public.easybroker_effect_attempts(
        eb_request_id, effect_kind, attempt_no, effect_idempotency_key,
        lease_token, started_at
      ) VALUES (
        r.eb_request_id, 'note', r.note_retry_count,
        'easybroker:' || r.eb_request_id || ':note:' || r.note_retry_count,
        v_token, p_now
      ) ON CONFLICT (effect_idempotency_key) DO UPDATE
        SET lease_token = EXCLUDED.lease_token,
            started_at = EXCLUDED.started_at
        WHERE public.easybroker_effect_attempts.finished_at IS NULL;
    END IF;
    IF v_attended_due THEN
      INSERT INTO public.easybroker_effect_attempts(
        eb_request_id, effect_kind, attempt_no, effect_idempotency_key,
        lease_token, started_at
      ) VALUES (
        r.eb_request_id, 'attended', r.attended_retry_count,
        'easybroker:' || r.eb_request_id || ':attended:' || r.attended_retry_count,
        v_token, p_now
      ) ON CONFLICT (effect_idempotency_key) DO UPDATE
        SET lease_token = EXCLUDED.lease_token,
            started_at = EXCLUDED.started_at
        WHERE public.easybroker_effect_attempts.finished_at IS NULL;
    END IF;

    eb_request_id := r.eb_request_id;
    opportunity_id := r.opportunity_id;
    responsible_first_name := r.responsible_first_name;
    note_state := r.note_state;
    attended_state := r.attended_state;
    lease_token := v_token;
    lease_expires_at := v_expires;
    note_due := v_note_due;
    attended_due := v_attended_due;
    note_idempotency_key := CASE WHEN v_note_due
      THEN 'easybroker:' || r.eb_request_id || ':note:' || r.note_retry_count END;
    attended_idempotency_key := CASE WHEN v_attended_due
      THEN 'easybroker:' || r.eb_request_id || ':attended:' || r.attended_retry_count END;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- 8. A succeeded note with no agent behind it closes the ledger: Atendida is
-- skipped, never attempted.
CREATE OR REPLACE FUNCTION public.finish_v3_easybroker_effect(
  p_eb_request_id BIGINT,
  p_lease_token UUID,
  p_step TEXT,
  p_ok BOOLEAN,
  p_evidence JSONB,
  p_now TIMESTAMPTZ
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE
  l public.easybroker_effect_ledger;
  v_attempt_no INTEGER;
  v_next_count INTEGER;
  v_next_deadline TIMESTAMPTZ;
  v_effect_key TEXT;
  v_alert_id BIGINT;
  v_note_next TIMESTAMPTZ;
  v_attended_next TIMESTAMPTZ;
  v_note_count INTEGER;
  v_attended_count INTEGER;
  v_retry_count INTEGER;
  v_close_state TEXT;
  v_manual_review BOOLEAN;
BEGIN
  IF p_eb_request_id IS NULL OR p_lease_token IS NULL
     OR p_step IS NULL OR p_step NOT IN ('note','attended')
     OR p_ok IS NULL OR p_now IS NULL
     OR p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' THEN
    RAISE EXCEPTION 'invalid effect result';
  END IF;

  SELECT * INTO l
  FROM public.easybroker_effect_ledger e
  WHERE e.eb_request_id = p_eb_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'state', 'missing_ledger',
      'eb_request_id', p_eb_request_id);
  END IF;

  IF p_step = 'note' AND l.note_state = 'succeeded' THEN
    RETURN jsonb_build_object('ok', true, 'state', 'already_succeeded',
      'eb_request_id', p_eb_request_id, 'step', p_step);
  END IF;
  IF p_step = 'attended' AND l.attended_state IN ('succeeded','skipped') THEN
    RETURN jsonb_build_object('ok', true, 'state', 'already_succeeded',
      'eb_request_id', p_eb_request_id, 'step', p_step);
  END IF;
  -- A lead nobody took has a responsible name but no agent.
  IF NULLIF(BTRIM(l.responsible_first_name), '') IS NULL THEN
    RAISE EXCEPTION 'final responsible required before EasyBroker effects';
  END IF;
  IF l.responsible_agent_id IS NULL AND p_step = 'attended' THEN
    RAISE EXCEPTION 'unassigned leads are never marked Atendida';
  END IF;
  IF l.lease_token IS DISTINCT FROM p_lease_token
     OR l.lease_expires_at IS NULL OR l.lease_expires_at <= p_now THEN
    RETURN jsonb_build_object('ok', false, 'state', 'lease_conflict',
      'eb_request_id', p_eb_request_id, 'step', p_step);
  END IF;
  IF p_step = 'attended' AND l.note_state <> 'succeeded' THEN
    RETURN jsonb_build_object('ok', false, 'state', 'note_required',
      'eb_request_id', p_eb_request_id, 'step', p_step);
  END IF;
  IF p_evidence->>'eb_request_id' IS DISTINCT FROM p_eb_request_id::TEXT THEN
    RAISE EXCEPTION 'exact EasyBroker request evidence required';
  END IF;
  IF p_ok AND p_step = 'note'
     AND p_evidence->>'note' IS DISTINCT FROM
         'RESPONSABLE: ' || BTRIM(l.responsible_first_name) THEN
    RAISE EXCEPTION 'canonical responsible note required';
  END IF;
  IF p_ok AND p_step = 'note'
     AND COALESCE(p_evidence->>'reconciled_existing', 'false') <> 'true'
     AND COALESCE(p_evidence->>'note_written', 'false') <> 'true' THEN
    RAISE EXCEPTION 'note write or existing-note reconciliation evidence required';
  END IF;
  IF p_ok AND p_step = 'attended'
     AND p_evidence->>'status' IS DISTINCT FROM 'Atendida' THEN
    RAISE EXCEPTION 'Atendida status evidence required';
  END IF;

  v_attempt_no := CASE WHEN p_step = 'note'
    THEN l.note_retry_count ELSE l.attended_retry_count END;
  v_effect_key := 'easybroker:' || p_eb_request_id || ':' || p_step || ':' || v_attempt_no;
  IF NOT EXISTS (
    SELECT 1
    FROM public.easybroker_effect_attempts a
    WHERE a.eb_request_id = p_eb_request_id
      AND a.effect_idempotency_key = v_effect_key
      AND a.lease_token = p_lease_token
      AND a.finished_at IS NULL
  ) THEN
    RETURN jsonb_build_object('ok', false, 'state', 'attempt_conflict',
      'eb_request_id', p_eb_request_id, 'step', p_step,
      'effect_idempotency_key', v_effect_key);
  END IF;

  v_manual_review := NOT p_ok AND p_evidence->>'error_code' IN (
    'easybroker_assignee_conflict', 'responsible_note_conflict'
  );

  IF p_ok THEN
    IF p_step = 'note' THEN
      UPDATE public.easybroker_effect_ledger e
      SET note_state = 'succeeded', note_evidence = p_evidence,
          note_next_retry_at = NULL,
          attended_state = CASE WHEN e.responsible_agent_id IS NULL
            THEN 'skipped' ELSE e.attended_state END,
          attended_next_retry_at = CASE WHEN e.responsible_agent_id IS NULL
            THEN NULL ELSE e.attended_next_retry_at END,
          close_state = CASE WHEN e.responsible_agent_id IS NULL
            THEN 'completed' ELSE e.close_state END,
          updated_at = p_now
      WHERE e.eb_request_id = p_eb_request_id;
    ELSE
      UPDATE public.easybroker_effect_ledger e
      SET attended_state = 'succeeded', attended_evidence = p_evidence,
          attended_next_retry_at = NULL, updated_at = p_now
      WHERE e.eb_request_id = p_eb_request_id;
    END IF;
  ELSE
    v_next_count := v_attempt_no + 1;
    v_next_deadline := COALESCE(
      CASE WHEN p_step = 'note' THEN l.note_first_failed_at
           ELSE l.attended_first_failed_at END, p_now
    ) + CASE v_next_count
      WHEN 1 THEN INTERVAL '1 minute'
      WHEN 2 THEN INTERVAL '5 minutes'
      WHEN 3 THEN INTERVAL '15 minutes'
      WHEN 4 THEN INTERVAL '30 minutes'
      ELSE INTERVAL '0'
    END;
    IF p_step = 'note' THEN
      UPDATE public.easybroker_effect_ledger e
      SET note_state = 'failed', note_evidence = p_evidence,
          note_retry_count = LEAST(v_next_count, 5),
          note_first_failed_at = COALESCE(e.note_first_failed_at, p_now),
          note_next_retry_at = CASE
            WHEN v_manual_review OR v_next_count >= 5 THEN NULL
            ELSE v_next_deadline
          END,
          attended_next_retry_at = CASE
            WHEN v_manual_review THEN NULL ELSE e.attended_next_retry_at
          END,
          updated_at = p_now
      WHERE e.eb_request_id = p_eb_request_id;
    ELSE
      UPDATE public.easybroker_effect_ledger e
      SET attended_state = 'failed', attended_evidence = p_evidence,
          attended_retry_count = LEAST(v_next_count, 5),
          attended_first_failed_at = COALESCE(e.attended_first_failed_at, p_now),
          attended_next_retry_at = CASE
            WHEN v_manual_review OR v_next_count >= 5 THEN NULL
            ELSE v_next_deadline
          END,
          updated_at = p_now
      WHERE e.eb_request_id = p_eb_request_id;
    END IF;
  END IF;

  SELECT e.note_next_retry_at, e.attended_next_retry_at,
         e.note_retry_count, e.attended_retry_count,
         CASE WHEN e.note_state = 'succeeded'
               AND e.attended_state IN ('succeeded','skipped')
              THEN 'completed'
              WHEN v_manual_review THEN 'manual_review'
              WHEN e.note_retry_count >= 5 OR e.attended_retry_count >= 5
              THEN 'exhausted' ELSE 'retrying' END
    INTO v_note_next, v_attended_next, v_note_count, v_attended_count,
         v_close_state
  FROM public.easybroker_effect_ledger e
  WHERE e.eb_request_id = p_eb_request_id;
  v_retry_count := GREATEST(v_note_count, v_attended_count, 0);
  UPDATE public.easybroker_effect_ledger e
  SET close_state = v_close_state,
      next_retry_at = CASE
        WHEN v_close_state = 'manual_review' THEN NULL
        WHEN v_note_next IS NULL THEN v_attended_next
        WHEN v_attended_next IS NULL THEN v_note_next
        ELSE LEAST(v_note_next, v_attended_next)
      END,
      lease_token = NULL,
      lease_expires_at = NULL,
      updated_at = p_now
  WHERE e.eb_request_id = p_eb_request_id;

  UPDATE public.easybroker_effect_attempts a
  SET finished_at = p_now, ok = p_ok, evidence = p_evidence
  WHERE a.effect_idempotency_key = v_effect_key
    AND a.eb_request_id = p_eb_request_id
    AND a.finished_at IS NULL;

  IF v_close_state IN ('exhausted', 'manual_review') THEN
    INSERT INTO public.easybroker_effect_alerts(
      eb_request_id, opportunity_id, incident_key, alert_type, metadata
    ) VALUES (
      p_eb_request_id, l.opportunity_id,
      CASE v_close_state
        WHEN 'manual_review' THEN
          'easybroker_effect_manual_review:' || p_eb_request_id
        ELSE 'easybroker_effect_exhausted:' || p_eb_request_id
      END,
      CASE v_close_state
        WHEN 'manual_review' THEN 'easybroker_effect_manual_review'
        ELSE 'easybroker_effects_exhausted'
      END,
      jsonb_strip_nulls(jsonb_build_object(
        'target', 'sandy', 'step', p_step,
        'retry_count', v_retry_count, 'eb_request_id', p_eb_request_id,
        'error_code', NULLIF(p_evidence->>'error_code', '')
      ))
    ) ON CONFLICT (incident_key) DO NOTHING
    RETURNING alert_id INTO v_alert_id;
    UPDATE public.easybroker_effect_ledger e
    SET sandy_alerted_at = COALESCE(e.sandy_alerted_at, p_now), updated_at = p_now
    WHERE e.eb_request_id = p_eb_request_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', p_ok, 'state', v_close_state, 'eb_request_id', p_eb_request_id,
    'step', p_step, 'effect_idempotency_key', v_effect_key,
    'alert_created', v_alert_id IS NOT NULL, 'changed_at', p_now
  );
END;
$$;

-- 9. Day SLA: the unassigned terminal, reached before the deadline, is a close.
CREATE OR REPLACE FUNCTION public.v3_day_sweep() RETURNS integer
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE total integer;
BEGIN
 INSERT INTO public.v3_day_incidents(capture_event_id,opportunity_id,reason)
 SELECT c.capture_event_id,c.opportunity_id,COALESCE(c.day_hold_reason,
   CASE WHEN c.contactado_status <> 'verified' THEN 'contactado_not_verified'
    WHEN c.route_dispatch_status <> 'dispatched' THEN 'route_not_dispatched'
    WHEN o.assigned_agent_id IS NULL AND o.state <> 'unassigned' THEN 'responsible_not_assigned'
    ELSE 'easybroker_not_closed' END)
 FROM public.i24_capture_events c
 LEFT JOIN public.lead_routing_opportunities o ON o.opportunity_id=c.opportunity_id
 WHERE c.day_deadline_at IS NOT NULL
   AND (c.day_hold_reason IS NOT NULL OR (c.day_deadline_at <= clock_timestamp()
     AND NOT COALESCE((c.contactado_status='verified' AND c.contactado_verified_at <= c.day_deadline_at
       AND c.route_dispatch_status='dispatched' AND c.route_dispatched_at <= c.day_deadline_at
       AND (
         (o.assigned_agent_id IS NOT NULL AND o.assigned_at <= c.day_deadline_at
          AND EXISTS (SELECT 1 FROM public.lead_routing_delivery_attempts a
            WHERE a.target_agent_id=o.assigned_agent_id
              AND (a.capture_event_id=c.capture_event_id
                OR (c.disposition='active_duplicate' AND a.opportunity_id=c.opportunity_id))
              AND a.delivered_at IS NOT NULL AND a.delivered_at <= c.day_deadline_at))
         OR (o.state='unassigned' AND o.unassigned_at <= c.day_deadline_at)
       )
       AND EXISTS (SELECT 1 FROM public.easybroker_effect_ledger e
         WHERE e.opportunity_id=c.opportunity_id AND e.note_state='succeeded'
          AND e.attended_state IN ('succeeded','skipped') AND e.updated_at <= c.day_deadline_at)),false)))
 ON CONFLICT (capture_event_id) DO NOTHING;
 GET DIAGNOSTICS total=ROW_COUNT;
 RETURN total;
END $$;

-- 10. Delivery callbacks never reopen an unassigned lead.
CREATE OR REPLACE FUNCTION public.reconcile_delivery_callback(p_provider_message_id TEXT)
RETURNS public.lead_routing_opportunities
LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public AS $$
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
     OR v_opp.state IN ('assigned','unassigned','unassigned_alerted','closed_won','closed_lost') THEN
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
$$;

-- 11. Dashboard: "Sin asignación" is its own assignment method.
CREATE OR REPLACE VIEW public.v3_leads_dashboard
WITH (security_invoker = true) AS
WITH att AS (
  -- WhatsApp delivery per tier + the attempt that was actually claimed.
  SELECT
    a.opportunity_id,
    max(a.delivered_at) FILTER (
      WHERE a.delivery_kind = 'offer' AND a.routing_tier = 'owner'
    ) AS owner_offer_delivered_at,
    max(a.delivered_at) FILTER (
      WHERE a.delivery_kind = 'offer' AND a.routing_tier IN ('primary_guard', 'backup_guard')
    ) AS guard_offer_delivered_at,
    max(a.delivered_at) FILTER (
      WHERE a.delivery_kind = 'assigned_notice'
    ) AS sandy_notice_delivered_at,
    -- NOTE: a.claimed_at is the sender's lease (WF13/WF23), NOT the human click.
    -- The human click lives in lead_routing_opportunities.accepted_at (see ca below).
    count(*) FILTER (
      WHERE a.delivery_kind = 'offer'
        AND a.status = 'requested'
        AND a.provider_accepted_at IS NULL
        AND a.requested_at < now() - interval '3 minutes'
    ) AS stuck_offers
  FROM public.lead_routing_delivery_attempts a
  GROUP BY a.opportunity_id
),
ev AS (
  SELECT
    e.opportunity_id,
    bool_or(e.event_type = 'manager_assigned') AS manager_assigned
  FROM public.lead_routing_events e
  GROUP BY e.opportunity_id
),
eb AS (
  -- EasyBroker side effects (nota RESPONSABLE + marcar Atendida).
  -- Final state comes from the ledger; attempts only give the timestamps, so a
  -- retried or manually reconciled effect no longer reads as failed.
  SELECT
    l.opportunity_id,
    bool_and(lg.note_state = 'succeeded') AS note_ok,
    max(fx.finished_at) FILTER (WHERE fx.effect_kind = 'note' AND fx.ok) AS note_at,
    bool_and(lg.attended_state IN ('succeeded', 'skipped')) AS attended_ok,
    max(fx.finished_at) FILTER (WHERE fx.effect_kind = 'attended' AND fx.ok) AS attended_at,
    bool_or(lg.close_state IN ('manual_review', 'exhausted')) AS any_failed
  FROM public.easybroker_i24_request_links l
  JOIN public.easybroker_effect_ledger lg ON lg.eb_request_id = l.eb_request_id
  LEFT JOIN public.easybroker_effect_attempts fx ON fx.eb_request_id = l.eb_request_id
  GROUP BY l.opportunity_id
)
SELECT
  o.opportunity_id,
  o.created_at,
  COALESCE(NULLIF(c.lead_name, ''), NULLIF(cap.offer_context->>'name', ''), cap.offer_context->>'lead_name') AS lead_name,
  COALESCE(NULLIF(c.lead_phone, ''), o.e164_phone, cap.offer_context->>'phone', cap.offer_context->>'lead_phone') AS lead_phone,
  o.property_id,
  COALESCE(cap.offer_context->>'property_title',
           NULLIF(concat_ws(' · ', cap.offer_context->>'property', cap.offer_context->>'address'), ''),
           c.current_property) AS property_title,
  cap.offer_context->>'easybroker_url' AS easybroker_url,
  o.state,
  o.routing_tier,
  o.assigned_agent_id,
  ag.name AS assigned_name,
  ag.role AS assigned_role,
  o.assigned_at,
  CASE
    WHEN o.external_evidence->>'v3_final_route' = 'unassigned' OR o.state = 'unassigned'
      THEN 'unassigned'
    WHEN o.accepted_at IS NOT NULL THEN 'claim'
    WHEN ev.manager_assigned OR o.external_evidence->>'v3_final_route' = 'sandy' THEN 'sandy_fallback'
    WHEN o.assigned_agent_id IS NOT NULL THEN 'direct'
    ELSE NULL
  END AS assignment_method,
  CASE
    WHEN o.accepted_at IS NOT NULL AND ca.delivered_base IS NOT NULL
      THEN round(EXTRACT(EPOCH FROM (o.accepted_at - ca.delivered_base)) / 60.0)::int
    ELSE NULL
  END AS minutes_to_claim,
  att.owner_offer_delivered_at,
  att.guard_offer_delivered_at,
  att.sandy_notice_delivered_at,
  eb.note_ok AS eb_note_ok,
  eb.note_at AS eb_note_at,
  eb.attended_ok AS eb_attended_ok,
  eb.attended_at AS eb_attended_at,
  o.v3_night_queued_at AS night_queued_at,
  o.v3_night_released_at AS night_released_at,
  cap.route_dispatch_status AS dispatch_status,
  -- One human-readable reason, highest severity first. NULL = nothing wrong.
  (CASE
    WHEN o.state IN ('closed_won', 'closed_lost') THEN NULL
    WHEN cap.route_dispatch_status = 'manual_review'
      THEN 'Captura en revision manual: requiere resolver el motivo registrado'
    WHEN COALESCE(att.stuck_offers, 0) > 0
      THEN 'Oferta pedida hace mas de 3 min sin enviar'
    WHEN o.assigned_agent_id IS NULL
         AND o.state <> 'unassigned'
         AND o.expires_at IS NOT NULL
         AND o.expires_at < now() - interval '2 minutes'
      THEN 'Oferta vencida sin escalar'
    WHEN eb.any_failed
      THEN 'Efecto EasyBroker fallido (nota o Atendida)'
    WHEN o.assigned_agent_id IS NULL
         AND o.state <> 'unassigned'
         AND cap.route_dispatch_status IN ('pending', 'failed', 'leased')
         AND cap.happened_at < now() - interval '30 minutes'
         AND (NULLIF(btrim(o.property_id), '') IS NULL
              OR (o.state <> 'queued_night'
                  AND COALESCE(cap.route_dispatch_next_attempt_at, cap.happened_at) <= now()))
      THEN CASE WHEN NULLIF(btrim(o.property_id), '') IS NULL
        THEN 'Referencia EasyBroker pendiente por mas de 30 min: reparto detenido'
        ELSE 'Captura pendiente de reparto por mas de 30 min' END
    WHEN o.assigned_agent_id IS NOT NULL
         AND o.assigned_at < now() - interval '30 minutes'
         AND (NOT COALESCE(eb.note_ok, false) OR NOT COALESCE(eb.attended_ok, false))
      THEN 'Asignado sin cierre EasyBroker verificado por mas de 30 min'
    ELSE NULL
  END) AS problem_reason,
  (o.state NOT IN ('closed_won', 'closed_lost') AND COALESCE((cap.route_dispatch_status = 'manual_review'
    OR COALESCE(att.stuck_offers, 0) > 0
    OR (o.assigned_agent_id IS NULL
        AND o.state <> 'unassigned'
        AND o.expires_at IS NOT NULL
        AND o.expires_at < now() - interval '2 minutes')
    OR COALESCE(eb.any_failed, false)
    OR (o.assigned_agent_id IS NULL
        AND o.state <> 'unassigned'
        AND cap.route_dispatch_status IN ('pending', 'failed', 'leased')
        AND cap.happened_at < now() - interval '30 minutes'
        AND (NULLIF(btrim(o.property_id), '') IS NULL
             OR (o.state <> 'queued_night'
                 AND COALESCE(cap.route_dispatch_next_attempt_at, cap.happened_at) <= now())))
    OR (o.assigned_agent_id IS NOT NULL
        AND o.assigned_at < now() - interval '30 minutes'
        AND (NOT COALESCE(eb.note_ok, false) OR NOT COALESCE(eb.attended_ok, false)))), false)) AS has_problem
FROM public.lead_routing_opportunities o
LEFT JOIN public.agents ag ON ag.agent_id = o.assigned_agent_id
LEFT JOIN public.conversations c ON c.conversation_id = o.conversation_id
LEFT JOIN att ON att.opportunity_id = o.opportunity_id
LEFT JOIN ev ON ev.opportunity_id = o.opportunity_id
LEFT JOIN eb ON eb.opportunity_id = o.opportunity_id
LEFT JOIN LATERAL (
  SELECT e.offer_context, e.route_dispatch_status, e.happened_at, e.route_dispatch_next_attempt_at
  FROM public.i24_capture_events e
  WHERE e.opportunity_id = o.opportunity_id
  ORDER BY e.capture_event_id DESC
  LIMIT 1
) cap ON true
LEFT JOIN LATERAL (
  -- The offer addressed to the agent who ended up assigned: its delivery is the claim clock base.
  SELECT COALESCE(a.delivered_at, a.provider_accepted_at, a.requested_at) AS delivered_base
  FROM public.lead_routing_delivery_attempts a
  WHERE a.opportunity_id = o.opportunity_id
    AND a.delivery_kind = 'offer'
    AND a.target_agent_id = o.assigned_agent_id
  ORDER BY a.requested_at DESC
  LIMIT 1
) ca ON true
WHERE o.v3_enabled;

COMMENT ON VIEW public.v3_leads_dashboard IS
  'Read-only flattened V3 lead view for the dashboard (/leads-v3). Derived from lead_routing_* , i24_capture_events and easybroker_effect_attempts; never written to.';

REVOKE ALL ON TABLE public.v3_leads_dashboard FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.v3_leads_dashboard TO authenticated;
GRANT SELECT ON TABLE public.v3_leads_dashboard TO service_role;

-- 12. Grants mirror the neighbouring migrations (CREATE OR REPLACE keeps the
-- existing ACL; these are the explicit, auditable statements).
REVOKE ALL ON FUNCTION public.v3_mark_unassigned(BIGINT,TEXT,BIGINT,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v3_mark_unassigned(BIGINT,TEXT,BIGINT,TIMESTAMPTZ)
  TO service_role;
REVOKE ALL ON FUNCTION public.claim_v3_easybroker_effects(INTEGER,TIMESTAMPTZ,INTERVAL)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_v3_easybroker_effects(INTEGER,TIMESTAMPTZ,INTERVAL)
  TO service_role;
REVOKE ALL ON FUNCTION public.claim_v3_easybroker_request_creations(INTEGER,TIMESTAMPTZ,INTERVAL)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_v3_easybroker_request_creations(INTEGER,TIMESTAMPTZ,INTERVAL)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.finish_v3_easybroker_effect(
  BIGINT, UUID, TEXT, BOOLEAN, JSONB, TIMESTAMPTZ
) TO service_role;
REVOKE ALL ON FUNCTION public.v3_day_sweep() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v3_day_sweep() TO service_role;
