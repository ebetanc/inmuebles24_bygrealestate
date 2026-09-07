-- Only captures produced by the fast reader after explicit activation qualify.
CREATE TABLE public.v3_day_settings (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  enabled_at timestamptz
);
INSERT INTO public.v3_day_settings(singleton) VALUES (true);
ALTER TABLE public.v3_day_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.v3_day_settings FROM anon, authenticated;
GRANT SELECT ON public.v3_day_settings TO service_role;

ALTER TABLE public.i24_capture_events
  ADD COLUMN portal_received_at timestamptz,
  ADD COLUMN day_deadline_at timestamptz,
  ADD COLUMN day_hold_reason text;
CREATE INDEX i24_day_deadline_idx ON public.i24_capture_events(day_deadline_at)
  WHERE day_deadline_at IS NOT NULL;

CREATE FUNCTION public.v3_day_capture_init() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE arrived timestamptz; activated timestamptz;
BEGIN
  IF NEW.offer_context->>'day_sla_version' IS DISTINCT FROM '1' THEN RETURN NEW; END IF;
  arrived := (NEW.offer_context->>'portal_received_at')::timestamptz;
  IF arrived IS NULL OR arrived > clock_timestamp()+interval '5 seconds' THEN
    RAISE EXCEPTION 'invalid original portal arrival';
  END IF;
  NEW.portal_received_at := arrived;
  SELECT enabled_at INTO activated FROM public.v3_day_settings WHERE singleton;
  IF activated IS NULL OR arrived < activated
     OR (arrived AT TIME ZONE 'America/Mexico_City')::time < time '08:05'
     OR (arrived AT TIME ZONE 'America/Mexico_City')::time >= time '20:00' THEN
    RETURN NEW;
  END IF;
  NEW.day_deadline_at := arrived + interval '15 minutes';
  NEW.happened_at := arrived;
  IF NEW.disposition = 'created_new'
     AND COALESCE(NEW.offer_context->>'status','') NOT IN ('Pendiente','') THEN
    NEW.day_hold_reason := 'portal_already_contacted_without_capture';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER v3_day_capture_init BEFORE INSERT ON public.i24_capture_events
FOR EACH ROW EXECUTE FUNCTION public.v3_day_capture_init();

CREATE FUNCTION public.v3_day_deadline(p_capture_id bigint DEFAULT NULL,
  p_opportunity_id bigint DEFAULT NULL,p_request_id bigint DEFAULT NULL)
RETURNS timestamptz LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT min(c.day_deadline_at) FROM public.i24_capture_events c
 WHERE (p_capture_id IS NOT NULL AND c.capture_event_id=p_capture_id)
    OR (p_opportunity_id IS NOT NULL AND c.opportunity_id=p_opportunity_id
        AND c.disposition='created_new')
    OR (p_request_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.easybroker_i24_request_links l
        WHERE l.eb_request_id=p_request_id AND l.i24_capture_event_id=c.capture_event_id));
$$;

CREATE FUNCTION public.v3_day_allowed(p_capture_id bigint DEFAULT NULL,
  p_opportunity_id bigint DEFAULT NULL,p_request_id bigint DEFAULT NULL)
RETURNS boolean LANGUAGE sql VOLATILE SET search_path='' AS $$
 SELECT (public.v3_day_deadline(p_capture_id,p_opportunity_id,p_request_id) IS NULL
     OR public.v3_day_deadline(p_capture_id,p_opportunity_id,p_request_id)
          > clock_timestamp()+interval '10 seconds')
 AND NOT EXISTS (SELECT 1 FROM public.i24_capture_events c
   WHERE c.day_hold_reason IS NOT NULL
     AND (c.capture_event_id=p_capture_id OR c.opportunity_id=p_opportunity_id
       OR EXISTS (SELECT 1 FROM public.easybroker_i24_request_links l
           WHERE l.eb_request_id=p_request_id AND l.i24_capture_event_id=c.capture_event_id)));
$$;

CREATE FUNCTION public.v3_day_protect_assignment() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF (NEW.assigned_agent_id IS DISTINCT FROM OLD.assigned_agent_id
     OR NEW.routing_tier IS DISTINCT FROM OLD.routing_tier
     OR NEW.delivery_requested_at IS DISTINCT FROM OLD.delivery_requested_at)
    AND NOT public.v3_day_allowed(NULL,NEW.opportunity_id,NULL) THEN
   RAISE EXCEPTION 'day_deadline_expired_or_held';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER v3_day_protect_assignment BEFORE UPDATE ON public.lead_routing_opportunities
FOR EACH ROW EXECUTE FUNCTION public.v3_day_protect_assignment();

CREATE FUNCTION public.v3_day_protect_offer() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF NOT public.v3_day_allowed(NEW.capture_event_id,NEW.opportunity_id,NULL) THEN
   RAISE EXCEPTION 'day_deadline_expired_or_held';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER v3_day_protect_offer BEFORE INSERT ON public.lead_routing_delivery_attempts
FOR EACH ROW EXECUTE FUNCTION public.v3_day_protect_offer();

CREATE TABLE public.v3_day_incidents (
 capture_event_id bigint PRIMARY KEY REFERENCES public.i24_capture_events(capture_event_id),
 opportunity_id bigint REFERENCES public.lead_routing_opportunities(opportunity_id),
 reason text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 notification_state text NOT NULL DEFAULT 'pending'
   CHECK(notification_state IN ('pending','claimed','accepted','unknown')),
 notification_token uuid, provider_message_id text, notified_at timestamptz
);
ALTER TABLE public.v3_day_incidents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.v3_day_incidents FROM anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.v3_day_incidents TO service_role;

CREATE FUNCTION public.v3_day_sweep() RETURNS integer
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE total integer;
BEGIN
 INSERT INTO public.v3_day_incidents(capture_event_id,opportunity_id,reason)
 SELECT c.capture_event_id,c.opportunity_id,COALESCE(c.day_hold_reason,
   CASE WHEN c.contactado_status <> 'verified' THEN 'contactado_not_verified'
    WHEN c.route_dispatch_status <> 'dispatched' THEN 'route_not_dispatched'
    WHEN o.assigned_agent_id IS NULL THEN 'responsible_not_assigned'
    ELSE 'easybroker_not_closed' END)
 FROM public.i24_capture_events c
 LEFT JOIN public.lead_routing_opportunities o ON o.opportunity_id=c.opportunity_id
 WHERE c.day_deadline_at IS NOT NULL
   AND (c.day_hold_reason IS NOT NULL OR (c.day_deadline_at <= clock_timestamp()
     AND NOT COALESCE((c.contactado_status='verified' AND c.contactado_verified_at <= c.day_deadline_at
       AND c.route_dispatch_status='dispatched' AND c.route_dispatched_at <= c.day_deadline_at
       AND o.assigned_agent_id IS NOT NULL AND o.assigned_at <= c.day_deadline_at
       AND EXISTS (SELECT 1 FROM public.lead_routing_delivery_attempts a
         WHERE a.target_agent_id=o.assigned_agent_id
           AND (a.capture_event_id=c.capture_event_id
             OR (c.disposition='active_duplicate' AND a.opportunity_id=c.opportunity_id))
           AND a.delivered_at IS NOT NULL AND a.delivered_at <= c.day_deadline_at)
       AND EXISTS (SELECT 1 FROM public.easybroker_effect_ledger e
         WHERE e.opportunity_id=c.opportunity_id AND e.note_state='succeeded'
          AND e.attended_state='succeeded' AND e.updated_at <= c.day_deadline_at)),false)))
 ON CONFLICT (capture_event_id) DO NOTHING;
 GET DIAGNOSTICS total=ROW_COUNT;
 RETURN total;
END $$;

-- Do not recycle a claimed alert after an ambiguous provider response.
CREATE FUNCTION public.v3_day_claim_alerts() RETURNS TABLE(capture_event_id bigint,
 opportunity_id bigint,property_id text,manager_phone text,reason text,notification_token uuid)
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 PERFORM public.v3_day_sweep();
 RETURN QUERY WITH picked AS (
  SELECT i.capture_event_id FROM public.v3_day_incidents i
  WHERE i.notification_state='pending' ORDER BY i.created_at LIMIT 20
  FOR UPDATE SKIP LOCKED
 ), claimed AS (
  UPDATE public.v3_day_incidents i SET notification_state='claimed',notification_token=gen_random_uuid()
  FROM picked p WHERE i.capture_event_id=p.capture_event_id RETURNING i.*
 ) SELECT i.capture_event_id,i.opportunity_id,c.property_public_id,a.whatsapp_number,
   i.reason,i.notification_token FROM claimed i
 JOIN public.i24_capture_events c USING(capture_event_id)
 JOIN public.agents a ON a.agent_id='agent_manager';
END $$;

REVOKE ALL ON FUNCTION public.v3_day_capture_init(),public.v3_day_protect_assignment(),
 public.v3_day_protect_offer(),public.v3_day_deadline(bigint,bigint,bigint),
 public.v3_day_allowed(bigint,bigint,bigint),public.v3_day_sweep(),public.v3_day_claim_alerts()
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.v3_day_capture_init(),public.v3_day_protect_assignment(),
 public.v3_day_protect_offer(),public.v3_day_deadline(bigint,bigint,bigint),
 public.v3_day_allowed(bigint,bigint,bigint),public.v3_day_sweep(),public.v3_day_claim_alerts()
 TO service_role;

-- Fresh production definition plus deadline predicates: claim_v3_i24_contact_effects
CREATE OR REPLACE FUNCTION public.claim_v3_i24_contact_effects(p_limit integer DEFAULT 20, p_now timestamp with time zone DEFAULT now())
 RETURNS TABLE(capture_event_id bigint, opportunity_id bigint, i24_lead_id text, lease_token uuid, attempt integer)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
#variable_conflict error
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid V3 Contactado claim input';
  END IF;
  RETURN QUERY
  WITH candidates AS (
    SELECT e.capture_event_id
    FROM public.i24_capture_events e
    JOIN public.lead_routing_opportunities o
      ON o.opportunity_id = e.opportunity_id
    WHERE o.v3_enabled
      AND public.v3_day_allowed(e.capture_event_id,NULL,NULL)
      AND e.opportunity_id IS NOT NULL
      AND e.disposition <> 'non_routable'
      -- Contactado is before routing, so waiting for dispatched would deadlock.
      -- A valid, matching property plus a pending handoff is route readiness.
      AND e.route_dispatch_status = 'pending'
      AND UPPER(BTRIM(e.property_public_id)) ~ '^EB-[A-Z0-9]{4,}$'
      AND UPPER(BTRIM(o.property_id)) = UPPER(BTRIM(e.property_public_id))
      AND e.contactado_status IN ('pending', 'failed', 'leased')
      AND (
        e.contactado_status IN ('pending', 'failed')
        OR (
          e.contactado_status = 'leased'
          AND e.contactado_lease_expires_at <= p_now
        )
      )
      AND COALESCE(e.contactado_next_attempt_at, p_now) <= p_now
    ORDER BY e.contactado_next_attempt_at NULLS FIRST, e.capture_event_id
    FOR UPDATE OF e SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    UPDATE public.i24_capture_events e
    SET contactado_status = 'leased',
        contactado_lease_token = gen_random_uuid(),
        contactado_lease_expires_at = p_now + INTERVAL '2 minutes',
        contactado_attempts = e.contactado_attempts + 1
    FROM candidates c
    WHERE e.capture_event_id = c.capture_event_id
    RETURNING e.capture_event_id, e.opportunity_id, e.external_event_id,
      e.contactado_lease_token, e.contactado_attempts
  )
  SELECT c.capture_event_id, c.opportunity_id, c.external_event_id,
    c.contactado_lease_token, c.contactado_attempts
  FROM claimed c;
END;
$function$;

-- Fresh production definition plus deadline predicates: claim_v3_route_dispatches
CREATE OR REPLACE FUNCTION public.claim_v3_route_dispatches(p_limit integer DEFAULT 20, p_now timestamp with time zone DEFAULT now())
 RETURNS TABLE(capture_event_id bigint, opportunity_id bigint, disposition text, i24_lead_id text, property_public_id text, offer_context jsonb, lease_token uuid, attempt integer)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
#variable_conflict error
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid V3 route dispatch claim input';
  END IF;
  -- The scraper calls this claim on every run. This idempotent catch-up keeps a
  -- missed WF7 cron or a batch larger than 100 from stranding V3 until tomorrow.
  PERFORM public.v3_release_night_queue(500, p_now);
  RETURN QUERY
  WITH candidates AS (
    SELECT e.capture_event_id
    FROM public.i24_capture_events e
    JOIN public.lead_routing_opportunities o
      ON o.opportunity_id = e.opportunity_id
    WHERE o.v3_enabled
      AND public.v3_day_allowed(e.capture_event_id,NULL,NULL)
      AND o.state <> 'queued_night'
      AND e.contactado_status = 'verified'
      AND e.disposition <> 'non_routable'
      AND UPPER(BTRIM(e.property_public_id)) ~ '^EB-[A-Z0-9]{4,}$'
      AND UPPER(BTRIM(o.property_id)) = UPPER(BTRIM(e.property_public_id))
      AND e.route_dispatch_status IN ('pending', 'failed', 'leased')
      AND (
        e.route_dispatch_status IN ('pending', 'failed')
        OR e.route_dispatch_lease_expires_at <= p_now
      )
      AND COALESCE(
        e.route_dispatch_next_attempt_at,
        CASE
          WHEN (e.happened_at AT TIME ZONE 'America/Mexico_City')::TIME
                 >= TIME '20:00:00'
          THEN (
            (e.happened_at AT TIME ZONE 'America/Mexico_City')::DATE
              + 1 + TIME '08:05:00'
          ) AT TIME ZONE 'America/Mexico_City'
          WHEN (e.happened_at AT TIME ZONE 'America/Mexico_City')::TIME
                 < TIME '08:05:00'
          THEN (
            (e.happened_at AT TIME ZONE 'America/Mexico_City')::DATE
              + TIME '08:05:00'
          ) AT TIME ZONE 'America/Mexico_City'
          ELSE p_now
        END
      ) <= p_now
    ORDER BY e.route_dispatch_next_attempt_at NULLS FIRST, e.capture_event_id
    FOR UPDATE OF e SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    UPDATE public.i24_capture_events e
    SET route_dispatch_status = 'leased',
        route_dispatch_lease_token = gen_random_uuid(),
        route_dispatch_lease_expires_at = p_now + INTERVAL '2 minutes',
        route_dispatch_attempts = e.route_dispatch_attempts + 1
    FROM candidates c
    WHERE e.capture_event_id = c.capture_event_id
    RETURNING e.*
  )
  SELECT c.capture_event_id, c.opportunity_id, c.disposition,
    c.external_event_id, c.property_public_id, c.offer_context,
    c.route_dispatch_lease_token, c.route_dispatch_attempts
  FROM claimed c;
END;
$function$;

-- Fresh production definition plus deadline predicates: claim_v3_easybroker_request_creations
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
  JOIN public.agents a ON a.agent_id=o.assigned_agent_id
  WHERE (e.capture_event_id IN (107,108)
         OR e.happened_at >= TIMESTAMPTZ '2026-08-28T17:00:05.020Z')
    AND public.v3_day_allowed(e.capture_event_id,NULL,NULL)
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
$function$;

-- Fresh production definition plus deadline predicates: reserve_v3_easybroker_request_creation
CREATE OR REPLACE FUNCTION public.reserve_v3_easybroker_request_creation(p_capture_event_id bigint, p_lease_token uuid, p_now timestamp with time zone DEFAULT now(), p_manual_retry boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE r public.easybroker_contact_request_creation_ledger;
BEGIN
  IF NOT public.v3_day_allowed(p_capture_event_id,NULL,NULL) THEN
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

-- Fresh production definition plus deadline predicates: claim_v3_easybroker_effects
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
  -- required to make the request actionable.
  UPDATE public.easybroker_effect_ledger e
  SET responsible_agent_id = a.agent_id,
      responsible_first_name = split_part(
        regexp_replace(BTRIM(a.name), '\s+', ' ', 'g'), ' ', 1
      ),
      close_state = 'pending',
      note_next_retry_at = p_now,
      attended_next_retry_at = p_now,
      next_retry_at = p_now,
      updated_at = p_now
  FROM public.lead_routing_opportunities o
  JOIN public.agents a ON a.agent_id = o.assigned_agent_id
  WHERE e.opportunity_id = o.opportunity_id
    AND e.close_state = 'awaiting_responsible'
    AND o.state IN ('assigned','closed_won')
    AND o.assigned_agent_id IS NOT NULL
    AND NULLIF(BTRIM(a.name), '') IS NOT NULL;

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
    v_attended_due := r.attended_state IN ('pending','failed')
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
END; $function$;

-- Fresh production definition plus deadline predicates: v3_claim_delivery_attempts
CREATE OR REPLACE FUNCTION public.v3_claim_delivery_attempts(p_limit integer DEFAULT 20, p_now timestamp with time zone DEFAULT now())
 RETURNS SETOF lead_routing_delivery_attempts
 LANGUAGE sql
 SET search_path TO ''
AS $function$
  WITH candidates AS (
    SELECT a.attempt_id
    FROM public.lead_routing_delivery_attempts AS a
    JOIN public.lead_routing_opportunities AS o
      ON o.opportunity_id = a.opportunity_id
    WHERE public.v3_day_allowed(a.capture_event_id,a.opportunity_id,NULL)
      AND p_limit BETWEEN 1 AND 200
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
$function$;

-- Fresh production definition plus deadline predicates: claim_v3_delivery
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
  IF v_opp.current_delivery_attempt_id IS DISTINCT FROM v_attempt.attempt_id THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'attempt_not_current');
  END IF;
  IF NOT v_opp.v3_enabled OR v_attempt.delivery_kind IS DISTINCT FROM 'offer'
     OR v_attempt.capture_event_id IS DISTINCT FROM p_capture_event_id
     OR v_attempt.routing_tier NOT IN ('owner', 'primary_guard')
     OR v_opp.routing_tier IS DISTINCT FROM v_attempt.routing_tier THEN
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
  -- Production stores canonical digits without a leading plus, while Meta may
  -- send either that representation or display punctuation.  Validate the
  -- complete raw value first, then compare one canonical 8-15 digit form.
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

  -- The opportunity deadline is the sole authority; WF3b cannot extend it.
  v_deadline := v_opp.expires_at;
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
  IF v_opp.assigned_agent_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', TRUE,
      'outcome', CASE WHEN v_opp.assigned_agent_id = BTRIM(p_sender_agent_id)
                      THEN 'already_assigned' ELSE 'already_assigned_other' END,
      'opportunity_id', p_opportunity_id, 'assigned_agent_id', v_opp.assigned_agent_id);
  END IF;
  IF v_opp.routing_tier NOT IN ('owner', 'primary_guard')
     OR v_opp.state NOT IN ('owner_open', 'primary_guard_open', 'delivered') THEN
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

-- Fresh production definition plus deadline predicates: v3_route_ready_opportunity
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
    PERFORM public.v3_assign_sandy(p_opportunity_id,'guard_unavailable',p_capture_event_id,p_now);
    RETURN jsonb_build_object('state','assigned','tier','sandy','opportunity_id',p_opportunity_id);
  END IF;
  UPDATE public.lead_routing_opportunities SET state='guard_delivery_pending', routing_tier='primary_guard', updated_at=p_now
  WHERE opportunity_id=p_opportunity_id AND assigned_agent_id IS NULL;
  v_attempt_id := public.v3_request_offer(p_capture_event_id,'primary_guard',
    'v3:guard:'||p_opportunity_id::TEXT||':'||p_capture_event_id::TEXT,
    v_guard.agent_id,v_guard.whatsapp_number);
  RETURN jsonb_build_object('state','guard_delivery_requested','tier','primary_guard','attempt_id',v_attempt_id,'opportunity_id',p_opportunity_id,'capture_event_id',p_capture_event_id);
END;
$function$;

-- Fresh production definition plus deadline predicates: v3_advance_routing_tier
CREATE OR REPLACE FUNCTION public.v3_advance_routing_tier(p_opportunity_id bigint, p_expected_tier text, p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
  IF NOT FOUND OR NOT v_opp.v3_enabled OR v_opp.assigned_agent_id IS NOT NULL THEN
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
      PERFORM public.v3_assign_sandy(
        p_opportunity_id,
        CASE WHEN NOT v_guard_found THEN 'guard_unavailable' ELSE 'owner_equals_guard' END,
        v_attempt.capture_event_id,
        p_now
      );
      RETURN jsonb_build_object('state','assigned','tier','sandy','opportunity_id',p_opportunity_id);
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
  PERFORM public.v3_assign_sandy(
    p_opportunity_id,
    'guard_expired',
    v_attempt.capture_event_id,
    p_now
  );
  RETURN jsonb_build_object('state','assigned','tier','sandy','opportunity_id',p_opportunity_id);
END;
$function$;
