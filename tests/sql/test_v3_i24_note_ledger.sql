-- Execute after the full migration chain, in the SAME transaction, then ROLLBACK.
-- No HTTP calls, no Inmuebles24 writes, nothing committed.
DO $$
DECLARE
  r record; n integer; i integer;
  op1 bigint; op2 bigint; op3 bigint;
  cap1 bigint; cap2 bigint; cap3 bigint;
  tok1 uuid; tok2 uuid; expected text;
  t0 timestamptz := clock_timestamp() - interval '1 hour';
BEGIN
 SELECT split_part(regexp_replace(BTRIM(a.name), '\s+', ' ', 'g'), ' ', 1)
   INTO expected FROM public.agents a WHERE a.agent_id='agent_gina';
 IF expected IS NULL THEN RAISE EXCEPTION 'missing agent_gina seed'; END IF;

 -- (a) a claimed lead enqueues the responsible's first name
 SELECT * INTO r FROM public.v3_intake(
   p_account_key=>'note-ledger-rollback',p_idempotency_key=>gen_random_uuid()::text,
   p_external_id=>'266700001',p_property_public_id=>'EB-QJ4964',
   p_email=>gen_random_uuid()::text||'@example.invalid',
   p_offer_context=>jsonb_build_object('name','Nota asignada'));
 op1:=r.opportunity_id; cap1:=r.capture_event_id;
 UPDATE public.lead_routing_opportunities
 SET state='assigned', assigned_agent_id='agent_gina', assigned_at=t0
 WHERE opportunity_id=op1;
 SELECT * INTO r FROM public.i24_note_ledger WHERE opportunity_id=op1;
 IF NOT FOUND THEN RAISE EXCEPTION 'assigned lead did not enqueue a note'; END IF;
 IF r.note_text<>expected THEN
   RAISE EXCEPTION 'note is % not %', r.note_text, expected; END IF;
 IF r.i24_lead_id<>'266700001' THEN
   RAISE EXCEPTION 'note points at conversation %', r.i24_lead_id; END IF;
 IF r.capture_event_id<>cap1 THEN RAISE EXCEPTION 'wrong capture on the note'; END IF;
 IF r.state<>'pending' OR r.attempts<>0 OR r.lease_token IS NOT NULL THEN
   RAISE EXCEPTION 'fresh note is %/%/%', r.state, r.attempts, r.lease_token; END IF;

 -- (b) a lead nobody took enqueues the literal responsible
 SELECT * INTO r FROM public.v3_intake(
   p_account_key=>'note-ledger-rollback',p_idempotency_key=>gen_random_uuid()::text,
   p_external_id=>'266700002',p_property_public_id=>'EB-QJ4964',
   p_email=>gen_random_uuid()::text||'@example.invalid',
   p_offer_context=>jsonb_build_object('name','Nota sin asignacion'));
 op2:=r.opportunity_id; cap2:=r.capture_event_id;
 UPDATE public.lead_routing_opportunities SET state='unassigned', unassigned_at=t0
 WHERE opportunity_id=op2;
 SELECT * INTO r FROM public.i24_note_ledger WHERE opportunity_id=op2;
 IF NOT FOUND OR r.note_text<>'SIN ASIGNACIÓN' THEN
   RAISE EXCEPTION 'unassigned lead enqueued %', r.note_text; END IF;

 -- (c) re-stamping the same state is a no-op, not an error and not a duplicate
 UPDATE public.lead_routing_opportunities SET state='unassigned', updated_at=clock_timestamp()
 WHERE opportunity_id=op2;
 SELECT count(*) INTO n FROM public.i24_note_ledger WHERE opportunity_id=op2;
 IF n<>1 THEN RAISE EXCEPTION 'same-state update produced % notes', n; END IF;

 -- (d) no Inmuebles24 conversation id means there is nothing to write on
 SELECT * INTO r FROM public.v3_intake(
   p_account_key=>'note-ledger-rollback',p_idempotency_key=>gen_random_uuid()::text,
   p_property_public_id=>'EB-QJ4964',
   p_email=>gen_random_uuid()::text||'@example.invalid',
   p_offer_context=>jsonb_build_object('name','Nota sin conversacion'));
 op3:=r.opportunity_id; cap3:=r.capture_event_id;
 IF (SELECT e.external_event_id FROM public.i24_capture_events e
     WHERE e.capture_event_id=cap3) IS NOT NULL THEN
   RAISE EXCEPTION 'fixture capture unexpectedly has an external id'; END IF;
 UPDATE public.lead_routing_opportunities SET state='unassigned', unassigned_at=t0
 WHERE opportunity_id=op3;
 IF EXISTS(SELECT 1 FROM public.i24_note_ledger WHERE opportunity_id=op3) THEN
   RAISE EXCEPTION 'note enqueued without a conversation id'; END IF;

 -- (e) the worker leases both pending notes
 n:=0;
 FOR r IN SELECT * FROM public.claim_v3_i24_notes(10,t0) LOOP
   n:=n+1;
   IF r.lease_token IS NULL THEN RAISE EXCEPTION 'claim returned no lease token'; END IF;
   IF r.attempt<>1 THEN RAISE EXCEPTION 'first attempt is %', r.attempt; END IF;
   IF r.opportunity_id=op1 THEN tok1:=r.lease_token; END IF;
   IF r.opportunity_id=op2 THEN tok2:=r.lease_token; END IF;
 END LOOP;
 IF n<>2 THEN RAISE EXCEPTION 'claim returned % rows not 2', n; END IF;
 IF tok1 IS NULL OR tok2 IS NULL THEN RAISE EXCEPTION 'a note was not claimed'; END IF;
 SELECT * INTO r FROM public.i24_note_ledger WHERE opportunity_id=op1;
 IF r.state<>'leased' OR r.lease_until IS DISTINCT FROM t0+interval '3 minutes' THEN
   RAISE EXCEPTION 'lease is %/%', r.state, r.lease_until; END IF;

 -- (g) somebody else's lease closes nothing
 IF public.finish_v3_i24_note(op1,gen_random_uuid(),TRUE,jsonb_build_object('note_written',true)) THEN
   RAISE EXCEPTION 'finish accepted a foreign lease token'; END IF;
 IF (SELECT l.state FROM public.i24_note_ledger l WHERE l.opportunity_id=op1)<>'leased' THEN
   RAISE EXCEPTION 'foreign lease token changed the note'; END IF;

 -- (h) a written note is terminal and keeps one evidence entry
 IF NOT public.finish_v3_i24_note(op2,tok2,TRUE,jsonb_build_object('note_written',true)) THEN
   RAISE EXCEPTION 'finish rejected a valid lease'; END IF;
 SELECT * INTO r FROM public.i24_note_ledger WHERE opportunity_id=op2;
 IF r.state<>'succeeded' OR r.lease_token IS NOT NULL OR r.lease_until IS NOT NULL THEN
   RAISE EXCEPTION 'succeeded note is %/%/%', r.state, r.lease_token, r.lease_until; END IF;
 SELECT count(*) INTO n FROM jsonb_object_keys(r.evidence);
 IF n<>1 THEN RAISE EXCEPTION 'succeeded note carries % evidence entries', n; END IF;

 -- (f) five failures park the note for a human, and it stops being claimable
 FOR i IN 1..4 LOOP
   IF NOT public.finish_v3_i24_note(op1,tok1,FALSE,jsonb_build_object('error_code','i24_unreachable')) THEN
     RAISE EXCEPTION 'failure % was not recorded', i; END IF;
   IF (SELECT l.state FROM public.i24_note_ledger l WHERE l.opportunity_id=op1)<>'failed' THEN
     RAISE EXCEPTION 'failure % did not leave the note retryable', i; END IF;
   tok1:=NULL;
   SELECT c.lease_token INTO tok1 FROM public.claim_v3_i24_notes(10,t0) c
   WHERE c.opportunity_id=op1;
   IF tok1 IS NULL THEN RAISE EXCEPTION 'note % was not re-leased', i; END IF;
 END LOOP;
 SELECT * INTO r FROM public.i24_note_ledger WHERE opportunity_id=op1;
 IF r.attempts<>5 THEN RAISE EXCEPTION 'attempts is % not 5', r.attempts; END IF;
 IF NOT public.finish_v3_i24_note(op1,tok1,FALSE,jsonb_build_object('error_code','i24_unreachable')) THEN
   RAISE EXCEPTION 'the fifth failure was not recorded'; END IF;
 SELECT * INTO r FROM public.i24_note_ledger WHERE opportunity_id=op1;
 IF r.state<>'manual_review' THEN
   RAISE EXCEPTION 'exhausted note is % not manual_review', r.state; END IF;
 SELECT count(*) INTO n FROM public.claim_v3_i24_notes(10,t0);
 IF n<>0 THEN RAISE EXCEPTION 'a parked note was claimed again'; END IF;

 RAISE NOTICE 'V3_I24_NOTE_LEDGER_TESTS_PASS';
END $$;
