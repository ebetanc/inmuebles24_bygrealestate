\set ON_ERROR_STOP on

CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE public.agents (
  agent_id text PRIMARY KEY
);

CREATE TABLE public.conversations (
  conversation_id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);

\i /work/whatsapp-agent/migrations/0021_lead_routing_v2.sql
\i /work/whatsapp-agent/migrations/0024_upsert_lead_opportunity.sql
\i /work/whatsapp-agent/migrations/0038_recover_legacy_i24_intake.sql

DO $$
DECLARE
  first_conversation uuid := gen_random_uuid();
  recovered_conversation uuid := gen_random_uuid();
  missing_property_conversation uuid := gen_random_uuid();
  first_opportunity bigint;
  recovered record;
  replay record;
BEGIN
  INSERT INTO public.conversations(conversation_id)
  VALUES (first_conversation), (recovered_conversation), (missing_property_conversation);

  SELECT opportunity_id INTO first_opportunity
  FROM public.upsert_lead_opportunity(
    first_conversation, 'listing-1', NULL, NULL, '525539660807',
    'inmuebles24', 'legacy-1', 'queued_night'
  );

  SELECT * INTO recovered
  FROM public.upsert_i24_lead_opportunity_recovering(
    recovered_conversation, 'listing-1', NULL, NULL, '+525539660807',
    'inmuebles24', 'legacy-1', 'queued_night'
  );

  IF recovered.opportunity_id <> first_opportunity
     OR recovered.state <> 'queued_night'
     OR recovered.identity_reason <> 'e164_phone'
     OR recovered.should_route IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'legacy opportunity was not promoted exactly once';
  END IF;

  SELECT * INTO replay
  FROM public.upsert_i24_lead_opportunity_recovering(
    recovered_conversation, 'listing-1', NULL, NULL, '+525539660807',
    'inmuebles24', 'legacy-1', 'queued_night'
  );

  IF replay.opportunity_id <> first_opportunity
     OR replay.should_route IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'replay was not deduplicated';
  END IF;

  IF (SELECT count(*) FROM public.lead_routing_opportunities) <> 1
     OR (SELECT count(*) FROM public.lead_routing_events) <> 2
     OR (SELECT count(*) FROM public.lead_routing_events WHERE event_type = 'identity_recovered') <> 1 THEN
    RAISE EXCEPTION 'recovery created duplicate opportunities or events';
  END IF;

  PERFORM public.upsert_lead_opportunity(
    missing_property_conversation, NULL, NULL, NULL, '525500000001',
    'inmuebles24', 'legacy-no-property', 'queued_night'
  );

  SELECT * INTO replay
  FROM public.upsert_i24_lead_opportunity_recovering(
    missing_property_conversation, NULL, NULL, NULL, '+525500000001',
    'inmuebles24', 'legacy-no-property', 'queued_night'
  );

  IF replay.state <> 'manual_non_deduplicable'
     OR replay.should_route IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'non-routable legacy row should remain manual';
  END IF;
END;
$$;

SELECT 'LEGACY_I24_RECOVERY_PASS';
