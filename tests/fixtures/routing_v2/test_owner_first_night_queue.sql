\set ON_ERROR_STOP on

BEGIN;
SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_agent record;
  v_state text;
  v_opportunity bigint;
  v_attempt record;
  v_replay record;
  v_count integer;
BEGIN
  SELECT agent_id, whatsapp_number INTO v_agent
  FROM public.get_guard_coverage_slots()
  WHERE coverage_role = 'primary'
  LIMIT 1;
  IF v_agent.agent_id IS NULL THEN
    RAISE EXCEPTION 'fixture requires primary guard coverage';
  END IF;

  FOREACH v_state IN ARRAY ARRAY['captured','queued_night'] LOOP
    INSERT INTO public.lead_routing_opportunities(
      property_id,identity_key,identity_reason,state
    ) VALUES(
      'FIXTURE-OWNER-'||v_state,
      'email:fixture-owner-'||v_state||'@example.test',
      'normalized_email',v_state
    ) RETURNING opportunity_id INTO v_opportunity;

    SELECT * INTO v_attempt FROM public.create_delivery_attempt(
      v_opportunity,'owner','fixture:owner:'||v_state,
      v_agent.agent_id,v_agent.whatsapp_number
    );
    IF v_attempt.should_send IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'owner attempt not created from %', v_state;
    END IF;
    SELECT state INTO v_state FROM public.lead_routing_opportunities
    WHERE opportunity_id=v_opportunity;
    IF v_state IS DISTINCT FROM 'delivery_requested' THEN
      RAISE EXCEPTION 'owner attempt did not enter delivery_requested';
    END IF;

    SELECT * INTO v_replay FROM public.create_delivery_attempt(
      v_opportunity,'owner','fixture:owner:'||split_part(v_attempt.client_request_id,':',3),
      v_agent.agent_id,v_agent.whatsapp_number
    );
    SELECT count(*) INTO v_count FROM public.lead_routing_delivery_attempts
    WHERE opportunity_id=v_opportunity;
    IF v_replay.should_send IS DISTINCT FROM FALSE OR v_count <> 1 THEN
      RAISE EXCEPTION 'owner replay duplicated delivery attempt';
    END IF;
  END LOOP;

  INSERT INTO public.lead_routing_opportunities(
    property_id,identity_key,identity_reason,state
  ) VALUES(
    'FIXTURE-MISSING-OWNER-NIGHT',
    'email:fixture-missing-owner-night@example.test',
    'normalized_email','queued_night'
  ) RETURNING opportunity_id INTO v_opportunity;

  PERFORM public.route_missing_owner_data(
    v_opportunity,'missing_owner_data','fixture:missing-owner:queued-night'
  );
  SELECT state INTO v_state FROM public.lead_routing_opportunities
  WHERE opportunity_id=v_opportunity;
  IF v_state IS DISTINCT FROM 'guard_delivery_pending' THEN
    RAISE EXCEPTION 'queued_night missing owner did not enter guard delivery';
  END IF;
END;
$$;

RESET ROLE;
ROLLBACK;

SELECT 'OWNER_FIRST_NIGHT_QUEUE_PASS';
