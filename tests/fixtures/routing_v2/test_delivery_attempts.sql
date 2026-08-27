\set ON_ERROR_STOP on

BEGIN;

-- The production helper returns NULL outside business hours. Override only in
-- this rolled-back fixture so coverage scenarios are independent of wall time.
CREATE OR REPLACE FUNCTION public.current_shift()
RETURNS TEXT LANGUAGE SQL STABLE SECURITY INVOKER SET search_path=pg_catalog
AS 'SELECT ''morning''::text';

INSERT INTO public.agents(agent_id,name,whatsapp_number,is_available,role) VALUES
  ('guard_primary_test','Guard Primary','525500000010',true,'asesor'),
  ('guard_backup_test','Guard Backup','525500000011',true,'asesor'),
  ('owner_resolution_test','Owner Resolution','525500000012',true,'asesor')
ON CONFLICT(agent_id) DO UPDATE SET
  whatsapp_number=EXCLUDED.whatsapp_number,is_available=true,role='asesor';

INSERT INTO public.property_agent_alias(tag_normalized,agent_id)
VALUES('fixture_owner_tag','owner_resolution_test')
ON CONFLICT(tag_normalized) DO UPDATE SET agent_id=EXCLUDED.agent_id;

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

-- Full owner-first contract with no external effects: EasyBroker tag resolution,
-- one durable owner attempt, delivered callback, SLA expiry, and one primary claim.
DO $$
DECLARE
  v_opp BIGINT;
  v_resolved RECORD;
  v_owner RECORD;
  v_replay RECORD;
  v_primary RECORD;
  v_row public.lead_routing_opportunities;
  v_expires TIMESTAMPTZ;
  v_count BIGINT;
BEGIN
  SELECT * INTO v_resolved
  FROM public.resolve_first_property_tag(
    'EB-LRV2008OWNERSLA', ARRAY['fixture_owner_tag']::text[]
  );
  IF v_resolved.resolved IS DISTINCT FROM TRUE
     OR v_resolved.owner_agent_id IS DISTINCT FROM 'owner_resolution_test'
     OR v_resolved.owner_number IS DISTINCT FROM '525500000012' THEN
    RAISE EXCEPTION 'owner tag did not resolve to fixture owner';
  END IF;

  INSERT INTO public.lead_routing_opportunities(
    property_id,identity_key,identity_reason,state,routing_tier
  ) VALUES(
    'EB-LRV2008OWNERSLA','email:lrv2008-owner-sla@example.test',
    'normalized_email','resolved','owner'
  ) RETURNING opportunity_id INTO v_opp;

  SELECT * INTO v_owner FROM public.create_delivery_attempt(
    v_opp,'owner','test-owner-sla',v_resolved.owner_agent_id,v_resolved.owner_number
  );
  IF v_owner.should_send IS DISTINCT FROM TRUE
     OR v_owner.routing_tier IS DISTINCT FROM 'owner'
     OR v_owner.target_agent_id IS DISTINCT FROM 'owner_resolution_test'
     OR v_owner.target_number IS DISTINCT FROM '525500000012'
     OR v_owner.client_request_id IS DISTINCT FROM 'test-owner-sla' THEN
    RAISE EXCEPTION 'first owner delivery was not sendable';
  END IF;

  SELECT * INTO v_replay FROM public.create_delivery_attempt(
    v_opp,'owner','test-owner-sla',v_resolved.owner_agent_id,v_resolved.owner_number
  );
  IF v_replay.should_send IS DISTINCT FROM FALSE
     OR v_replay.attempt_id IS DISTINCT FROM v_owner.attempt_id THEN
    RAISE EXCEPTION 'owner delivery replay was not idempotent';
  END IF;

  PERFORM public.bind_delivery_message(
    v_owner.attempt_id,'wamid.test.owner.sla',v_owner.lease_token
  );
  PERFORM public.record_delivery_callback(
    'wamid.test.owner.sla','delivered',NOW(),'{}'::jsonb
  );
  PERFORM public.record_delivery_callback(
    'wamid.test.owner.sla','delivered',NOW(),'{}'::jsonb
  );
  SELECT * INTO v_row
  FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  v_expires:=v_row.expires_at;
  IF v_row.state IS DISTINCT FROM 'owner_open'
     OR v_row.delivery_status IS DISTINCT FROM 'delivered'
     OR v_row.delivered_at IS NULL
     OR v_expires IS DISTINCT FROM v_row.delivered_at+INTERVAL '5 minutes' THEN
    RAISE EXCEPTION 'owner delivered callback did not start exact SLA';
  END IF;
  SELECT count(*) INTO v_count FROM public.lead_routing_delivery_callbacks
  WHERE provider_message_id='wamid.test.owner.sla' AND delivery_status='delivered';
  IF v_count<>1 THEN RAISE EXCEPTION 'owner delivered callback replay was not idempotent'; END IF;
  SELECT count(*) INTO v_count FROM public.lead_routing_events
  WHERE opportunity_id=v_opp
    AND idempotency_key='delivery:wamid.test.owner.sla:delivered';
  IF v_count<>1 THEN RAISE EXCEPTION 'owner delivered event replay was not idempotent'; END IF;

  SELECT count(*) INTO v_count
  FROM public.sweep_expired_routing_tiers(100,v_expires-INTERVAL '1 second')
  WHERE opportunity_id=v_opp;
  IF v_count<>0 THEN RAISE EXCEPTION 'owner SLA swept before expiry'; END IF;
  SELECT count(*) INTO v_count
  FROM public.sweep_expired_routing_tiers(100,v_expires+INTERVAL '1 second')
  WHERE opportunity_id=v_opp;
  IF v_count<>1 THEN RAISE EXCEPTION 'owner SLA sweeper did not transition opportunity once'; END IF;
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state IS DISTINCT FROM 'guard_delivery_pending'
     OR v_row.routing_tier IS DISTINCT FROM 'primary_guard'
     OR v_row.current_delivery_attempt_id IS NOT NULL
     OR v_row.delivered_at IS NOT NULL OR v_row.expires_at IS NOT NULL THEN
    RAISE EXCEPTION 'owner SLA expiry did not open clean primary delivery';
  END IF;
  SELECT * INTO v_primary
  FROM public.claim_pending_guard_deliveries(10)
  WHERE opportunity_id=v_opp;
  IF v_primary.attempt_id IS NULL
     OR v_primary.target_agent_id IS DISTINCT FROM 'guard_primary_test'
     OR v_primary.routing_tier IS DISTINCT FROM 'primary_guard'
     OR v_primary.status IS DISTINCT FROM 'requested'
     OR v_primary.provider_message_id IS NOT NULL THEN
    RAISE EXCEPTION 'owner SLA expiry did not offer only to primary guard';
  END IF;
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.assigned_agent_id IS NOT NULL
     OR v_row.state IS DISTINCT FROM 'delivery_requested'
     OR v_row.current_delivery_attempt_id IS DISTINCT FROM v_primary.attempt_id THEN
    RAISE EXCEPTION 'primary guard claim mutated assignment or current attempt';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.lead_routing_delivery_attempts WHERE opportunity_id=v_opp;
  IF v_count<>2 THEN RAISE EXCEPTION 'owner SLA chain created % attempts, expected 2',v_count; END IF;
  SELECT count(*) INTO v_count FROM public.lead_routing_events
  WHERE opportunity_id=v_opp AND idempotency_key='tier-expired:'||v_owner.attempt_id::text;
  IF v_count<>1 THEN RAISE EXCEPTION 'owner SLA expiry event was not unique'; END IF;
  SELECT count(*) INTO v_count FROM public.lead_routing_events
  WHERE opportunity_id=v_opp AND event_type='claim_accepted';
  IF v_count<>0 THEN RAISE EXCEPTION 'delivery chain must not claim the lead automatically'; END IF;
  SELECT count(*) INTO v_count FROM public.lead_routing_events
  WHERE opportunity_id=v_opp AND event_type='delivery_confirmed_by_claim';
  IF v_count<>0 THEN RAISE EXCEPTION 'delivery chain used claim as delivery proof'; END IF;

  PERFORM public.advance_routing_tier(v_opp,'owner',v_expires+INTERVAL '2 seconds');
  SELECT count(*) INTO v_count
  FROM public.claim_pending_guard_deliveries(10) WHERE opportunity_id=v_opp;
  IF v_count<>0 THEN RAISE EXCEPTION 'owner SLA replay reclaimed primary guard'; END IF;
  SELECT count(*) INTO v_count
  FROM public.lead_routing_delivery_attempts WHERE opportunity_id=v_opp;
  IF v_count<>2 THEN RAISE EXCEPTION 'owner SLA replay duplicated a delivery attempt'; END IF;
  SELECT count(*) INTO v_count FROM public.lead_routing_events
  WHERE opportunity_id=v_opp AND idempotency_key='tier-expired:'||v_owner.attempt_id::text;
  IF v_count<>1 THEN RAISE EXCEPTION 'owner SLA replay duplicated expiry event'; END IF;
END $$;

-- A provider-accepted owner message without callback is swept once. A late
-- delivered callback is preserved as evidence but cannot reopen the owner tier.
DO $$
DECLARE
  v_opp BIGINT;
  v_resolved RECORD;
  v_owner RECORD;
  v_primary RECORD;
  v_row public.lead_routing_opportunities;
  v_count BIGINT;
BEGIN
  SELECT * INTO v_resolved
  FROM public.resolve_first_property_tag(
    'EB-LRV2008OWNERTIMEOUT', ARRAY['fixture_owner_tag']::text[]
  );
  IF v_resolved.resolved IS DISTINCT FROM TRUE
     OR v_resolved.owner_agent_id IS DISTINCT FROM 'owner_resolution_test' THEN
    RAISE EXCEPTION 'timeout owner did not resolve';
  END IF;

  INSERT INTO public.lead_routing_opportunities(
    property_id,identity_key,identity_reason,state,routing_tier
  ) VALUES(
    'EB-LRV2008OWNERTIMEOUT','email:lrv2008-owner-timeout@example.test',
    'normalized_email','resolved','owner'
  ) RETURNING opportunity_id INTO v_opp;
  SELECT * INTO v_owner FROM public.create_delivery_attempt(
    v_opp,'owner','test-owner-timeout',v_resolved.owner_agent_id,v_resolved.owner_number
  );
  IF v_owner.should_send IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'timeout owner delivery was not sendable';
  END IF;
  PERFORM public.bind_delivery_message(
    v_owner.attempt_id,'wamid.test.owner.timeout',v_owner.lease_token
  );
  UPDATE public.lead_routing_delivery_attempts
  SET bound_at=NOW()-INTERVAL '11 minutes'
  WHERE attempt_id=v_owner.attempt_id;

  PERFORM * FROM public.sweep_owner_delivery_no_callback(INTERVAL '10 minutes',10);
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state IS DISTINCT FROM 'guard_delivery_pending'
     OR v_row.routing_tier IS DISTINCT FROM 'primary_guard'
     OR v_row.current_delivery_attempt_id IS NOT NULL
     OR v_row.delivered_at IS NOT NULL OR v_row.expires_at IS NOT NULL THEN
    RAISE EXCEPTION 'owner callback timeout did not open primary guard';
  END IF;
  IF (SELECT status FROM public.lead_routing_delivery_attempts WHERE attempt_id=v_owner.attempt_id)
     IS DISTINCT FROM 'failed' THEN
    RAISE EXCEPTION 'timed-out owner attempt was not failed';
  END IF;
  SELECT count(*) INTO v_count FROM public.lead_routing_events
  WHERE opportunity_id=v_opp
    AND idempotency_key='delivery-fallback:'||v_owner.attempt_id::text
    AND metadata->>'reason'='delivery_callback_timeout';
  IF v_count<>1 THEN RAISE EXCEPTION 'callback timeout fallback event was not unique'; END IF;

  SELECT * INTO v_primary
  FROM public.claim_pending_guard_deliveries(10)
  WHERE opportunity_id=v_opp;
  IF v_primary.attempt_id IS NULL
     OR v_primary.target_agent_id IS DISTINCT FROM 'guard_primary_test'
     OR v_primary.routing_tier IS DISTINCT FROM 'primary_guard'
     OR v_primary.status IS DISTINCT FROM 'requested'
     OR v_primary.provider_message_id IS NOT NULL THEN
    RAISE EXCEPTION 'callback timeout did not create one primary guard attempt';
  END IF;
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.assigned_agent_id IS NOT NULL
     OR v_row.state IS DISTINCT FROM 'delivery_requested'
     OR v_row.current_delivery_attempt_id IS DISTINCT FROM v_primary.attempt_id THEN
    RAISE EXCEPTION 'timeout primary claim mutated assignment or current attempt';
  END IF;
  SELECT count(*) INTO v_count FROM public.lead_routing_events
  WHERE opportunity_id=v_opp AND event_type='claim_accepted';
  IF v_count<>0 THEN RAISE EXCEPTION 'timeout chain claimed the lead automatically'; END IF;
  SELECT count(*) INTO v_count FROM public.lead_routing_events
  WHERE opportunity_id=v_opp AND event_type='delivery_confirmed_by_claim';
  IF v_count<>0 THEN RAISE EXCEPTION 'timeout chain used claim as delivery proof'; END IF;

  PERFORM * FROM public.sweep_owner_delivery_no_callback(INTERVAL '10 minutes',10);
  SELECT count(*) INTO v_count FROM public.lead_routing_events
  WHERE opportunity_id=v_opp
    AND idempotency_key='delivery-fallback:'||v_owner.attempt_id::text;
  IF v_count<>1 THEN RAISE EXCEPTION 'second timeout sweep duplicated transition'; END IF;
  SELECT count(*) INTO v_count
  FROM public.lead_routing_delivery_attempts WHERE opportunity_id=v_opp;
  IF v_count<>2 THEN RAISE EXCEPTION 'second timeout sweep duplicated delivery attempt'; END IF;

  PERFORM public.record_delivery_callback(
    'wamid.test.owner.timeout','delivered',NOW(),'{}'::jsonb
  );
  PERFORM public.record_delivery_callback(
    'wamid.test.owner.timeout','delivered',NOW(),'{}'::jsonb
  );
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state IS DISTINCT FROM 'delivery_requested'
     OR v_row.routing_tier IS DISTINCT FROM 'primary_guard'
     OR v_row.current_delivery_attempt_id IS DISTINCT FROM v_primary.attempt_id
     OR v_row.delivered_at IS NOT NULL OR v_row.expires_at IS NOT NULL THEN
    RAISE EXCEPTION 'late owner callback reopened owner routing';
  END IF;
  IF (SELECT status FROM public.lead_routing_delivery_attempts WHERE attempt_id=v_owner.attempt_id)
     IS DISTINCT FROM 'failed' THEN
    RAISE EXCEPTION 'late owner callback changed failed attempt';
  END IF;
  SELECT count(*) INTO v_count FROM public.lead_routing_delivery_callbacks
  WHERE provider_message_id='wamid.test.owner.timeout' AND delivery_status='delivered';
  IF v_count<>1 THEN RAISE EXCEPTION 'late callback replay duplicated callback evidence'; END IF;
  SELECT count(*) INTO v_count FROM public.lead_routing_events
  WHERE opportunity_id=v_opp AND event_type='delivery_confirmed' AND routing_tier='owner';
  IF v_count<>0 THEN RAISE EXCEPTION 'late callback created owner delivery event'; END IF;
  SELECT count(*) INTO v_count
  FROM public.claim_pending_guard_deliveries(10) WHERE opportunity_id=v_opp;
  IF v_count<>0 THEN RAISE EXCEPTION 'late callback made primary guard claimable twice'; END IF;
  SELECT count(*) INTO v_count
  FROM public.lead_routing_delivery_attempts WHERE opportunity_id=v_opp;
  IF v_count<>2 THEN RAISE EXCEPTION 'late callback duplicated delivery attempt'; END IF;
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
DECLARE v_a BIGINT; v_collision BOOLEAN:=false;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier)
  VALUES('EB-LRV2008-COLLIDE-A','email:lrv2008-collide-a@example.test','normalized_email','resolved','owner') RETURNING opportunity_id INTO v_a;
  PERFORM public.create_delivery_attempt(v_a,'owner','test-owner-collision','owner_test','525500000012');
  BEGIN
    PERFORM public.create_delivery_attempt(v_a,'owner','test-owner-collision','owner_test','525500000013');
  EXCEPTION WHEN others THEN
    IF SQLERRM='client_request_id collision' THEN v_collision:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_collision THEN RAISE EXCEPTION 'client request collision unexpectedly accepted'; END IF;
END $$;

ROLLBACK;
