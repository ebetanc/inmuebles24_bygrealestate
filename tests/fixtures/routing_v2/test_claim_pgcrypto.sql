\set ON_ERROR_STOP on

-- 0034 regression: claim_lead_opportunity must resolve digest() with pgcrypto installed in
-- the `extensions` schema, exactly like Supabase. The pre-0034 gate installed pgcrypto in
-- `public`, which masked the production failure ("function digest(text, unknown) does not
-- exist") — this fixture fails fast if the gate environment repeats that layout.
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
    WHERE e.extname='pgcrypto' AND n.nspname='extensions'
  ) THEN
    RAISE EXCEPTION 'gate must install pgcrypto in schema extensions (Supabase layout)';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE p.proname='digest' AND n.nspname='public'
  ) THEN
    RAISE EXCEPTION 'digest() must not exist in public — that layout produced the false green';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='claim_lead_opportunity'
      AND p.proconfig @> ARRAY['search_path=pg_catalog, public, extensions']
  ) THEN
    RAISE EXCEPTION '0034 not applied: claim_lead_opportunity search_path lacks extensions';
  END IF;
END $$;

INSERT INTO public.agents(agent_id,name,whatsapp_number,is_available) VALUES
  ('pgcrypto_agent','Pgcrypto Agent','525500000031',true)
ON CONFLICT(agent_id) DO UPDATE SET is_available=true,whatsapp_number='525500000031';

DO $$
DECLARE v_opp BIGINT; v_attempt BIGINT; v_result TEXT; v_assigned TEXT;
BEGIN
  INSERT INTO public.lead_routing_opportunities(property_id,identity_key,identity_reason,state,routing_tier,delivery_status,delivered_at,expires_at)
  VALUES('EB-PGCRYPTO-1','email:pgcrypto@example.test','normalized_email','owner_open','owner','delivered',NOW(),NOW()+INTERVAL '5 minutes')
  RETURNING opportunity_id INTO v_opp;
  INSERT INTO public.lead_routing_delivery_attempts(opportunity_id,routing_tier,client_request_id,status,target_agent_id,target_number,delivered_at)
  VALUES(v_opp,'owner','pgcrypto-fixture-owner','delivered','pgcrypto_agent','525500000031',NOW()) RETURNING attempt_id INTO v_attempt;
  UPDATE public.lead_routing_opportunities SET current_delivery_attempt_id=v_attempt WHERE opportunity_id=v_opp;

  -- The internal digest() (actor auth) is what broke in production pre-0034.
  SELECT claim_status INTO v_result FROM public.claim_lead_opportunity(v_opp,'owner','pgcrypto_agent',encode(extensions.digest('525500000031','sha256'),'hex'),'pgcrypto-fixture-claim');
  IF v_result<>'accepted' THEN RAISE EXCEPTION 'claim was not accepted with pgcrypto in extensions (got %)',v_result; END IF;
  SELECT claim_status INTO v_result FROM public.claim_lead_opportunity(v_opp,'owner','pgcrypto_agent',encode(extensions.digest('525500000031','sha256'),'hex'),'pgcrypto-fixture-claim');
  IF v_result<>'accepted' THEN RAISE EXCEPTION 'idempotent replay changed result (got %)',v_result; END IF;
  SELECT assigned_agent_id INTO v_assigned FROM public.lead_routing_opportunities WHERE opportunity_id=v_opp;
  IF v_assigned<>'pgcrypto_agent' THEN RAISE EXCEPTION 'assignment missing after accepted claim'; END IF;
END $$;

ROLLBACK;
