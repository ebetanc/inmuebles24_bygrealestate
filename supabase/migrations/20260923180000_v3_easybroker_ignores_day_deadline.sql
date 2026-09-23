-- The 15-minute day deadline stops WhatsApp routing, not EasyBroker bookkeeping.
-- Leads whose owner+guard cascade ends near the deadline (#938, #949/#950 on
-- 2026-09-22/23) froze without their EasyBroker request or responsible note.
-- EasyBroker gates now only honor a manual hold (day_hold_reason); the creation
-- claim keeps its 24 h / post-cutover window, so no old lead is reopened.
CREATE OR REPLACE FUNCTION public.v3_day_not_held(p_capture_id bigint DEFAULT NULL,
 p_opportunity_id bigint DEFAULT NULL,p_request_id bigint DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT NOT EXISTS (SELECT 1 FROM public.i24_capture_events c
   WHERE c.day_hold_reason IS NOT NULL AND (
     (p_capture_id IS NOT NULL AND c.capture_event_id=p_capture_id)
     OR (p_capture_id IS NULL AND p_request_id IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.easybroker_i24_request_links l
       WHERE l.eb_request_id=p_request_id AND l.i24_capture_event_id=c.capture_event_id))
     OR (p_capture_id IS NULL AND p_request_id IS NULL AND c.opportunity_id=p_opportunity_id)));
$$;
REVOKE ALL ON FUNCTION public.v3_day_not_held(bigint,bigint,bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v3_day_not_held(bigint,bigint,bigint) TO service_role;

CREATE OR REPLACE FUNCTION public.claim_v3_easybroker_request_creations(p_limit integer DEFAULT 20, p_now timestamp with time zone DEFAULT now(), p_lease_duration interval DEFAULT '00:02:00'::interval)
 RETURNS TABLE(capture_event_id bigint, opportunity_id bigint, i24_lead_id text, property_public_id text, offer_context jsonb, normalized_email text, e164_phone text, correlation_window_start_at timestamp with time zone, correlation_horizon_at timestamp with time zone, remote_request_id bigint, lease_token uuid, lease_expires_at timestamp with time zone, post_allowed boolean)
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
         l.lease_expires_at, l.post_attempt_count=0
  FROM claimed l
  JOIN public.i24_capture_events e ON e.capture_event_id=l.capture_event_id
  LEFT JOIN refreshed r ON r.capture_event_id=l.capture_event_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.reserve_v3_easybroker_request_creation(p_capture_event_id bigint, p_lease_token uuid, p_now timestamp with time zone DEFAULT now(), p_manual_retry boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$

DECLARE r public.easybroker_contact_request_creation_ledger;

BEGIN

  IF NOT public.v3_day_not_held(p_capture_event_id,NULL,NULL) THEN

    RETURN jsonb_build_object('ok',FALSE,'state','day_deadline_expired','post_allowed',FALSE);

  END IF;

  IF p_capture_event_id IS NULL OR p_lease_token IS NULL OR p_now IS NULL

     OR p_manual_retry IS NULL THEN

    RAISE EXCEPTION 'invalid EasyBroker creation reservation input';

  END IF;

  SELECT * INTO r FROM public.easybroker_contact_request_creation_ledger

    WHERE capture_event_id=p_capture_event_id FOR UPDATE;

  IF NOT FOUND OR r.state NOT IN ('pending','recovery')

     OR r.lease_token IS DISTINCT FROM p_lease_token

     OR r.lease_expires_at IS NULL OR r.lease_expires_at <= p_now THEN

    RETURN jsonb_build_object('ok',FALSE,'state','lease_conflict','post_allowed',FALSE);

  END IF;

  IF r.post_attempt_count >= 2 THEN

    RETURN jsonb_build_object('ok',TRUE,'state','retry_consumed','post_allowed',FALSE);

  END IF;

  IF p_manual_retry AND NOT (

       r.post_attempt_count=1 AND r.manual_retry_authorized_at IS NOT NULL

       AND r.manual_retry_consumed_at IS NULL AND r.remote_request_id IS NULL

     ) THEN

    RETURN jsonb_build_object('ok',TRUE,'state','retry_not_authorized','post_allowed',FALSE);

  END IF;

  IF NOT p_manual_retry AND r.post_attempt_count=1 THEN

    RETURN jsonb_build_object('ok',TRUE,'state','recovery','post_allowed',FALSE);

  END IF;

  IF EXISTS (SELECT 1 FROM public.easybroker_i24_request_links l

             WHERE l.i24_capture_event_id=p_capture_event_id) THEN

    RETURN jsonb_build_object('ok',TRUE,'state','already_linked','post_allowed',FALSE);

  END IF;

  UPDATE public.easybroker_contact_request_creation_ledger

    SET post_attempt_count=post_attempt_count+1, post_attempted_at=p_now,

        manual_retry_consumed_at=CASE WHEN p_manual_retry THEN p_now

          ELSE manual_retry_consumed_at END,

        updated_at=p_now

    WHERE capture_event_id=p_capture_event_id;

  RETURN jsonb_build_object('ok',TRUE,'state',CASE WHEN p_manual_retry

    THEN 'manual_retry_reserved' ELSE 'reserved' END,'post_allowed',TRUE);

END;

$function$;

CREATE OR REPLACE FUNCTION public.claim_v3_easybroker_effects(p_limit integer, p_now timestamp with time zone, p_lease_duration interval)
 RETURNS TABLE(eb_request_id bigint, opportunity_id bigint, responsible_first_name text, note_state text, attended_state text, lease_token uuid, lease_expires_at timestamp with time zone, note_due boolean, attended_due boolean, note_idempotency_key text, attended_idempotency_key text)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
      OR (o.state = 'unassigned' AND o.assigned_agent_id IS NULL)
    );

  FOR r IN
    SELECT e.*
    FROM public.easybroker_effect_ledger e
    WHERE public.v3_day_not_held(NULL,e.opportunity_id,e.eb_request_id)
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
$function$;
