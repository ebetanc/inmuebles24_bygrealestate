-- Transactional fixture for V3 property backfill and guarded night release.
-- Run only against a disposable database with all migrations applied.
BEGIN;

DO $fixture$
DECLARE
  v_first RECORD;
  v_replay RECORD;
  v_conflict RECORD;
  v_manual_first RECORD;
  v_manual_replay RECORD;
  v_sent_first RECORD;
  v_sent_replay RECORD;
  v_assigned_first RECORD;
  v_returning_night RECORD;
  v_returning_contact RECORD;
  v_returning_route RECORD;
  v_night_missing_first RECORD;
  v_night_missing_replay RECORD;
  v_night_missing_contact RECORD;
  v_night_missing_route RECORD;
  v_contact_claim RECORD;
  v_night RECORD;
  v_boundary RECORD;
  v_night_contact_claim RECORD;
  v_property TEXT;
  v_state TEXT;
  v_status TEXT;
  v_error TEXT;
  v_attempts INTEGER;
  v_count INTEGER;
  v_processed BOOLEAN;
  v_next_at TIMESTAMPTZ;
  v_eb_request_id BIGINT := -9090101;
  v_eb_lease UUID := gen_random_uuid();
  v_finish JSONB;
BEGIN
  SELECT * INTO v_first
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:property-backfill', 'inmuebles24',
    'fixture-lead-property-backfill', 'fixture-person-property-backfill',
    NULL, 'property-backfill@example.test', '+525500000901',
    '{"listing_id":"fixture-listing-property-backfill"}'::JSONB,
    '2026-09-01T16:00:00Z'::TIMESTAMPTZ
  );

  IF v_first.capture_event_id IS NULL THEN
    RAISE EXCEPTION 'first intake did not create a capture';
  END IF;

  UPDATE public.i24_capture_events
  SET route_dispatch_status = 'failed',
      route_dispatch_attempts = 2,
      route_dispatch_last_error_code = 'missing_property_public_id'
  WHERE capture_event_id = v_first.capture_event_id;

  SELECT COUNT(*) INTO v_count
  FROM public.claim_v3_i24_contact_effects(
    200, '2026-09-01T16:00:01Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_first.capture_event_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'capture without property was claimed for Contactado';
  END IF;

  SELECT * INTO v_replay
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:property-backfill', 'inmuebles24',
    'fixture-lead-property-backfill', 'fixture-person-property-backfill',
    'eb-rdy01', 'property-backfill@example.test', '+525500000901',
    '{"listing_id":"fixture-listing-property-backfill","property_public_id":"eb-rdy01"}'::JSONB,
    '2026-09-01T16:01:00Z'::TIMESTAMPTZ
  );

  IF v_replay.capture_event_id IS DISTINCT FROM v_first.capture_event_id THEN
    RAISE EXCEPTION 'property replay created a new capture';
  END IF;

  SELECT e.property_public_id, o.property_id, e.route_dispatch_status,
         e.route_dispatch_last_error_code, e.route_dispatch_attempts
    INTO v_property, v_state, v_status, v_error, v_attempts
  FROM public.i24_capture_events e
  JOIN public.lead_routing_opportunities o USING (opportunity_id)
  WHERE e.capture_event_id = v_first.capture_event_id;
  IF v_property IS DISTINCT FROM 'EB-RDY01' OR v_state IS DISTINCT FROM 'EB-RDY01' THEN
    RAISE EXCEPTION 'capture/opportunity property backfill did not converge';
  END IF;
  IF v_status IS DISTINCT FROM 'pending'
     OR v_error IS DISTINCT FROM 'missing_property_public_id'
     OR v_attempts IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'failed missing-property backfill did not preserve evidence while rearming';
  END IF;

  SELECT * INTO v_contact_claim
  FROM public.claim_v3_i24_contact_effects(
    200, '2026-09-01T16:01:01Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_first.capture_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'valid property replay did not enable Contactado';
  END IF;

  PERFORM public.finish_v3_i24_contact_effect(
    v_contact_claim.capture_event_id,
    v_contact_claim.lease_token,
    TRUE,
    NULL,
    '2026-09-01T16:01:02Z'::TIMESTAMPTZ
  );

  SELECT * INTO v_conflict
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:property-backfill', 'inmuebles24',
    'fixture-lead-property-backfill', 'fixture-person-property-backfill',
    'EB-OTHER9', 'property-backfill@example.test', '+525500000901',
    '{}'::JSONB, '2026-09-01T16:02:00Z'::TIMESTAMPTZ
  );
  SELECT property_public_id INTO v_property
  FROM public.i24_capture_events
  WHERE capture_event_id = v_first.capture_event_id;
  IF v_conflict.capture_event_id IS DISTINCT FROM v_first.capture_event_id
     OR v_property IS DISTINCT FROM 'EB-RDY01' THEN
    RAISE EXCEPTION 'conflicting replay overwrote a non-null property';
  END IF;

  SELECT * INTO v_manual_first
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:property-backfill-manual', 'inmuebles24',
    'fixture-lead-property-backfill-manual', 'fixture-person-property-backfill-manual',
    NULL, 'property-backfill-manual@example.test', '+525500000903',
    '{}'::JSONB, '2026-09-01T16:03:00Z'::TIMESTAMPTZ
  );
  UPDATE public.i24_capture_events
  SET route_dispatch_status = 'manual_review',
      route_dispatch_attempts = 3,
      route_dispatch_last_error_code = 'missing_property_public_id'
  WHERE capture_event_id = v_manual_first.capture_event_id;

  SELECT * INTO v_manual_replay
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:property-backfill-manual', 'inmuebles24',
    'fixture-lead-property-backfill-manual', 'fixture-person-property-backfill-manual',
    'EB-RDY02', 'property-backfill-manual@example.test', '+525500000903',
    '{}'::JSONB, '2026-09-01T16:04:00Z'::TIMESTAMPTZ
  );
  SELECT route_dispatch_status, route_dispatch_last_error_code,
         route_dispatch_attempts, property_public_id
    INTO v_status, v_error, v_attempts, v_property
  FROM public.i24_capture_events
  WHERE capture_event_id = v_manual_first.capture_event_id;
  IF v_manual_replay.capture_event_id IS DISTINCT FROM v_manual_first.capture_event_id
     OR v_status IS DISTINCT FROM 'pending'
     OR v_error IS DISTINCT FROM 'missing_property_public_id'
     OR v_attempts IS DISTINCT FROM 3
     OR v_property IS DISTINCT FROM 'EB-RDY02' THEN
    RAISE EXCEPTION 'manual-review missing-property backfill was not a safe in-place rearm';
  END IF;

  SELECT * INTO v_sent_first
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:property-backfill-sent', 'inmuebles24',
    'fixture-lead-property-backfill-sent', 'fixture-person-property-backfill-sent',
    NULL, 'property-backfill-sent@example.test', '+525500000904',
    '{}'::JSONB, '2026-09-01T16:05:00Z'::TIMESTAMPTZ
  );
  UPDATE public.i24_capture_events
  SET route_dispatch_status = 'failed',
      route_dispatch_last_error_code = 'missing_property_public_id',
      route_dispatched_at = '2026-09-01T16:05:01Z'::TIMESTAMPTZ
  WHERE capture_event_id = v_sent_first.capture_event_id;

  SELECT * INTO v_sent_replay
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:property-backfill-sent', 'inmuebles24',
    'fixture-lead-property-backfill-sent', 'fixture-person-property-backfill-sent',
    'EB-RDY03', 'property-backfill-sent@example.test', '+525500000904',
    '{}'::JSONB, '2026-09-01T16:05:02Z'::TIMESTAMPTZ
  );
  SELECT route_dispatch_status, property_public_id
    INTO v_status, v_property
  FROM public.i24_capture_events
  WHERE capture_event_id = v_sent_first.capture_event_id;
  IF v_sent_replay.capture_event_id IS DISTINCT FROM v_sent_first.capture_event_id
     OR v_property IS DISTINCT FROM 'EB-RDY03'
     OR v_status IS DISTINCT FROM 'failed' THEN
    RAISE EXCEPTION 'backfill rearmed a capture with durable dispatch evidence';
  END IF;

  INSERT INTO public.agents(agent_id, name, whatsapp_number, on_shift, is_available)
  VALUES ('fixture-night-agent', 'Fixture Agent', '+525599999999', FALSE, TRUE)
  ON CONFLICT (agent_id) DO UPDATE SET name = EXCLUDED.name;
  SELECT * INTO v_assigned_first
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:returning-day', 'inmuebles24',
    'fixture-lead-returning-day', 'fixture-person-returning',
    'EB-RET01', 'returning-night@example.test', '+525500000906',
    '{}'::JSONB, '2026-09-01T16:06:00Z'::TIMESTAMPTZ
  );
  UPDATE public.lead_routing_opportunities
  SET state = 'assigned', assigned_agent_id = 'fixture-night-agent'
  WHERE opportunity_id = v_assigned_first.opportunity_id;

  SELECT * INTO v_returning_night
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:returning-night', 'inmuebles24',
    'fixture-lead-returning-night', 'fixture-person-returning',
    'EB-RET01', 'returning-night@example.test', '+525500000906',
    '{}'::JSONB, '2026-09-02T02:00:00Z'::TIMESTAMPTZ
  );
  IF v_returning_night.disposition IS DISTINCT FROM 'returning_assigned'
     OR v_returning_night.opportunity_id IS DISTINCT FROM v_assigned_first.opportunity_id THEN
    RAISE EXCEPTION 'night recurrent did not preserve its assigned opportunity';
  END IF;
  SELECT * INTO v_returning_contact
  FROM public.claim_v3_i24_contact_effects(
    200, '2026-09-02T02:00:01Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_returning_night.capture_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'night recurrent was not Contactado-ready';
  END IF;
  PERFORM public.finish_v3_i24_contact_effect(
    v_returning_contact.capture_event_id,
    v_returning_contact.lease_token,
    TRUE,
    NULL,
    '2026-09-02T02:00:02Z'::TIMESTAMPTZ
  );
  SELECT COUNT(*) INTO v_count
  FROM public.claim_v3_route_dispatches(
    200, '2026-09-02T02:00:03Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_returning_night.capture_event_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'returning_assigned escaped its 08:05 night hold';
  END IF;
  SELECT * INTO v_returning_route
  FROM public.claim_v3_route_dispatches(
    200, '2026-09-02T14:05:00Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_returning_night.capture_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'returning_assigned did not release at 08:05';
  END IF;

  SELECT * INTO v_night_missing_first
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:night-missing-property', 'inmuebles24',
    'fixture-lead-night-missing', 'fixture-person-night-missing',
    NULL, 'night-missing@example.test', '+525500000907',
    '{}'::JSONB, '2026-09-03T02:00:00Z'::TIMESTAMPTZ
  );
  UPDATE public.i24_capture_events
  SET route_dispatch_status = 'failed',
      route_dispatch_attempts = 4,
      route_dispatch_last_error_code = 'missing_property_public_id'
  WHERE capture_event_id = v_night_missing_first.capture_event_id;
  SELECT * INTO v_night_missing_replay
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:night-missing-property', 'inmuebles24',
    'fixture-lead-night-missing', 'fixture-person-night-missing',
    'EB-NGT03', 'night-missing@example.test', '+525500000907',
    '{}'::JSONB, '2026-09-03T02:01:00Z'::TIMESTAMPTZ
  );
  SELECT route_dispatch_status, route_dispatch_next_attempt_at,
         route_dispatch_attempts, route_dispatch_last_error_code
    INTO v_status, v_next_at, v_attempts, v_error
  FROM public.i24_capture_events
  WHERE capture_event_id = v_night_missing_first.capture_event_id;
  IF v_night_missing_replay.capture_event_id IS DISTINCT FROM
       v_night_missing_first.capture_event_id
     OR v_status IS DISTINCT FROM 'pending'
     OR v_next_at IS DISTINCT FROM '2026-09-03T14:05:00Z'::TIMESTAMPTZ
     OR v_attempts IS DISTINCT FROM 4
     OR v_error IS DISTINCT FROM 'missing_property_public_id' THEN
    RAISE EXCEPTION 'night property backfill erased the 08:05 hold';
  END IF;
  SELECT * INTO v_night_missing_contact
  FROM public.claim_v3_i24_contact_effects(
    200, '2026-09-03T02:01:01Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_night_missing_first.capture_event_id;
  PERFORM public.finish_v3_i24_contact_effect(
    v_night_missing_contact.capture_event_id,
    v_night_missing_contact.lease_token,
    TRUE, NULL, '2026-09-03T02:01:02Z'::TIMESTAMPTZ
  );
  SELECT COUNT(*) INTO v_count
  FROM public.claim_v3_route_dispatches(
    200, '2026-09-03T02:01:03Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_night_missing_first.capture_event_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'night property backfill routed before 08:05';
  END IF;
  SELECT * INTO v_night_missing_route
  FROM public.claim_v3_route_dispatches(
    200, '2026-09-03T14:05:00Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_night_missing_first.capture_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'night property backfill did not release at 08:05';
  END IF;

  SELECT * INTO v_night
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:night-release', 'inmuebles24',
    'fixture-lead-night-release', 'fixture-person-night-release',
    'EB-NGT01', 'night-release@example.test', '+525500000902',
    '{"listing_id":"fixture-listing-night-release","property_public_id":"EB-NGT01"}'::JSONB,
    '2026-09-01T02:20:00Z'::TIMESTAMPTZ
  );

  SELECT * INTO v_boundary
  FROM public.v3_intake(
    'fixture-readiness', 'fixture:night-boundary', 'inmuebles24',
    'fixture-lead-night-boundary', 'fixture-person-night-boundary',
    'EB-NGT02', 'night-boundary@example.test', '+525500000905',
    '{"listing_id":"fixture-listing-night-boundary","property_public_id":"EB-NGT02"}'::JSONB,
    '2026-09-01T14:04:59Z'::TIMESTAMPTZ
  );
  SELECT state INTO v_state
  FROM public.lead_routing_opportunities
  WHERE opportunity_id = v_boundary.opportunity_id;
  IF v_state IS DISTINCT FROM 'queued_night' THEN
    RAISE EXCEPTION '08:04:59 CDMX intake escaped the night queue';
  END IF;
  SELECT COUNT(*) INTO v_count
  FROM public.v3_release_night_queue(
    200, '2026-09-01T14:04:59Z'::TIMESTAMPTZ
  );
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'night release opened before 08:05 CDMX';
  END IF;

  SELECT * INTO v_night_contact_claim
  FROM public.claim_v3_i24_contact_effects(
    200, '2026-09-01T02:20:01Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_night.capture_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'night capture with mapping was not Contactado-ready';
  END IF;
  PERFORM public.finish_v3_i24_contact_effect(
    v_night_contact_claim.capture_event_id,
    v_night_contact_claim.lease_token,
    TRUE,
    NULL,
    '2026-09-01T02:20:02Z'::TIMESTAMPTZ
  );

  SELECT * INTO v_contact_claim
  FROM public.claim_v3_i24_contact_effects(
    200, '2026-09-01T14:04:59Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_boundary.capture_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fresh boundary capture was not Contactado-ready';
  END IF;
  PERFORM public.finish_v3_i24_contact_effect(
    v_contact_claim.capture_event_id,
    v_contact_claim.lease_token,
    TRUE,
    NULL,
    '2026-09-01T14:04:59Z'::TIMESTAMPTZ
  );

  SELECT COUNT(*) INTO v_count
  FROM public.claim_v3_route_dispatches(
    200, '2026-09-01T02:20:03Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_night.capture_event_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'queued_night capture escaped before 08:05';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.claim_night_queue(
    200, '2026-09-01T14:05:00Z'::TIMESTAMPTZ, INTERVAL '10 minutes'
  ) claimed
  WHERE claimed.opportunity_id = v_night.opportunity_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'V3 night opportunity escaped through the legacy WF7 claim';
  END IF;

  UPDATE public.i24_capture_events
  SET route_dispatch_status = 'manual_review',
      route_dispatch_attempts = 5,
      route_dispatch_last_error_code = 'webhook_dispatch_failed',
      route_dispatch_next_attempt_at = NULL
  WHERE capture_event_id = v_night.capture_event_id;

  SELECT COUNT(*) INTO v_count
  FROM public.v3_release_night_queue(
    200, '2026-09-01T14:05:00Z'::TIMESTAMPTZ
  ) AS released(opportunity_id)
  WHERE released.opportunity_id = v_night.opportunity_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'legacy manual_review capture changed without its explicit CAS';
  END IF;

  SELECT state INTO v_state
  FROM public.lead_routing_opportunities
  WHERE opportunity_id = v_boundary.opportunity_id;
  IF v_state IS DISTINCT FROM 'captured' THEN
    RAISE EXCEPTION '08:05 CDMX did not release the boundary intake';
  END IF;

  SELECT o.state, e.route_dispatch_status,
         e.route_dispatch_last_error_code, e.route_dispatch_attempts
    INTO v_state, v_status, v_error, v_attempts
  FROM public.lead_routing_opportunities o
  JOIN public.i24_capture_events e USING (opportunity_id)
  WHERE o.opportunity_id = v_night.opportunity_id
    AND e.capture_event_id = v_night.capture_event_id;
  IF v_state IS DISTINCT FROM 'queued_night'
     OR v_status IS DISTINCT FROM 'manual_review'
     OR v_error IS DISTINCT FROM 'webhook_dispatch_failed'
     OR v_attempts IS DISTINCT FROM 5 THEN
    RAISE EXCEPTION 'legacy manual_review state or evidence changed during release';
  END IF;

  SELECT processed, processing_status
    INTO v_processed, v_status
  FROM public.night_queue
  WHERE opportunity_id = v_night.opportunity_id;
  IF v_processed IS DISTINCT FROM FALSE OR v_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'legacy manual_review report row changed during release';
  END IF;

  SELECT processed, processing_status
    INTO v_processed, v_status
  FROM public.night_queue
  WHERE opportunity_id = v_boundary.opportunity_id;
  IF v_processed IS DISTINCT FROM TRUE OR v_status IS DISTINCT FROM 'processed' THEN
    RAISE EXCEPTION 'fresh V3 release did not retire its legacy report-only row';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.v3_release_night_queue(
    200, '2026-09-01T14:05:01Z'::TIMESTAMPTZ
  );
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'second release was not idempotent';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.claim_v3_route_dispatches(
    200, '2026-09-01T14:05:02Z'::TIMESTAMPTZ
  ) claimed
  WHERE claimed.capture_event_id = v_night.capture_event_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'legacy manual_review capture was claimable without its explicit CAS';
  END IF;

  INSERT INTO public.easybroker_contact_request_inbox(
    eb_request_id, account_key, happened_at
  ) VALUES (
    v_eb_request_id, 'fixture-readiness',
    '2026-09-01T16:10:00Z'::TIMESTAMPTZ
  );
  INSERT INTO public.easybroker_effect_ledger(
    eb_request_id, opportunity_id, responsible_agent_id,
    responsible_first_name, close_state, note_next_retry_at,
    attended_next_retry_at, next_retry_at, lease_token, lease_expires_at
  ) VALUES (
    v_eb_request_id, v_assigned_first.opportunity_id, 'fixture-night-agent',
    'Fixture', 'pending', '2026-09-01T16:10:00Z'::TIMESTAMPTZ,
    '2026-09-01T16:10:00Z'::TIMESTAMPTZ,
    '2026-09-01T16:10:00Z'::TIMESTAMPTZ, v_eb_lease,
    '2026-09-01T16:12:00Z'::TIMESTAMPTZ
  );
  INSERT INTO public.easybroker_effect_attempts(
    eb_request_id, effect_kind, attempt_no, effect_idempotency_key,
    lease_token, started_at
  ) VALUES (
    v_eb_request_id, 'note', 0,
    'easybroker:' || v_eb_request_id || ':note:0', v_eb_lease,
    '2026-09-01T16:10:00Z'::TIMESTAMPTZ
  );

  v_finish := public.finish_v3_easybroker_effect(
    v_eb_request_id, v_eb_lease, 'note', FALSE,
    jsonb_build_object(
      'eb_request_id', v_eb_request_id::TEXT,
      'error_code', 'easybroker_assignee_conflict'
    ),
    '2026-09-01T16:10:01Z'::TIMESTAMPTZ
  );
  IF v_finish->>'state' IS DISTINCT FROM 'manual_review'
     OR COALESCE((v_finish->>'alert_created')::BOOLEAN, FALSE) IS NOT TRUE THEN
    RAISE EXCEPTION 'deterministic EasyBroker conflict was not parked and alerted';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.easybroker_effect_ledger e
  WHERE e.eb_request_id = v_eb_request_id
    AND e.close_state = 'manual_review'
    AND e.note_state = 'failed'
    AND e.next_retry_at IS NULL
    AND e.note_next_retry_at IS NULL
    AND e.attended_next_retry_at IS NULL
    AND e.lease_token IS NULL
    AND e.lease_expires_at IS NULL;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'manual-review conflict retained retry or lease state';
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.easybroker_effect_alerts a
  WHERE a.eb_request_id = v_eb_request_id
    AND a.incident_key =
      'easybroker_effect_manual_review:' || v_eb_request_id
    AND a.alert_type = 'easybroker_effect_manual_review'
    AND a.status = 'pending'
    AND a.metadata->>'error_code' = 'easybroker_assignee_conflict';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'manual-review conflict did not create its exact alert';
  END IF;

  PERFORM public.finish_v3_easybroker_effect(
    v_eb_request_id, v_eb_lease, 'note', FALSE,
    jsonb_build_object(
      'eb_request_id', v_eb_request_id::TEXT,
      'error_code', 'easybroker_assignee_conflict'
    ),
    '2026-09-01T16:10:02Z'::TIMESTAMPTZ
  );
  SELECT COUNT(*) INTO v_count
  FROM public.easybroker_effect_alerts a
  WHERE a.incident_key =
    'easybroker_effect_manual_review:' || v_eb_request_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'manual-review replay duplicated its alert';
  END IF;
END;
$fixture$;

ROLLBACK;
