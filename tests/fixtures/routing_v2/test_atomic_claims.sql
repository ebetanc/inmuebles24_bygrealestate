\set ON_ERROR_STOP on

INSERT INTO public.agents(agent_id,name,whatsapp_number,is_available) VALUES
  ('claim_agent_a','Claim Agent A','525500000021',true),
  ('claim_agent_b','Claim Agent B','525500000022',true)
ON CONFLICT(agent_id) DO UPDATE SET is_available=true;

DO $$
DECLARE v_conversation UUID; v_opp BIGINT; v_attempt BIGINT; v_result TEXT; v_assigned TEXT;
BEGIN
  INSERT INTO public.conversations(lead_phone,lead_name,current_property)
  VALUES('525599900001','Atomic Claim Lead','EB-CLAIM-1') RETURNING conversation_id INTO v_conversation;
  INSERT INTO public.lead_routing_opportunities(conversation_id,property_id,identity_key,identity_reason,state,routing_tier,delivery_status,delivered_at,expires_at)
  VALUES(v_conversation,'EB-CLAIM-1','phone:+525599900001','e164_phone','owner_open','owner','delivered',NOW(),NOW()+INTERVAL '5 minutes')
  RETURNING opportunity_id INTO v_opp;
  INSERT INTO public.lead_routing_delivery_attempts(opportunity_id,routing_tier,client_request_id,status,target_agent_id,target_number,delivered_at)
  VALUES(v_opp,'owner','claim-fixture-owner','delivered','claim_agent_a','525500000021',NOW()) RETURNING attempt_id INTO v_attempt;
  UPDATE public.lead_routing_opportunities SET current_delivery_attempt_id=v_attempt WHERE opportunity_id=v_opp;

  SELECT claim_status INTO v_result FROM public.claim_lead_opportunity(v_opp,'owner','claim_agent_a',encode(digest('525500000021','sha256'),'hex'),'claim-fixture-first');
  IF v_result<>'accepted' THEN RAISE EXCEPTION 'first valid claim was not accepted'; END IF;
  SELECT claim_status INTO v_result FROM public.claim_lead_opportunity(v_opp,'owner','claim_agent_b',encode(digest('525500000022','sha256'),'hex'),'claim-fixture-second');
  IF v_result<>'already_assigned' THEN RAISE EXCEPTION 'second claim did not lose deterministically'; END IF;
  SELECT claim_status INTO v_result FROM public.claim_lead_opportunity(v_opp,'owner','claim_agent_a',encode(digest('525500000021','sha256'),'hex'),'claim-fixture-retry');
  IF v_result<>'accepted' THEN RAISE EXCEPTION 'winner retry was not idempotent'; END IF;
  UPDATE public.agents SET is_available=false,whatsapp_number='525500000099' WHERE agent_id='claim_agent_a';
  SELECT claim_status INTO v_result FROM public.claim_lead_opportunity(v_opp,'owner','claim_agent_a',encode(digest('525500000021','sha256'),'hex'),'claim-fixture-first');
  IF v_result<>'accepted' THEN RAISE EXCEPTION 'persisted replay changed after actor profile update'; END IF;
  UPDATE public.agents SET is_available=true,whatsapp_number='525500000021' WHERE agent_id='claim_agent_a';
  SELECT assigned_agent_id INTO v_assigned FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_assigned<>'claim_agent_a' THEN RAISE EXCEPTION 'late claim reassigned winner'; END IF;
END $$;

DO $$
DECLARE v_opp BIGINT; v_attempt BIGINT; v_result TEXT;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier,delivery_status,expires_at)
  VALUES('EB-CLAIM-PENDING','email:claim-pending@example.test','normalized_email','delivery_requested','owner','requested',NOW()+INTERVAL '5 minutes')
  RETURNING opportunity_id INTO v_opp;
  INSERT INTO public.lead_routing_delivery_attempts(opportunity_id,routing_tier,client_request_id,status,target_agent_id,target_number)
  VALUES(v_opp,'owner','claim-fixture-pending','sent','claim_agent_a','525500000021') RETURNING attempt_id INTO v_attempt;
  UPDATE public.lead_routing_opportunities SET current_delivery_attempt_id=v_attempt WHERE opportunity_id=v_opp;
  SELECT claim_status INTO v_result FROM public.claim_lead_opportunity(v_opp,'owner','claim_agent_a',encode(digest('525500000021','sha256'),'hex'),'claim-fixture-pending-result');
  IF v_result<>'delivery_pending' THEN RAISE EXCEPTION 'undelivered claim was not pending'; END IF;

  UPDATE public.lead_routing_opportunities SET state='owner_open',delivery_status='delivered',delivered_at=NOW(),expires_at=NOW() WHERE opportunity_id=v_opp;
  UPDATE public.lead_routing_delivery_attempts SET status='delivered',delivered_at=NOW() WHERE attempt_id=v_attempt;
  SELECT claim_status INTO v_result FROM public.claim_lead_opportunity(v_opp,'owner','claim_agent_a',encode(digest('525500000021','sha256'),'hex'),'claim-fixture-boundary');
  IF v_result<>'expired' THEN RAISE EXCEPTION 'claim at exact expiry boundary was accepted'; END IF;

  UPDATE public.lead_routing_opportunities SET expires_at=NOW()+INTERVAL '5 minutes' WHERE opportunity_id=v_opp;
  SELECT claim_status INTO v_result FROM public.claim_lead_opportunity(v_opp,'owner','claim_agent_b',encode(digest('525500000022','sha256'),'hex'),'claim-fixture-unauthorized');
  IF v_result<>'not_authorized' THEN RAISE EXCEPTION 'wrong agent was not rejected'; END IF;

  BEGIN
    PERFORM public.claim_lead_opportunity(v_opp,'owner','claim_agent_b',encode(digest('525500000022','sha256'),'hex'),'claim-fixture-boundary');
    RAISE EXCEPTION 'idempotency collision unexpectedly accepted';
  EXCEPTION WHEN others THEN
    IF SQLERRM NOT LIKE '%collision%' THEN RAISE; END IF;
  END;
END $$;

DO $$
DECLARE v_opp BIGINT; v_attempt BIGINT; v_result TEXT;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier,delivery_status,delivered_at,expires_at)
  VALUES('EB-CLAIM-OLD','email:claim-old@example.test','normalized_email','primary_guard_open','primary_guard','delivered',NOW(),NOW()+INTERVAL '5 minutes')
  RETURNING opportunity_id INTO v_opp;
  INSERT INTO public.lead_routing_delivery_attempts(opportunity_id,routing_tier,client_request_id,status,target_agent_id,target_number,delivered_at)
  VALUES(v_opp,'primary_guard','claim-fixture-primary','delivered','claim_agent_b','525500000022',NOW()) RETURNING attempt_id INTO v_attempt;
  UPDATE public.lead_routing_opportunities SET current_delivery_attempt_id=v_attempt WHERE opportunity_id=v_opp;
  SELECT claim_status INTO v_result FROM public.claim_lead_opportunity(v_opp,'owner','claim_agent_a',encode(digest('525500000021','sha256'),'hex'),'claim-fixture-old-tier');
  IF v_result<>'expired' THEN RAISE EXCEPTION 'old owner tier was not rejected'; END IF;
  IF (SELECT assigned_agent_id IS NOT NULL FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp) THEN RAISE EXCEPTION 'old tier mutated assignment'; END IF;
END $$;

