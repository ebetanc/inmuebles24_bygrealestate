-- Execute after the migration, in the SAME transaction, then ROLLBACK.
-- No HTTP calls, synthetic sends, or committed leads.
DO $$
DECLARE expired bigint; fresh bigint; night bigint; op bigint; r record; n integer;
BEGIN
 UPDATE public.v3_day_settings SET enabled_at=clock_timestamp()-interval '2 days';
 SELECT * INTO r FROM public.v3_intake(
   p_account_key=>'day-sla-rollback',p_idempotency_key=>gen_random_uuid()::text,
   p_external_id=>'9999999901',p_property_public_id=>'EB-QJ4964',
   p_email=>gen_random_uuid()::text||'@example.invalid',
   p_offer_context=>jsonb_build_object('name','SLA rollback','day_sla_version',1,
     'status','Pendiente','portal_received_at',clock_timestamp()-interval '16 minutes'));
 expired:=r.capture_event_id;op:=r.opportunity_id;
 IF public.v3_day_allowed(expired,op,NULL) THEN RAISE EXCEPTION 'expired allowed'; END IF;
 IF public.v3_day_deadline(expired,NULL,NULL) IS NULL THEN RAISE EXCEPTION 'missing deadline'; END IF;
 IF EXISTS(SELECT 1 FROM public.claim_v3_i24_contact_effects(200) c WHERE c.capture_event_id=expired)
   THEN RAISE EXCEPTION 'expired Contactado leased'; END IF;
 IF EXISTS(SELECT 1 FROM public.claim_v3_route_dispatches(200) c WHERE c.capture_event_id=expired)
   THEN RAISE EXCEPTION 'expired route leased'; END IF;
 IF public.claim_v3_delivery(op,1,expired,'agent_manager','525500000000',p_reply_to_wamid=>'test')->>'outcome'<>'late'
   THEN RAISE EXCEPTION 'late acceptance allowed'; END IF;
 BEGIN
   UPDATE public.lead_routing_opportunities SET assigned_agent_id='agent_manager',state='assigned' WHERE opportunity_id=op;
   RAISE EXCEPTION 'assignment should have failed' USING ERRCODE='check_violation';
 EXCEPTION WHEN raise_exception THEN
   IF SQLERRM<>'day_deadline_expired_or_held' THEN RAISE; END IF;
 END;
 PERFORM public.v3_day_sweep();PERFORM public.v3_day_sweep();
 SELECT count(*) INTO n FROM public.v3_day_incidents WHERE capture_event_id=expired;
 IF n<>1 THEN RAISE EXCEPTION 'incident not exactly once'; END IF;
 SELECT * INTO r FROM public.v3_intake(
   p_account_key=>'day-sla-rollback',p_idempotency_key=>gen_random_uuid()::text,
   p_external_id=>'9999999902',p_property_public_id=>'EB-QJ4964',
   p_email=>gen_random_uuid()::text||'@example.invalid',
   p_offer_context=>jsonb_build_object('name','SLA rollback','day_sla_version',1,
     'status','Contactado','portal_received_at',clock_timestamp()-interval '1 minute'));
 fresh:=r.capture_event_id;
 IF public.v3_day_allowed(fresh,NULL,NULL) THEN RAISE EXCEPTION 'human-contacted reoffer allowed'; END IF;
 PERFORM public.v3_day_sweep();
 IF NOT EXISTS(SELECT 1 FROM public.v3_day_incidents WHERE capture_event_id=fresh
     AND reason='portal_already_contacted_without_capture') THEN RAISE EXCEPTION 'missing human-contacted incident'; END IF;
 SELECT * INTO r FROM public.v3_intake(
   p_account_key=>'day-sla-rollback',p_idempotency_key=>gen_random_uuid()::text,
   p_external_id=>'9999999903',p_property_public_id=>'EB-QJ4964',
   p_email=>gen_random_uuid()::text||'@example.invalid',
   p_offer_context=>jsonb_build_object('name','SLA rollback','day_sla_version',1,
     'status','Pendiente','portal_received_at',
       (date_trunc('day',clock_timestamp() AT TIME ZONE 'America/Mexico_City')+interval '1 hour') AT TIME ZONE 'America/Mexico_City'));
 night:=r.capture_event_id;
 IF public.v3_day_deadline(night,NULL,NULL) IS NOT NULL OR NOT public.v3_day_allowed(night,NULL,NULL)
   THEN RAISE EXCEPTION 'night changed'; END IF;
 IF public.v3_day_deadline(night,op,NULL) IS NOT NULL THEN RAISE EXCEPTION 'capture scope overridden by previous opportunity'; END IF;
 IF NOT public.v3_day_allowed(304,NULL,NULL) THEN RAISE EXCEPTION 'legacy changed'; END IF;
 RAISE NOTICE 'DAY_SLA_ROLLBACK_TESTS_PASS';
END $$;
