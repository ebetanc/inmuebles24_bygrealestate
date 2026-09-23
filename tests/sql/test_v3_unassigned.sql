-- Execute after the full migration chain, in the SAME transaction, then ROLLBACK.
-- No HTTP calls, no WhatsApp sends, nothing committed.
DO $$
DECLARE
  r record; op bigint; cap bigint; op2 bigint; cap2 bigint; op3 bigint; cap3 bigint;
  op4 bigint; cap4 bigint;
  n integer; res jsonb; tok uuid; changed boolean;
  t0 timestamptz := clock_timestamp() - interval '1 hour';
  deadline timestamptz := clock_timestamp() - interval '30 minutes';
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.agents WHERE agent_id='agent_manager' AND role='manager')
   THEN RAISE EXCEPTION 'missing stable manager seed'; END IF;

 SELECT * INTO r FROM public.v3_intake(
   p_account_key=>'unassigned-rollback',p_idempotency_key=>gen_random_uuid()::text,
   p_external_id=>'9999990001',p_property_public_id=>'EB-QJ4964',
   p_email=>gen_random_uuid()::text||'@example.invalid',
   p_offer_context=>jsonb_build_object('name','Sin asignacion rollback'));
 op:=r.opportunity_id; cap:=r.capture_event_id;
 UPDATE public.lead_routing_opportunities
 SET state='guard_delivery_pending', routing_tier='primary_guard'
 WHERE opportunity_id=op;
 IF NOT EXISTS(SELECT 1 FROM public.lead_routing_opportunities
    WHERE opportunity_id=op AND v3_enabled) THEN RAISE EXCEPTION 'opportunity is not V3'; END IF;

 -- (a) the terminal route leaves nobody assigned and notifies nobody
 changed := public.v3_mark_unassigned(op,'guard_expired',cap,t0);
 IF NOT changed THEN RAISE EXCEPTION 'v3_mark_unassigned did not change the lead'; END IF;
 SELECT * INTO r FROM public.lead_routing_opportunities WHERE opportunity_id=op;
 IF r.state<>'unassigned' THEN RAISE EXCEPTION 'state is % not unassigned', r.state; END IF;
 IF r.assigned_agent_id IS NOT NULL THEN RAISE EXCEPTION 'unassigned lead got an agent'; END IF;
 IF r.unassigned_at IS DISTINCT FROM t0 THEN RAISE EXCEPTION 'unassigned_at not stamped'; END IF;
 IF r.routing_tier IS NOT NULL OR r.expires_at IS NOT NULL
    OR r.current_delivery_attempt_id IS NOT NULL THEN
   RAISE EXCEPTION 'auction state survived the unassigned terminal'; END IF;
 IF r.external_evidence->>'v3_final_route'<>'unassigned' THEN
   RAISE EXCEPTION 'missing v3_final_route evidence'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.lead_routing_events
    WHERE opportunity_id=op AND event_type='left_unassigned') THEN
   RAISE EXCEPTION 'missing left_unassigned event'; END IF;
 IF EXISTS(SELECT 1 FROM public.lead_routing_delivery_attempts
    WHERE opportunity_id=op AND delivery_kind='assigned_notice') THEN
   RAISE EXCEPTION 'Sandy was notified about an unassigned lead'; END IF;

 -- Retried dispatch must not reopen the terminal, even during night hours.
 UPDATE public.i24_capture_events
 SET contactado_status='verified', contactado_verified_at=t0,
     route_dispatch_status='dispatched', route_dispatched_at=t0
 WHERE capture_event_id=cap;
 res := public.v3_route_ready_opportunity(op,cap,ARRAY[]::text[],clock_timestamp());
 IF res->>'state'<>'unassigned' THEN
   RAISE EXCEPTION 'route_ready reopened an unassigned lead: %', res; END IF;
 IF (SELECT state FROM public.lead_routing_opportunities WHERE opportunity_id=op)<>'unassigned' THEN
   RAISE EXCEPTION 'route_ready changed the terminal state'; END IF;

 -- (b) idempotent
 IF public.v3_mark_unassigned(op,'guard_expired',cap,clock_timestamp()) THEN
   RAISE EXCEPTION 'second v3_mark_unassigned reported a change'; END IF;
 SELECT count(*) INTO n FROM public.lead_routing_events
 WHERE opportunity_id=op AND event_type='left_unassigned';
 IF n<>1 THEN RAISE EXCEPTION 'left_unassigned duplicated'; END IF;

 -- (f) an already-unassigned lead is terminal for the sweeper
 res := public.v3_advance_routing_tier(op,'primary_guard',clock_timestamp());
 IF res->>'state'<>'unassigned' THEN
   RAISE EXCEPTION 'advance_routing_tier reopened an unassigned lead: %', res; END IF;

 -- (c) EasyBroker promotes to the literal responsible, Atendida never due
 INSERT INTO public.easybroker_contact_request_inbox(eb_request_id,account_key,happened_at)
 VALUES (990001,'unassigned-rollback',t0);
 INSERT INTO public.easybroker_effect_ledger(eb_request_id,opportunity_id)
 VALUES (990001,op);
 SELECT * INTO r FROM public.claim_v3_easybroker_effects(10,t0,interval '2 minutes')
 WHERE eb_request_id=990001;
 IF NOT FOUND THEN RAISE EXCEPTION 'unassigned ledger was not claimed'; END IF;
 IF r.responsible_first_name<>'SIN ASIGNACIÓN' THEN
   RAISE EXCEPTION 'responsible is % not SIN ASIGNACION', r.responsible_first_name; END IF;
 IF NOT r.note_due THEN RAISE EXCEPTION 'note not due'; END IF;
 IF r.attended_due THEN RAISE EXCEPTION 'Atendida due for an unassigned lead'; END IF;
 tok := r.lease_token;

 -- (d) a succeeded note closes the ledger with Atendida skipped
 res := public.finish_v3_easybroker_effect(990001,tok,'note',TRUE,
   jsonb_build_object('eb_request_id','990001','note','RESPONSABLE: SIN ASIGNACIÓN',
     'note_written','true'), t0);
 IF NOT (res->>'ok')::boolean THEN RAISE EXCEPTION 'note finish failed: %', res; END IF;
 SELECT * INTO r FROM public.easybroker_effect_ledger WHERE eb_request_id=990001;
 IF r.note_state<>'succeeded' OR r.attended_state<>'skipped' OR r.close_state<>'completed' THEN
   RAISE EXCEPTION 'ledger is %/%/% after the note', r.note_state,r.attended_state,r.close_state; END IF;
 IF EXISTS(SELECT 1 FROM public.easybroker_effect_attempts
    WHERE eb_request_id=990001 AND effect_kind='attended') THEN
   RAISE EXCEPTION 'an Atendida attempt was created'; END IF;

 -- (g) an unassigned lead with no EasyBroker request still gets one created,
 -- and the resulting effect ledger resolves to the literal responsible.
 SELECT * INTO r FROM public.v3_intake(
   p_account_key=>'unassigned-rollback',p_idempotency_key=>gen_random_uuid()::text,
   p_external_id=>'9999990003',p_property_public_id=>'EB-QJ4964',
   p_email=>gen_random_uuid()::text||'@example.invalid',
   p_offer_context=>jsonb_build_object('name','Sin asignacion sin request'));
 op3:=r.opportunity_id; cap3:=r.capture_event_id;
 PERFORM public.v3_mark_unassigned(op3,'guard_expired',cap3,t0);
 UPDATE public.i24_capture_events
 SET contactado_status='verified', contactado_verified_at=t0,
     route_dispatch_status='dispatched', route_dispatched_at=t0
 WHERE capture_event_id=cap3;
 IF NOT EXISTS(SELECT 1 FROM public.claim_v3_easybroker_request_creations(50,clock_timestamp(),interval '2 minutes') c
    WHERE c.capture_event_id=cap3) THEN
   RAISE EXCEPTION 'unassigned lead was not queued for EasyBroker request creation'; END IF;

 -- the created request correlates back and the note names SIN ASIGNACIÓN
 INSERT INTO public.easybroker_contact_request_inbox(
   eb_request_id,account_key,happened_at,correlation_state)
 VALUES (990003,'unassigned-rollback',t0,'linked');
 INSERT INTO public.easybroker_i24_request_links(
   eb_request_id,i24_capture_event_id,opportunity_id,idempotency_key,match_basis)
 VALUES (990003,cap3,op3,'unassigned-rollback:990003','email');
 res := public.enqueue_v3_easybroker_effect(990003,t0);
 IF res->>'state'<>'awaiting_responsible' THEN
   RAISE EXCEPTION 'unexpected enqueue state: %', res; END IF;
 SELECT * INTO r FROM public.claim_v3_easybroker_effects(10,t0,interval '2 minutes')
 WHERE eb_request_id=990003;
 IF NOT FOUND THEN RAISE EXCEPTION 'created request never became actionable'; END IF;
 IF r.responsible_first_name<>'SIN ASIGNACIÓN' OR r.attended_due THEN
   RAISE EXCEPTION 'created request resolved to %/attended_due=%',
     r.responsible_first_name, r.attended_due; END IF;

 -- Stale leads with no day deadline must not enter automatic creation.
 SELECT * INTO r FROM public.v3_intake(
   p_account_key=>'unassigned-rollback',p_idempotency_key=>gen_random_uuid()::text,
   p_external_id=>'9999990004',p_property_public_id=>'EB-QJ4964',
   p_email=>gen_random_uuid()::text||'@example.invalid',
   p_offer_context=>jsonb_build_object('name','Solicitud antigua'));
 op4:=r.opportunity_id; cap4:=r.capture_event_id;
 PERFORM public.v3_mark_unassigned(op4,'guard_expired',cap4,t0);
 UPDATE public.i24_capture_events
 SET happened_at=clock_timestamp()-interval '2 days',
     contactado_status='verified', contactado_verified_at=t0,
     route_dispatch_status='dispatched', route_dispatched_at=t0
 WHERE capture_event_id=cap4;
 IF EXISTS(SELECT 1 FROM public.claim_v3_easybroker_request_creations(50,clock_timestamp(),interval '2 minutes') c
    WHERE c.capture_event_id=cap4) THEN
   RAISE EXCEPTION 'stale lead entered automatic EasyBroker creation'; END IF;

 -- (e) day SLA: unassigned before the deadline plus a closed ledger is a close
 UPDATE public.i24_capture_events
 SET contactado_status='verified', contactado_verified_at=t0,
     route_dispatch_status='dispatched', route_dispatched_at=t0,
     day_deadline_at=deadline
 WHERE capture_event_id=cap;
 PERFORM public.v3_day_sweep();
 IF EXISTS(SELECT 1 FROM public.v3_day_incidents WHERE capture_event_id=cap) THEN
   RAISE EXCEPTION 'closed unassigned lead raised a day incident'; END IF;

 -- ... and an unclosed EasyBroker ledger past the deadline still does
 SELECT * INTO r FROM public.v3_intake(
   p_account_key=>'unassigned-rollback',p_idempotency_key=>gen_random_uuid()::text,
   p_external_id=>'9999990002',p_property_public_id=>'EB-QJ4964',
   p_email=>gen_random_uuid()::text||'@example.invalid',
   p_offer_context=>jsonb_build_object('name','Sin asignacion pendiente'));
 op2:=r.opportunity_id; cap2:=r.capture_event_id;
 PERFORM public.v3_mark_unassigned(op2,'guard_expired',cap2,t0);
 INSERT INTO public.easybroker_contact_request_inbox(eb_request_id,account_key,happened_at)
 VALUES (990002,'unassigned-rollback',t0);
 INSERT INTO public.easybroker_effect_ledger(eb_request_id,opportunity_id)
 VALUES (990002,op2);
 UPDATE public.i24_capture_events
 SET contactado_status='verified', contactado_verified_at=t0,
     route_dispatch_status='dispatched', route_dispatched_at=t0,
     day_deadline_at=deadline
 WHERE capture_event_id=cap2;
 PERFORM public.v3_day_sweep();
 SELECT count(*) INTO n FROM public.v3_day_incidents
 WHERE capture_event_id=cap2 AND reason='easybroker_not_closed';
 IF n<>1 THEN RAISE EXCEPTION 'open EasyBroker ledger did not raise easybroker_not_closed'; END IF;

 -- the dashboard names the new terminal
 IF (SELECT assignment_method FROM public.v3_leads_dashboard WHERE opportunity_id=op)
    IS DISTINCT FROM 'unassigned' THEN
   RAISE EXCEPTION 'dashboard does not report the unassigned route'; END IF;

 RAISE NOTICE 'V3_UNASSIGNED_TESTS_PASS';
END $$;
