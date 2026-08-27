\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION public.current_shift()
RETURNS TEXT LANGUAGE SQL STABLE SECURITY INVOKER SET search_path=pg_catalog
AS 'SELECT ''morning''::text';

INSERT INTO public.agents(agent_id,name,whatsapp_number,is_available) VALUES
  ('fallback_primary_test','Fallback Primary','525500000210',true),
  ('fallback_backup_test','Fallback Backup','525500000211',true)
ON CONFLICT(agent_id) DO UPDATE SET is_available=true;

INSERT INTO public.agent_schedule(schedule_date,shift,agent_id,coverage_role) VALUES
  ((NOW() AT TIME ZONE 'America/Mexico_City')::date,'morning','fallback_primary_test','primary'),
  ((NOW() AT TIME ZONE 'America/Mexico_City')::date,'morning','fallback_backup_test','backup')
ON CONFLICT (schedule_date,shift,coverage_role) WHERE coverage_role IS NOT NULL
DO UPDATE SET agent_id=EXCLUDED.agent_id;

SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_reason TEXT;
  v_opp BIGINT;
  v_route RECORD;
  v_attempt RECORD;
  v_attempt_count INTEGER;
  v_replay_count INTEGER;
BEGIN
  FOREACH v_reason IN ARRAY ARRAY['missing_owner_data','routing_safe_mode'] LOOP
    INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
    VALUES('EB-FALLBACK-'||v_reason,'email:'||v_reason||'@example.test','normalized_email','captured','owner')
    RETURNING opportunity_id INTO v_opp;

    SELECT * INTO v_route FROM public.route_missing_owner_data(
      v_opp, v_reason, 'fixture:fallback:'||v_reason
    );
    IF v_route.state IS DISTINCT FROM 'guard_delivery_pending'
       OR v_route.routing_tier IS DISTINCT FROM 'primary_guard' THEN
      RAISE EXCEPTION '% did not durably enqueue primary guard delivery', v_reason;
    END IF;

    SELECT * INTO v_attempt FROM public.claim_pending_guard_deliveries(10)
    WHERE opportunity_id=v_opp;
    IF v_attempt.attempt_id IS NULL OR v_attempt.target_agent_id IS DISTINCT FROM 'fallback_primary_test' THEN
      RAISE EXCEPTION '% did not create exactly the primary attempt', v_reason;
    END IF;

    SELECT count(*) INTO v_attempt_count
    FROM public.lead_routing_delivery_attempts WHERE opportunity_id=v_opp;
    IF v_attempt_count <> 1 THEN RAISE EXCEPTION '% created duplicate attempts', v_reason; END IF;

    PERFORM public.route_missing_owner_data(v_opp,v_reason,'fixture:fallback:'||v_reason);
    SELECT count(*) INTO v_replay_count
    FROM public.claim_pending_guard_deliveries(10) WHERE opportunity_id=v_opp;
    SELECT count(*) INTO v_attempt_count
    FROM public.lead_routing_delivery_attempts WHERE opportunity_id=v_opp;
    IF v_replay_count <> 0 OR v_attempt_count <> 1 THEN
      RAISE EXCEPTION '% replay duplicated guard delivery', v_reason;
    END IF;
  END LOOP;
END $$;

RESET ROLE;
DELETE FROM public.agent_schedule
WHERE schedule_date=(NOW() AT TIME ZONE 'America/Mexico_City')::date;
SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_opp BIGINT;
  v_route RECORD;
  v_event public.lead_routing_events;
  v_alert RECORD;
  v_alert_count INTEGER;
  v_second_claim_count INTEGER;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
  VALUES('EB-FALLBACK-NONE','email:fallback-none@example.test','normalized_email','captured','owner')
  RETURNING opportunity_id INTO v_opp;
  SELECT * INTO v_route FROM public.route_missing_owner_data(
    v_opp,'missing_owner_data','fixture:fallback:no-coverage'
  );
  IF v_route.state IS DISTINCT FROM 'unassigned_alerted' OR v_route.routing_tier IS NOT NULL THEN
    RAISE EXCEPTION 'missing coverage did not produce unassigned alert state';
  END IF;
  SELECT * INTO v_event FROM public.lead_routing_events
  WHERE idempotency_key='fixture:fallback:no-coverage';
  IF v_event.event_type IS DISTINCT FROM 'missing_owner_data'
     OR v_event.metadata->>'state' IS DISTINCT FROM 'unassigned_alerted' THEN
    RAISE EXCEPTION 'missing coverage alert evidence incorrect';
  END IF;

  SELECT * INTO v_alert FROM public.claim_unassigned_alerts(10, NOW(), INTERVAL '2 minutes')
  WHERE opportunity_id=v_opp;
  IF v_alert.alert_id IS NULL THEN
    RAISE EXCEPTION 'WF3c direct alert lease could not claim missing-coverage alert';
  END IF;

  PERFORM public.route_missing_owner_data(
    v_opp,'missing_owner_data','fixture:fallback:no-coverage'
  );
  SELECT count(*) INTO v_alert_count
  FROM public.routing_v2_unassigned_alerts WHERE opportunity_id=v_opp;
  SELECT count(*) INTO v_second_claim_count
  FROM public.claim_unassigned_alerts(10, NOW(), INTERVAL '2 minutes')
  WHERE opportunity_id=v_opp;
  IF v_alert_count <> 1 OR v_second_claim_count <> 0 THEN
    RAISE EXCEPTION 'missing-coverage alert replay duplicated row or active lease';
  END IF;
END $$;

RESET ROLE;
ROLLBACK;
