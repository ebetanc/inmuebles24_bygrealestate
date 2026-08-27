-- LRV2-013: circuit breaker trip/idempotency/exit/re-entry, history preserved.
BEGIN;

CREATE OR REPLACE FUNCTION public.current_shift()
RETURNS TEXT LANGUAGE SQL STABLE SECURITY INVOKER SET search_path=pg_catalog
AS 'SELECT ''morning''::text';

INSERT INTO public.agents(agent_id,name,whatsapp_number,is_available) VALUES
  ('safemode_primary_test','Safe Mode Primary','525500000041',true)
ON CONFLICT(agent_id) DO UPDATE SET is_available=true,whatsapp_number=EXCLUDED.whatsapp_number;
INSERT INTO public.agent_schedule(schedule_date,shift,agent_id,coverage_role) VALUES
  ((NOW() AT TIME ZONE 'America/Mexico_City')::date,'morning','safemode_primary_test','primary')
ON CONFLICT (schedule_date,shift,coverage_role) WHERE coverage_role IS NOT NULL
DO UPDATE SET agent_id=EXCLUDED.agent_id;

DO $$
DECLARE
  v_state public.routing_safe_mode_state;
  v_row RECORD;
  v_count INTEGER;
  v_t0 TIMESTAMPTZ := '2026-08-13 09:00:00+00';
  v_opp1 BIGINT;
  v_opp2 BIGINT;
  v_fallback RECORD;
BEGIN
  -- Baseline: start from normal regardless of shared PG17 fixture state; ROLLBACK restores it.
  UPDATE public.routing_safe_mode_state
  SET status = 'normal', reason = NULL, entered_at = NULL, operational_owner = NULL,
      acknowledged = false, acknowledged_at = NULL, acknowledged_by = NULL,
      exited_at = NULL, exited_by = NULL
  WHERE id = 1;

  -- Two failures 4 minutes apart trip safe_mode exactly once.
  SELECT * INTO v_row FROM public.report_routing_failure(
    'delivery_failed', 'fixture:safe-mode:f1', v_t0
  );
  IF v_row.status IS DISTINCT FROM 'normal' OR v_row.just_entered THEN
    RAISE EXCEPTION 'first failure must not trip safe mode';
  END IF;

  SELECT * INTO v_row FROM public.report_routing_failure(
    'delivery_failed', 'fixture:safe-mode:f2', v_t0 + INTERVAL '4 minutes'
  );
  IF v_row.status IS DISTINCT FROM 'safe_mode' OR NOT v_row.just_entered THEN
    RAISE EXCEPTION 'second failure within 5 minutes must trip safe mode';
  END IF;
  IF v_row.operational_owner IS DISTINCT FROM 'manager' THEN
    RAISE EXCEPTION 'operational owner must be manager on trip';
  END IF;

  SELECT * INTO v_state FROM public.get_routing_safe_mode();
  IF v_state.status IS DISTINCT FROM 'safe_mode' OR v_state.entered_at IS DISTINCT FROM v_t0 + INTERVAL '4 minutes' THEN
    RAISE EXCEPTION 'durable state did not persist trip';
  END IF;

  -- A third failure while already tripped must not create a second entry event.
  SELECT * INTO v_row FROM public.report_routing_failure(
    'delivery_failed', 'fixture:safe-mode:f3', v_t0 + INTERVAL '6 minutes'
  );
  IF v_row.just_entered THEN
    RAISE EXCEPTION 'third failure must not re-trip safe mode';
  END IF;
  IF v_row.entered_at IS DISTINCT FROM v_t0 + INTERVAL '4 minutes' THEN
    RAISE EXCEPTION 'third failure must not move entered_at';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.routing_safe_mode_events
  WHERE event_type = 'safe_mode_entered';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'exactly one safe_mode_entered event expected, got %', v_count;
  END IF;

  -- Replaying the same idempotency_key is a pure no-op (no duplicate rows, same answer).
  SELECT * INTO v_row FROM public.report_routing_failure('delivery_failed', 'fixture:safe-mode:f2', v_t0 + INTERVAL '4 minutes');
  IF v_row.just_entered THEN RAISE EXCEPTION 'replay of a known key must not re-trip'; END IF;
  SELECT count(*) INTO v_count FROM public.routing_safe_mode_events WHERE idempotency_key = 'fixture:safe-mode:f2';
  IF v_count <> 1 THEN RAISE EXCEPTION 'replay must not duplicate the event row'; END IF;

  -- Exit requires a real actor.
  BEGIN
    PERFORM public.exit_routing_safe_mode(NULL, true, 'fixture:safe-mode:exit-noactor');
    RAISE EXCEPTION 'exit without actor must fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%explicit actor%' THEN RAISE; END IF;
  END;

  -- Exit requires a green health check.
  BEGIN
    PERFORM public.exit_routing_safe_mode('manager-1', false, 'fixture:safe-mode:exit-red');
    RAISE EXCEPTION 'exit with a red health check must fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%green health check%' THEN RAISE; END IF;
  END;

  -- Confirm the failed attempts left safe_mode untouched.
  SELECT * INTO v_state FROM public.get_routing_safe_mode();
  IF v_state.status IS DISTINCT FROM 'safe_mode' THEN
    RAISE EXCEPTION 'rejected exit attempts must not change status';
  END IF;

  -- Manual exit with actor + green health check succeeds.
  SELECT * INTO v_state FROM public.exit_routing_safe_mode(
    'manager-1', true, 'fixture:safe-mode:exit-ok', v_t0 + INTERVAL '20 minutes'
  );
  IF v_state.status IS DISTINCT FROM 'normal'
     OR v_state.exited_by IS DISTINCT FROM 'manager-1'
     OR v_state.exited_at IS DISTINCT FROM v_t0 + INTERVAL '20 minutes' THEN
    RAISE EXCEPTION 'manual exit did not persist';
  END IF;

  -- Exit is idempotent and does not erase the completed exit's evidence.
  SELECT * INTO v_state FROM public.exit_routing_safe_mode(
    'manager-1', true, 'fixture:safe-mode:exit-ok', v_t0 + INTERVAL '20 minutes'
  );
  IF v_state.status IS DISTINCT FROM 'normal' OR v_state.exited_by IS DISTINCT FROM 'manager-1' THEN
    RAISE EXCEPTION 'replayed exit changed durable state';
  END IF;

  -- Exiting again while already normal is a safe no-op: it short-circuits
  -- before inserting an event, so no event is recorded for that call.
  SELECT * INTO v_state FROM public.exit_routing_safe_mode('manager-2', true, 'fixture:safe-mode:exit-noop');
  IF v_state.status IS DISTINCT FROM 'normal' THEN
    RAISE EXCEPTION 'no-op exit must report normal status';
  END IF;
  PERFORM 1 FROM public.routing_safe_mode_events WHERE idempotency_key = 'fixture:safe-mode:exit-noop';
  IF FOUND THEN
    RAISE EXCEPTION 'no-op exit (already normal) must not insert a new event';
  END IF;

  -- History from the first incident is preserved (never deleted).
  SELECT count(*) INTO v_count FROM public.routing_safe_mode_events WHERE idempotency_key IN (
    'fixture:safe-mode:f1', 'fixture:safe-mode:f2', 'fixture:safe-mode:f3',
    'fixture:safe-mode:f2:entered', 'fixture:safe-mode:exit-ok'
  );
  IF v_count <> 5 THEN
    RAISE EXCEPTION 'safe mode history must be preserved across exit, got %', v_count;
  END IF;

  -- Re-entry after exit is possible: two more failures trip a fresh incident.
  SELECT * INTO v_row FROM public.report_routing_failure(
    'delivery_failed', 'fixture:safe-mode:g1', v_t0 + INTERVAL '30 minutes'
  );
  IF v_row.just_entered THEN RAISE EXCEPTION 'lone failure after exit must not trip'; END IF;

  SELECT * INTO v_row FROM public.report_routing_failure(
    'delivery_failed', 'fixture:safe-mode:g2', v_t0 + INTERVAL '33 minutes'
  );
  IF v_row.status IS DISTINCT FROM 'safe_mode' OR NOT v_row.just_entered THEN
    RAISE EXCEPTION 're-entry after exit must trip a fresh incident';
  END IF;

  -- Attempted delete/update of the append-only log must be rejected.
  BEGIN
    UPDATE public.routing_safe_mode_events SET reason = 'tampered' WHERE idempotency_key = 'fixture:safe-mode:f1';
    RAISE EXCEPTION 'append-only trigger did not reject UPDATE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%append-only%' THEN RAISE; END IF;
  END;

  -- Failures more than 5 minutes apart never trip.
  UPDATE public.routing_safe_mode_state
  SET status = 'normal', reason = NULL, entered_at = NULL, operational_owner = NULL,
      acknowledged = false, exited_at = NULL, exited_by = NULL
  WHERE id = 1;

  SELECT * INTO v_row FROM public.report_routing_failure(
    'delivery_failed', 'fixture:safe-mode:h1', v_t0 + INTERVAL '60 minutes'
  );
  SELECT * INTO v_row FROM public.report_routing_failure(
    'delivery_failed', 'fixture:safe-mode:h2', v_t0 + INTERVAL '66 minutes'
  );
  IF v_row.just_entered OR v_row.status IS DISTINCT FROM 'normal' THEN
    RAISE EXCEPTION 'failures more than 5 minutes apart must not trip safe mode';
  END IF;

  -- LRV2-013 P1-A: route_missing_owner_data (0028 override) accepts both
  -- 'routing_safe_mode' (WF10 direct-to-guard branch) and 'missing_owner_data'
  -- (pre-existing owner fallback), and rejects any other reason.
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
  VALUES('EB-SAFEMODE-1','email:safemode1@example.test','normalized_email','captured','owner')
  RETURNING opportunity_id INTO v_opp1;
  SELECT * INTO v_fallback FROM public.route_missing_owner_data(v_opp1,'routing_safe_mode','fixture:safe-mode:route-1');
  IF v_fallback.state IS DISTINCT FROM 'guard_delivery_pending' OR v_fallback.routing_tier IS DISTINCT FROM 'primary_guard' THEN
    RAISE EXCEPTION 'route_missing_owner_data must succeed with reason routing_safe_mode';
  END IF;

  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
  VALUES('EB-SAFEMODE-2','email:safemode2@example.test','normalized_email','captured','owner')
  RETURNING opportunity_id INTO v_opp2;
  SELECT * INTO v_fallback FROM public.route_missing_owner_data(v_opp2,'missing_owner_data','fixture:safe-mode:route-2');
  IF v_fallback.state IS DISTINCT FROM 'guard_delivery_pending' OR v_fallback.routing_tier IS DISTINCT FROM 'primary_guard' THEN
    RAISE EXCEPTION 'route_missing_owner_data must still succeed with reason missing_owner_data';
  END IF;

  BEGIN
    PERFORM public.route_missing_owner_data(999999999,'some_other_reason','fixture:safe-mode:route-bad');
    RAISE EXCEPTION 'route_missing_owner_data must reject an unrecognized reason';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%invalid owner fallback reason%' THEN RAISE; END IF;
  END;
END;
$$;

ROLLBACK;
