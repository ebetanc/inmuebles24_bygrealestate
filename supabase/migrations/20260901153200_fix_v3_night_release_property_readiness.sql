-- V3 incident hardening: a portal lead must keep its property identity until
-- routing is durably ready, and night work must not reach n8n before 08:05.
-- This migration changes functions only. It deliberately contains no repair
-- for a concrete production opportunity.

CREATE OR REPLACE FUNCTION public.v3_intake(
  p_account_key TEXT,
  p_idempotency_key TEXT,
  p_source TEXT DEFAULT 'inmuebles24',
  p_external_id TEXT DEFAULT NULL,
  p_portal_person_id TEXT DEFAULT NULL,
  p_property_public_id TEXT DEFAULT NULL,
  p_email TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_offer_context JSONB DEFAULT '{}'::JSONB,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS TABLE(
  disposition TEXT,
  opportunity_id BIGINT,
  capture_event_id BIGINT,
  contactado_status TEXT,
  reason TEXT
)
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
#variable_conflict error
DECLARE
  v_existing public.i24_capture_events;
  v_existing_capture_id BIGINT;
  v_opp public.lead_routing_opportunities;
  v_capture public.i24_capture_events;
  v_account TEXT := NULLIF(BTRIM(p_account_key), '');
  v_source TEXT := LOWER(NULLIF(BTRIM(p_source), ''));
  v_idempotency TEXT := NULLIF(BTRIM(p_idempotency_key), '');
  v_external TEXT := NULLIF(BTRIM(p_external_id), '');
  v_portal TEXT := NULLIF(BTRIM(p_portal_person_id), '');
  v_email TEXT := NULLIF(LOWER(BTRIM(p_email)), '');
  v_phone TEXT;
  v_property_input TEXT := UPPER(NULLIF(BTRIM(p_property_public_id), ''));
  v_property TEXT := CASE
    WHEN v_property_input ~ '^EB-[A-Z0-9]{4,}$' THEN v_property_input
  END;
  v_identity TEXT;
  v_identity_reason TEXT;
  v_is_night BOOLEAN;
  v_route_not_before TIMESTAMPTZ;
  v_can_rearm BOOLEAN := FALSE;
  v_disposition TEXT;
  v_reason TEXT;
BEGIN
  IF v_account IS NULL OR v_idempotency IS NULL OR p_now IS NULL OR v_source <> 'inmuebles24' THEN
    RAISE EXCEPTION 'invalid V3 intake identity';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_account || ':' || v_source || ':' || v_idempotency, 0));

  SELECT e.* INTO v_existing
  FROM public.i24_capture_events AS e
  WHERE e.account_key = v_account AND e.idempotency_key = v_idempotency
  FOR UPDATE;

  IF NOT FOUND AND v_external IS NOT NULL THEN
    SELECT e.* INTO v_existing
    FROM public.i24_capture_events AS e
    WHERE e.account_key = v_account
      AND e.source = v_source
      AND e.external_event_id = v_external
    ORDER BY e.capture_event_id
    LIMIT 1
    FOR UPDATE;
  END IF;

  IF FOUND THEN
    v_existing_capture_id := v_existing.capture_event_id;
    -- An exact replay may repair only a missing property. It may never replace
    -- a non-null value or merge two conflicting open opportunities.
    IF v_existing.property_public_id IS NULL
       AND v_property IS NOT NULL
       AND v_existing.opportunity_id IS NOT NULL THEN
      PERFORM pg_advisory_xact_lock(hashtextextended(
        v_account || ':' || v_source || ':' ||
        COALESCE(v_existing.identity_key, 'missing') || ':' || v_property, 0));

      SELECT o.* INTO v_opp
      FROM public.lead_routing_opportunities AS o
      WHERE o.opportunity_id = v_existing.opportunity_id
      FOR UPDATE;

      IF FOUND
         AND v_opp.v3_enabled
         AND v_opp.identity_key IS NOT DISTINCT FROM v_existing.identity_key
         AND (
           v_opp.property_id IS NULL
           OR UPPER(BTRIM(v_opp.property_id)) = v_property
         )
         AND NOT EXISTS (
           SELECT 1
           FROM public.lead_routing_opportunities conflicting
           WHERE conflicting.opportunity_id <> v_opp.opportunity_id
             AND conflicting.v3_enabled
             AND conflicting.v3_account_key = v_account
             AND conflicting.identity_key IS NOT DISTINCT FROM v_opp.identity_key
             AND UPPER(BTRIM(conflicting.property_id)) = v_property
             AND conflicting.state NOT IN ('closed_won', 'closed_lost')
         ) THEN
        v_can_rearm := (
          v_existing.route_dispatched_at IS NULL
          AND v_opp.assigned_agent_id IS NULL
          AND v_opp.current_delivery_attempt_id IS NULL
          AND NOT EXISTS (
            SELECT 1
            FROM public.lead_routing_delivery_attempts attempt
            WHERE attempt.opportunity_id = v_opp.opportunity_id
          )
          AND NOT EXISTS (
            SELECT 1
            FROM public.lead_routing_events event
            WHERE event.idempotency_key =
              'v3-route-dispatched:' || v_existing_capture_id::TEXT
          )
        );

        UPDATE public.lead_routing_opportunities AS o
        SET property_id = COALESCE(o.property_id, v_property),
            v3_offer_context = COALESCE(o.v3_offer_context, '{}'::JSONB)
              || jsonb_build_object('property_public_id', v_property),
            updated_at = p_now
        WHERE o.opportunity_id = v_opp.opportunity_id;

        UPDATE public.i24_capture_events AS e
        SET property_public_id = v_property,
            offer_context = COALESCE(e.offer_context, '{}'::JSONB)
              || jsonb_build_object('property_public_id', v_property),
            reason = CASE
              WHEN e.reason = 'missing_property_pending_backfill' THEN NULL
              ELSE e.reason
            END,
            route_dispatch_status = CASE
              WHEN e.route_dispatch_status IN ('failed', 'manual_review')
               AND e.route_dispatch_last_error_code = 'missing_property_public_id'
               AND v_can_rearm
              THEN 'pending'
              ELSE e.route_dispatch_status
            END,
            route_dispatch_lease_token = CASE
              WHEN e.route_dispatch_status IN ('failed', 'manual_review')
               AND e.route_dispatch_last_error_code = 'missing_property_public_id'
               AND v_can_rearm
              THEN NULL
              ELSE e.route_dispatch_lease_token
            END,
            route_dispatch_lease_expires_at = CASE
              WHEN e.route_dispatch_status IN ('failed', 'manual_review')
               AND e.route_dispatch_last_error_code = 'missing_property_public_id'
               AND v_can_rearm
              THEN NULL
              ELSE e.route_dispatch_lease_expires_at
            END,
            route_dispatch_next_attempt_at = CASE
              WHEN e.route_dispatch_status IN ('failed', 'manual_review')
               AND e.route_dispatch_last_error_code = 'missing_property_public_id'
               AND v_can_rearm
              THEN GREATEST(
                COALESCE(e.route_dispatch_next_attempt_at, p_now), p_now
              )
              ELSE e.route_dispatch_next_attempt_at
            END
        WHERE e.capture_event_id = v_existing_capture_id
          AND e.property_public_id IS NULL;

        SELECT e.* INTO v_existing
        FROM public.i24_capture_events AS e
        WHERE e.capture_event_id = v_existing_capture_id;
      END IF;
    END IF;

    RETURN QUERY SELECT v_existing.disposition, v_existing.opportunity_id,
      v_existing.capture_event_id, v_existing.contactado_status,
      v_existing.reason;
    RETURN;
  END IF;

  v_phone := CASE
    WHEN BTRIM(COALESCE(p_phone, '')) ~ '^[+][0-9][0-9 ()-]*[0-9]$'
     AND REGEXP_REPLACE(BTRIM(p_phone), '[ ()-]', '', 'g') ~ '^[+][0-9]{8,15}$'
    THEN REGEXP_REPLACE(BTRIM(p_phone), '[ ()-]', '', 'g')
  END;
  IF v_portal IS NOT NULL THEN
    v_identity := 'portal:' || v_source || ':' || v_portal;
    v_identity_reason := 'portal_person_id';
  ELSIF v_email IS NOT NULL THEN
    v_identity := 'email:' || v_email;
    v_identity_reason := 'normalized_email';
  ELSIF v_phone IS NOT NULL THEN
    v_identity := 'phone:' || v_phone;
    v_identity_reason := 'e164_phone';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_account || ':' || v_source || ':' || COALESCE(v_identity, 'missing') || ':' ||
    COALESCE(v_property, 'missing'), 0));

  IF v_external IS NULL THEN
    v_disposition := 'non_routable';
    v_reason := 'missing_external_id';
  ELSIF v_identity IS NULL THEN
    v_disposition := 'non_routable';
    v_reason := 'missing_prospect_identity';
  END IF;

  IF v_disposition = 'non_routable' THEN
    INSERT INTO public.i24_capture_events(
      account_key, source, external_event_id, idempotency_key, portal_person_id,
      property_public_id, normalized_email, e164_phone, identity_key, disposition,
      reason, offer_context, contactado_status, route_dispatch_status, happened_at
    ) VALUES (
      v_account, v_source, v_external, v_idempotency, v_portal, v_property,
      v_email, v_phone, v_identity, v_disposition, v_reason,
      COALESCE(p_offer_context, '{}'::JSONB), 'manual_review', 'manual_review', p_now
    ) RETURNING * INTO v_capture;
    RETURN QUERY SELECT v_disposition, NULL::BIGINT, v_capture.capture_event_id,
      'manual_review'::TEXT, v_reason;
    RETURN;
  END IF;

  v_is_night := (
    (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '20:00:00'
    OR (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '08:05:00'
  );
  v_route_not_before := CASE
    WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '20:00:00'
    THEN (
      (p_now AT TIME ZONE 'America/Mexico_City')::DATE + 1 + TIME '08:05:00'
    ) AT TIME ZONE 'America/Mexico_City'
    WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '08:05:00'
    THEN (
      (p_now AT TIME ZONE 'America/Mexico_City')::DATE + TIME '08:05:00'
    ) AT TIME ZONE 'America/Mexico_City'
  END;

  SELECT o.* INTO v_opp
  FROM public.lead_routing_opportunities AS o
  WHERE o.v3_enabled
    AND o.v3_account_key = v_account
    AND o.identity_key = v_identity
    AND o.property_id IS NOT DISTINCT FROM v_property
    AND o.state NOT IN ('closed_won', 'closed_lost')
  ORDER BY o.opportunity_id
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    v_disposition := CASE WHEN v_opp.assigned_agent_id IS NULL
      THEN 'active_duplicate' ELSE 'returning_assigned' END;
  ELSE
    INSERT INTO public.lead_routing_opportunities(
      property_id, portal_person_id, normalized_email, e164_phone, identity_key,
      identity_reason, state, v3_enabled, v3_account_key, v3_source, v3_external_id,
      v3_offer_context, v3_contactado_status, v3_night_queued_at
    ) VALUES (
      v_property, v_portal, v_email, v_phone, v_identity, v_identity_reason,
      CASE WHEN v_is_night THEN 'queued_night' ELSE 'captured' END,
      TRUE, v_account, v_source, v_external, COALESCE(p_offer_context, '{}'::JSONB),
      'pending', CASE WHEN v_is_night THEN p_now END
    ) RETURNING * INTO v_opp;
    v_disposition := 'created_new';
  END IF;

  INSERT INTO public.i24_capture_events(
    account_key, source, external_event_id, idempotency_key, portal_person_id,
    property_public_id, normalized_email, e164_phone, identity_key, opportunity_id,
    disposition, reason, offer_context, contactado_status,
    route_dispatch_next_attempt_at, happened_at
  ) VALUES (
    v_account, v_source, v_external, v_idempotency, v_portal, v_property,
    v_email, v_phone, v_identity, v_opp.opportunity_id, v_disposition,
    CASE WHEN v_property IS NULL THEN 'missing_property_pending_backfill' END,
    COALESCE(p_offer_context, '{}'::JSONB), 'pending', v_route_not_before, p_now
  ) RETURNING * INTO v_capture;

  IF v_disposition = 'created_new' AND v_is_night AND v_phone IS NOT NULL THEN
    INSERT INTO public.night_queue(
      source, lead_phone, property_id, lead_email, queued_at, opportunity_id
    ) VALUES (
      v_source, v_phone, v_property, v_email, p_now, v_opp.opportunity_id
    ) ON CONFLICT DO NOTHING;
  END IF;

  INSERT INTO public.lead_routing_events(
    opportunity_id, event_type, idempotency_key, metadata
  ) VALUES (
    v_opp.opportunity_id,
    CASE WHEN v_disposition = 'created_new' THEN 'detected' ELSE 'deduplicated' END,
    'v3-intake:' || v_account || ':' || v_idempotency,
    jsonb_build_object('disposition', v_disposition, 'source', v_source,
      'external_id', v_external, 'capture_event_id', v_capture.capture_event_id)
  ) ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN QUERY SELECT v_disposition, v_opp.opportunity_id,
    v_capture.capture_event_id, v_capture.contactado_status,
    CASE WHEN v_property IS NULL
      THEN 'missing_property_pending_backfill' ELSE NULL END::TEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_v3_i24_contact_effects(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS TABLE(
  capture_event_id BIGINT,
  opportunity_id BIGINT,
  i24_lead_id TEXT,
  lease_token UUID,
  attempt INTEGER
)
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
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
$$;

CREATE OR REPLACE FUNCTION public.claim_v3_route_dispatches(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS TABLE(
  capture_event_id BIGINT,
  opportunity_id BIGINT,
  disposition TEXT,
  i24_lead_id TEXT,
  property_public_id TEXT,
  offer_context JSONB,
  lease_token UUID,
  attempt INTEGER
)
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
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
$$;

-- Release only a verified pending night capture whose explicit hold elapsed.
-- Preserved attempt/error evidence does not make a safely rearmed capture
-- ineligible. Historical failed/manual_review captures stay queued_night until
-- an explicitly approved, opportunity-specific CAS repairs them.
CREATE OR REPLACE FUNCTION public.v3_release_night_queue(
  p_limit INTEGER DEFAULT 100,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS SETOF BIGINT
LANGUAGE sql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
  WITH candidates AS (
    SELECT o.opportunity_id
    FROM public.lead_routing_opportunities o
    WHERE o.v3_enabled
      AND o.state = 'queued_night'
      AND o.assigned_agent_id IS NULL
      AND o.current_delivery_attempt_id IS NULL
      AND EXISTS (
        SELECT 1
        FROM public.i24_capture_events e
        WHERE e.opportunity_id = o.opportunity_id
          AND e.disposition = 'created_new'
          AND e.contactado_status = 'verified'
          AND e.route_dispatch_status = 'pending'
          AND e.route_dispatched_at IS NULL
          AND e.route_dispatch_lease_token IS NULL
          AND e.route_dispatch_lease_expires_at IS NULL
          AND e.route_dispatch_next_attempt_at IS NOT NULL
          AND e.route_dispatch_next_attempt_at <= p_now
          AND UPPER(BTRIM(e.property_public_id)) ~ '^EB-[A-Z0-9]{4,}$'
          AND UPPER(BTRIM(o.property_id)) = UPPER(BTRIM(e.property_public_id))
          AND NOT EXISTS (
            SELECT 1
            FROM public.lead_routing_delivery_attempts a
            WHERE a.opportunity_id = o.opportunity_id
          )
          AND NOT EXISTS (
            SELECT 1
            FROM public.lead_routing_events ev
            WHERE ev.idempotency_key =
              'v3-route-dispatched:' || e.capture_event_id::TEXT
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.night_queue nq
        WHERE nq.opportunity_id = o.opportunity_id
          AND nq.processed = FALSE
          AND nq.processing_status = 'processing'
          AND (nq.lease_expires_at IS NULL OR nq.lease_expires_at > p_now)
      )
      AND p_now IS NOT NULL
      AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '08:05:00'
      AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '20:00:00'
    ORDER BY o.v3_night_queued_at, o.opportunity_id
    FOR UPDATE SKIP LOCKED
    LIMIT p_limit
  ), released AS (
    UPDATE public.lead_routing_opportunities o
    SET state = 'captured',
        v3_night_released_at = p_now,
        updated_at = p_now
    FROM candidates c
    WHERE o.opportunity_id = c.opportunity_id
    RETURNING o.opportunity_id
  ), legacy_retired AS (
    -- V3 rows remain visible to the 08:00 report, but they are never a second
    -- 08:05 routing path. Retire the report row in the same release statement.
    UPDATE public.night_queue nq
    SET processed = TRUE,
        processing_status = 'processed',
        processed_at = COALESCE(nq.processed_at, p_now),
        lease_token = NULL,
        lease_expires_at = NULL
    FROM released r
    WHERE nq.opportunity_id = r.opportunity_id
      AND (
        nq.processed = FALSE
        OR nq.processing_status <> 'processed'
    )
    RETURNING nq.opportunity_id
  ), effect_barrier AS (
    SELECT COUNT(*) AS retired_count
    FROM legacy_retired
  )
  SELECT r.opportunity_id
  FROM released r
  CROSS JOIN effect_barrier;
$$;

-- WF7 may continue to process legacy overnight sources, but this database
-- boundary makes V3 rows ineligible before any WF7 safe-mode branch can run.
CREATE OR REPLACE FUNCTION public.claim_night_queue(
  p_batch_size INTEGER DEFAULT 100,
  p_now TIMESTAMPTZ DEFAULT NOW(),
  p_lease_duration INTERVAL DEFAULT INTERVAL '10 minutes'
)
RETURNS TABLE (
  queue_id BIGINT,
  opportunity_id BIGINT,
  conversation_id UUID,
  source TEXT,
  lead_phone TEXT,
  lead_name TEXT,
  property_id TEXT,
  lead_email TEXT,
  temperature TEXT,
  bot_summary TEXT,
  queued_at TIMESTAMPTZ,
  property_title TEXT,
  property_public_id TEXT,
  property_price TEXT,
  lease_token UUID,
  routing_idempotency_key TEXT
) AS $$
#variable_conflict error
DECLARE
  cdmx_time TIME;
BEGIN
  IF p_batch_size IS NULL OR p_batch_size < 1 OR p_batch_size > 500 THEN
    RAISE EXCEPTION 'batch size must be between 1 and 500';
  END IF;
  IF p_now IS NULL THEN
    RAISE EXCEPTION 'claim timestamp must not be null';
  END IF;
  IF p_lease_duration IS NULL
     OR p_lease_duration <= INTERVAL '0 seconds'
     OR p_lease_duration > INTERVAL '15 minutes' THEN
    RAISE EXCEPTION 'lease duration must be between 0 and 15 minutes';
  END IF;

  cdmx_time := (p_now AT TIME ZONE 'America/Mexico_City')::TIME;
  IF cdmx_time < TIME '08:05:00' OR cdmx_time >= TIME '20:00:00' THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH candidates AS MATERIALIZED (
    SELECT nq.id
    FROM public.night_queue AS nq
    WHERE nq.processed = FALSE
      AND nq.opportunity_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.lead_routing_opportunities AS o
        WHERE o.opportunity_id = nq.opportunity_id
          AND o.v3_enabled
      )
      AND (
        nq.processing_status = 'pending'
        OR (nq.processing_status = 'processing' AND nq.lease_expires_at <= p_now)
      )
    ORDER BY nq.queued_at, nq.id
    FOR UPDATE SKIP LOCKED
    LIMIT p_batch_size
  ), leased AS (
    UPDATE public.night_queue AS nq
    SET processing_status = 'processing',
        lease_token = gen_random_uuid(),
        lease_expires_at = p_now + p_lease_duration,
        processing_attempts = processing_attempts + 1
    FROM candidates AS c
    WHERE nq.id = c.id
    RETURNING nq.*
  )
  SELECT
    l.id,
    l.opportunity_id,
    l.conversation_id,
    l.source,
    l.lead_phone,
    l.lead_name,
    l.property_id,
    l.lead_email,
    l.temperature,
    l.bot_summary,
    l.queued_at,
    COALESCE(pc.payload->>'title', conv.current_property, l.property_id),
    conv.property_public_id,
    COALESCE(pc.payload->>'price', 'Precio por confirmar'),
    l.lease_token,
    'night-queue:' || l.id::TEXT
  FROM leased AS l
  LEFT JOIN public.conversations AS conv ON conv.conversation_id = l.conversation_id
  LEFT JOIN public.properties_cache AS pc ON pc.property_id = l.property_id
  ORDER BY l.queued_at, l.id;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog;

-- A verified assignee/note conflict is deterministic: retrying the same UI
-- state cannot make it safe to write. Park only those two codes for review;
-- transient read failures keep the existing bounded retry policy.
ALTER TABLE public.easybroker_effect_ledger
  DROP CONSTRAINT IF EXISTS easybroker_effect_ledger_close_state_check;
ALTER TABLE public.easybroker_effect_ledger
  ADD CONSTRAINT easybroker_effect_ledger_close_state_check
  CHECK (close_state IN (
    'awaiting_responsible', 'pending', 'retrying', 'exhausted',
    'completed', 'manual_review'
  ));

ALTER TABLE public.easybroker_effect_alerts
  DROP CONSTRAINT IF EXISTS easybroker_effect_alerts_alert_type_check;
ALTER TABLE public.easybroker_effect_alerts
  ADD CONSTRAINT easybroker_effect_alerts_alert_type_check
  CHECK (alert_type IN (
    'easybroker_effects_exhausted', 'easybroker_effect_manual_review'
  ));

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
  IF p_step = 'attended' AND l.attended_state = 'succeeded' THEN
    RETURN jsonb_build_object('ok', true, 'state', 'already_succeeded',
      'eb_request_id', p_eb_request_id, 'step', p_step);
  END IF;
  IF l.responsible_agent_id IS NULL
     OR NULLIF(BTRIM(l.responsible_first_name), '') IS NULL THEN
    RAISE EXCEPTION 'final responsible required before EasyBroker effects';
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
          note_next_retry_at = NULL, updated_at = p_now
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
         CASE WHEN e.note_state = 'succeeded' AND e.attended_state = 'succeeded'
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
END; $$;

COMMENT ON FUNCTION public.claim_v3_i24_contact_effects(INTEGER, TIMESTAMPTZ)
  IS 'Claims Contactado only after a valid capture/opportunity property mapping exists; Contactado remains the gate before V3 dispatch.';
COMMENT ON FUNCTION public.claim_v3_route_dispatches(INTEGER, TIMESTAMPTZ)
  IS 'Claims verified V3 handoffs only outside queued_night and with a valid matching property mapping.';
COMMENT ON FUNCTION public.v3_release_night_queue(INTEGER, TIMESTAMPTZ)
  IS 'Atomically releases only verified pending V3 night holds at 08:05 CDMX and retires their legacy report row; historical failed/manual_review captures remain queued for an explicitly approved CAS.';
COMMENT ON FUNCTION public.claim_night_queue(INTEGER, TIMESTAMPTZ, INTERVAL)
  IS 'Legacy V2 night claim. V3 opportunities are excluded at the database boundary and cannot reach WF7 safe-mode routing.';
COMMENT ON FUNCTION public.finish_v3_easybroker_effect(
  BIGINT, UUID, TEXT, BOOLEAN, JSONB, TIMESTAMPTZ
) IS 'Finishes an exact EasyBroker effect; deterministic assignee/note conflicts stop in manual_review without retry, while transient failures retain bounded retry.';
-- routing_safe_mode_state scope is V2 only. V3 uses its fixed owner-first
-- ladder and must never branch on this singleton.
COMMENT ON TABLE public.routing_safe_mode_state IS
  'Legacy V2-only circuit breaker. V3 must not branch on this singleton; history lives in routing_safe_mode_events and this row is the current V2 snapshot.';

REVOKE ALL ON FUNCTION public.v3_intake(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_v3_i24_contact_effects(
  INTEGER, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_v3_route_dispatches(
  INTEGER, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.v3_release_night_queue(
  INTEGER, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_night_queue(
  INTEGER, TIMESTAMPTZ, INTERVAL
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finish_v3_easybroker_effect(
  BIGINT, UUID, TEXT, BOOLEAN, JSONB, TIMESTAMPTZ
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.v3_intake(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_v3_i24_contact_effects(
  INTEGER, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_v3_route_dispatches(
  INTEGER, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION public.v3_release_night_queue(
  INTEGER, TIMESTAMPTZ
) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_night_queue(
  INTEGER, TIMESTAMPTZ, INTERVAL
) TO service_role;
GRANT EXECUTE ON FUNCTION public.finish_v3_easybroker_effect(
  BIGINT, UUID, TEXT, BOOLEAN, JSONB, TIMESTAMPTZ
) TO service_role;
