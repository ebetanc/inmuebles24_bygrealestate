\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION public.current_shift()
RETURNS TEXT LANGUAGE SQL STABLE SECURITY INVOKER SET search_path=pg_catalog
AS 'SELECT ''morning''::text';

INSERT INTO public.agents(agent_id,name,whatsapp_number,is_available) VALUES
  ('tier_primary_test','Tier Primary','525500000031',true),
  ('tier_backup_test','Tier Backup','525500000032',true)
ON CONFLICT(agent_id) DO UPDATE SET is_available=true,whatsapp_number=EXCLUDED.whatsapp_number;
INSERT INTO public.agent_schedule(schedule_date,shift,agent_id,coverage_role) VALUES
  ((NOW() AT TIME ZONE 'America/Mexico_City')::date,'morning','tier_primary_test','primary'),
  ((NOW() AT TIME ZONE 'America/Mexico_City')::date,'morning','tier_backup_test','backup')
ON CONFLICT (schedule_date,shift,coverage_role) WHERE coverage_role IS NOT NULL
DO UPDATE SET agent_id=EXCLUDED.agent_id;

DO $$
DECLARE v_opp BIGINT; v_attempt BIGINT; v_row public.lead_routing_opportunities; v_events INTEGER;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier,delivery_status,delivered_at,expires_at)
  VALUES('EB-TIER-OWNER','email:tier-owner@example.test','normalized_email','owner_open','owner','delivered',NOW()-INTERVAL '6 minutes',NOW()-INTERVAL '1 minute')
  RETURNING opportunity_id INTO v_opp;
  INSERT INTO public.lead_routing_delivery_attempts(opportunity_id,routing_tier,client_request_id,status,target_agent_id,target_number,lease_token,delivered_at)
  VALUES(v_opp,'owner','tier-owner-attempt','delivered','owner_test','525500000030','old-owner-token',NOW()-INTERVAL '6 minutes') RETURNING attempt_id INTO v_attempt;
  UPDATE public.lead_routing_opportunities SET current_delivery_attempt_id=v_attempt WHERE opportunity_id=v_opp;

  PERFORM public.advance_routing_tier(v_opp,'owner',NOW());
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state<>'guard_delivery_pending' OR v_row.routing_tier<>'primary_guard' OR v_row.delivered_at IS NOT NULL OR v_row.expires_at IS NOT NULL THEN
    RAISE EXCEPTION 'owner did not advance only to primary delivery';
  END IF;
  IF (SELECT lease_token IS NOT NULL FROM public.lead_routing_delivery_attempts WHERE attempt_id=v_attempt) THEN
    RAISE EXCEPTION 'previous tier token remained valid';
  END IF;
  PERFORM public.advance_routing_tier(v_opp,'owner',NOW());
  SELECT count(*) INTO v_events FROM public.lead_routing_events WHERE idempotency_key='tier-expired:'||v_attempt::text;
  IF v_events<>1 THEN RAISE EXCEPTION 'owner transition replay duplicated event'; END IF;
END $$;

DO $$
DECLARE v_opp BIGINT; v_attempt BIGINT; v_row public.lead_routing_opportunities;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier,delivery_status,delivered_at,expires_at)
  VALUES('EB-TIER-PRIMARY','email:tier-primary@example.test','normalized_email','primary_guard_open','primary_guard','delivered',NOW()-INTERVAL '6 minutes',NOW()-INTERVAL '1 minute')
  RETURNING opportunity_id INTO v_opp;
  INSERT INTO public.lead_routing_delivery_attempts(opportunity_id,routing_tier,client_request_id,status,target_agent_id,target_number,delivered_at)
  VALUES(v_opp,'primary_guard','tier-primary-attempt','delivered','tier_primary_test','525500000031',NOW()-INTERVAL '6 minutes') RETURNING attempt_id INTO v_attempt;
  UPDATE public.lead_routing_opportunities SET current_delivery_attempt_id=v_attempt WHERE opportunity_id=v_opp;
  PERFORM public.advance_routing_tier(v_opp,'primary_guard',NOW());
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state<>'guard_delivery_pending' OR v_row.routing_tier<>'backup_guard' THEN RAISE EXCEPTION 'primary did not advance only to backup delivery'; END IF;
END $$;

DO $$
DECLARE v_opp BIGINT; v_attempt BIGINT; v_row public.lead_routing_opportunities;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier,delivery_status,delivered_at,expires_at)
  VALUES('EB-TIER-BACKUP','email:tier-backup@example.test','normalized_email','backup_guard_open','backup_guard','delivered',NOW()-INTERVAL '6 minutes',NOW()-INTERVAL '1 minute')
  RETURNING opportunity_id INTO v_opp;
  INSERT INTO public.lead_routing_delivery_attempts(opportunity_id,routing_tier,client_request_id,status,target_agent_id,target_number,delivered_at)
  VALUES(v_opp,'backup_guard','tier-backup-attempt','delivered','tier_backup_test','525500000032',NOW()-INTERVAL '6 minutes') RETURNING attempt_id INTO v_attempt;
  UPDATE public.lead_routing_opportunities SET current_delivery_attempt_id=v_attempt WHERE opportunity_id=v_opp;
  PERFORM public.advance_routing_tier(v_opp,'backup_guard',NOW());
  SELECT * INTO v_row FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_row.state<>'unassigned_alerted' OR v_row.routing_tier IS NOT NULL OR v_row.assigned_agent_id IS NOT NULL THEN
    RAISE EXCEPTION 'backup expiry did not end unassigned';
  END IF;
END $$;

ROLLBACK;
