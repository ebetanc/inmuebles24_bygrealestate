\set ON_ERROR_STOP on

BEGIN;

-- The production helper returns NULL outside business hours. Override only in
-- this rolled-back fixture so coverage scenarios are independent of wall time.
CREATE OR REPLACE FUNCTION public.current_shift()
RETURNS TEXT LANGUAGE SQL STABLE SECURITY INVOKER SET search_path=pg_catalog
AS 'SELECT ''morning''::text';

INSERT INTO public.agents(agent_id,name,whatsapp_number,is_available) VALUES
  ('guard_primary_test','Guard Primary','525500000010',true),
  ('guard_backup_test','Guard Backup','525500000011',true)
ON CONFLICT(agent_id) DO UPDATE SET is_available=true;

INSERT INTO public.agent_schedule(schedule_date,shift,agent_id,coverage_role) VALUES
  ((NOW() AT TIME ZONE 'America/Mexico_City')::date,'morning','guard_primary_test','primary'),
  ((NOW() AT TIME ZONE 'America/Mexico_City')::date,'morning','guard_backup_test','backup'),
  ((NOW() AT TIME ZONE 'America/Mexico_City')::date,'afternoon','guard_primary_test','primary'),
  ((NOW() AT TIME ZONE 'America/Mexico_City')::date,'afternoon','guard_backup_test','backup')
ON CONFLICT (schedule_date,shift,coverage_role) WHERE coverage_role IS NOT NULL
DO UPDATE SET agent_id=EXCLUDED.agent_id;

-- Callback-first delivery is one independent opportunity. The failure chain below
-- must not reuse its delivered attempt or provider message id.
DO $$
DECLARE v_opp BIGINT; v_attempt RECORD; v_row public.lead_routing_opportunities;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
  VALUES('EB-LRV2008-DELIVERED','email:lrv2008-delivered@example.test','normalized_email','resolved','owner') RETURNING opportunity_id INTO v_opp;
  SELECT * INTO v_attempt FROM public.create_delivery_attempt(v_opp,'owner','test-owner-delivered','owner_test','525500000012');
  PERFORM public.record_delivery_callback('wamid.test.delivered.owner','delivered',NOW(),'{}'::jsonb);
  PERFORM public.bind_delivery_message(v_attempt.attempt_id,'wamid.test.delivered.owner',v_attempt.lease_token);
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state<>'owner_open' OR v_row.delivered_at IS NULL OR v_row.expires_at<>v_row.delivered_at+INTERVAL '5 minutes' THEN RAISE EXCEPTION 'delivered SLA failed'; END IF;
END $$;

DO $$
DECLARE v_opp BIGINT; v_owner RECORD; v_primary RECORD; v_backup RECORD; v_row public.lead_routing_opportunities;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
  VALUES('EB-LRV2008-FAILURE-CHAIN','email:lrv2008-failure-chain@example.test','normalized_email','resolved','owner') RETURNING opportunity_id INTO v_opp;
  SELECT * INTO v_owner FROM public.create_delivery_attempt(v_opp,'owner','test-owner-failure-chain','owner_test','525500000012');
  PERFORM public.record_delivery_callback('wamid.test.failure-chain.owner','failed',NOW(),'{}'::jsonb);
  PERFORM public.bind_delivery_message(v_owner.attempt_id,'wamid.test.failure-chain.owner',v_owner.lease_token);
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state<>'guard_delivery_pending' OR v_row.routing_tier<>'primary_guard' OR v_row.expires_at IS NOT NULL THEN RAISE EXCEPTION 'owner failure did not open primary delivery'; END IF;
  SELECT * INTO v_primary FROM public.claim_pending_guard_deliveries(10) WHERE opportunity_id=v_opp;
  IF v_primary.target_agent_id<>'guard_primary_test' THEN RAISE EXCEPTION 'primary guard claim incorrect'; END IF;
  PERFORM public.record_delivery_callback('wamid.test.failure-chain.primary','failed',NOW(),'{}'::jsonb);
  PERFORM public.bind_delivery_message(v_primary.attempt_id,'wamid.test.failure-chain.primary',v_primary.lease_token);
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state<>'guard_delivery_pending' OR v_row.routing_tier<>'backup_guard' THEN RAISE EXCEPTION 'primary failure did not open backup delivery'; END IF;
  SELECT * INTO v_backup FROM public.claim_pending_guard_deliveries(10) WHERE opportunity_id=v_opp;
  IF v_backup.target_agent_id<>'guard_backup_test' THEN RAISE EXCEPTION 'backup guard claim incorrect'; END IF;
  PERFORM public.record_delivery_callback('wamid.test.failure-chain.backup','failed',NOW(),'{}'::jsonb);
  PERFORM public.bind_delivery_message(v_backup.attempt_id,'wamid.test.failure-chain.backup',v_backup.lease_token);
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state<>'unassigned_alerted' OR v_row.assigned_agent_id IS NOT NULL THEN RAISE EXCEPTION 'backup failure must end unassigned'; END IF;
END $$;

DO $$
DECLARE v_opp BIGINT; v_attempt RECORD; v_row public.lead_routing_opportunities;
BEGIN
  -- Scope temporary coverage change to this scenario; restore before next one.
  DELETE FROM public.agent_schedule
  WHERE schedule_date=(NOW() AT TIME ZONE 'America/Mexico_City')::date AND agent_id='guard_primary_test';
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
  VALUES('EB-LRV2008-BACKUP','email:lrv2008-backup@example.test','normalized_email','resolved','owner') RETURNING opportunity_id INTO v_opp;
  SELECT * INTO v_attempt FROM public.create_delivery_attempt(v_opp,'owner','test-owner-backup','owner_test','525500000012');
  PERFORM public.bind_delivery_message(v_attempt.attempt_id,'wamid.test.owner.backup',v_attempt.lease_token);
  PERFORM public.record_delivery_callback('wamid.test.owner.backup','failed',NOW(),'{}'::jsonb);
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state<>'guard_delivery_pending' OR v_row.routing_tier<>'backup_guard' THEN RAISE EXCEPTION 'owner must skip absent primary'; END IF;
  SELECT * INTO v_attempt FROM public.claim_pending_guard_deliveries(10) WHERE opportunity_id=v_opp;
  IF v_attempt.target_agent_id<>'guard_backup_test' THEN RAISE EXCEPTION 'backup was not claimed after absent primary'; END IF;
  INSERT INTO public.agent_schedule(schedule_date,shift,agent_id,coverage_role) VALUES
    ((NOW() AT TIME ZONE 'America/Mexico_City')::date,'morning','guard_primary_test','primary'),
    ((NOW() AT TIME ZONE 'America/Mexico_City')::date,'afternoon','guard_primary_test','primary')
  ON CONFLICT (schedule_date,shift,coverage_role) WHERE coverage_role IS NOT NULL
  DO UPDATE SET agent_id=EXCLUDED.agent_id;
END $$;

DO $$
DECLARE v_opp BIGINT; v_attempt RECORD; v_row public.lead_routing_opportunities;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
  VALUES('EB-LRV2008-SWEEP','email:lrv2008-sweep@example.test','normalized_email','resolved','owner') RETURNING opportunity_id INTO v_opp;
  SELECT * INTO v_attempt FROM public.create_delivery_attempt(v_opp,'owner','test-owner-sweep','owner_test','525500000012');
  UPDATE public.lead_routing_delivery_attempts SET lease_expires_at=NOW()-INTERVAL '1 second' WHERE attempt_id=v_attempt.attempt_id;
  PERFORM * FROM public.sweep_owner_delivery_no_callback(INTERVAL '2 minutes',10);
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state<>'guard_delivery_pending' OR v_row.routing_tier<>'primary_guard' THEN RAISE EXCEPTION 'expired requested attempt was not swept through fallback'; END IF;

  BEGIN
    PERFORM public.bind_delivery_message(v_attempt.attempt_id,'wamid.test.stale','wrong-token');
    RAISE EXCEPTION 'stale lease token unexpectedly accepted';
  EXCEPTION WHEN others THEN
    IF SQLERRM NOT LIKE '%lease invalid%' THEN RAISE; END IF;
  END;
END $$;

DO $$
DECLARE v_opp BIGINT; v_attempt RECORD;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
  VALUES('EB-LRV2008-PURGE','email:lrv2008-purge@example.test','normalized_email','resolved','owner') RETURNING opportunity_id INTO v_opp;
  SELECT * INTO v_attempt FROM public.create_delivery_attempt(v_opp,'owner','test-owner-purge','owner_test','525500000099');
  UPDATE public.lead_routing_delivery_attempts SET requested_at=NOW()-INTERVAL '31 days',target_number='525500000099' WHERE attempt_id=v_attempt.attempt_id;
  PERFORM public.purge_delivery_callback_evidence(NOW()-INTERVAL '30 days');
  IF (SELECT target_number IS NOT NULL FROM public.lead_routing_delivery_attempts WHERE attempt_id=v_attempt.attempt_id) THEN RAISE EXCEPTION 'purge did not redact target number'; END IF;
END $$;

DO $$
DECLARE v_a BIGINT; v_b BIGINT;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
  VALUES('EB-LRV2008-COLLIDE-A','email:lrv2008-collide-a@example.test','normalized_email','resolved','owner') RETURNING opportunity_id INTO v_a;
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
  VALUES('EB-LRV2008-COLLIDE-B','email:lrv2008-collide-b@example.test','normalized_email','resolved','owner') RETURNING opportunity_id INTO v_b;
  PERFORM public.create_delivery_attempt(v_a,'owner','test-owner-collision','owner_test','525500000012');
  BEGIN
    PERFORM public.create_delivery_attempt(v_b,'owner','test-owner-collision','owner_test','525500000013');
    RAISE EXCEPTION 'client request collision unexpectedly accepted';
  EXCEPTION WHEN others THEN
    IF SQLERRM NOT LIKE '%collision%' THEN RAISE; END IF;
  END;
END $$;

ROLLBACK;
