-- V3-02 LOCAL DRAFT ONLY: PROPOSED / NO APLICADO. No legacy eb_contact_id change.
CREATE TABLE IF NOT EXISTS public.i24_capture_events (
 capture_event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, account_key TEXT NOT NULL,
 source TEXT NOT NULL CHECK(source='inmuebles24'), external_event_id TEXT NOT NULL,
 property_public_id TEXT, normalized_email TEXT CHECK(normalized_email IS NULL OR normalized_email=LOWER(BTRIM(normalized_email))),
 e164_phone TEXT CHECK(e164_phone IS NULL OR e164_phone ~ '^\+[1-9][0-9]{7,14}$'), email_hash TEXT, phone_hash TEXT,
 sanitized_evidence JSONB NOT NULL DEFAULT '{}'::JSONB, happened_at TIMESTAMPTZ NOT NULL,
 fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), correlation_state TEXT NOT NULL DEFAULT 'pending'
  CHECK(correlation_state IN('pending','awaiting_eb_request','linked','manual_review:no_eb_request','manual_review:ambiguous','manual_review:identity_contradiction','already_linked','conflict')),
 correlation_reason TEXT, correlation_window_start_at TIMESTAMPTZ NOT NULL,
 correlation_horizon_at TIMESTAMPTZ NOT NULL,
 correlated_at TIMESTAMPTZ,
 CHECK (correlation_horizon_at >= correlation_window_start_at),
 UNIQUE(account_key,external_event_id));
CREATE TABLE IF NOT EXISTS public.easybroker_contact_request_inbox (
 eb_request_id BIGINT PRIMARY KEY, account_key TEXT NOT NULL, eb_person_contact_id BIGINT, property_public_id TEXT,
 normalized_email TEXT CHECK(normalized_email IS NULL OR normalized_email=LOWER(BTRIM(normalized_email))),
 e164_phone TEXT CHECK(e164_phone IS NULL OR e164_phone ~ '^\+[1-9][0-9]{7,14}$'), email_hash TEXT, phone_hash TEXT,
 sanitized_evidence JSONB NOT NULL DEFAULT '{}'::JSONB, happened_at TIMESTAMPTZ NOT NULL,
 fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), correlation_state TEXT NOT NULL DEFAULT 'pending'
  CHECK(correlation_state IN('pending','awaiting_eb_request','linked','manual_review:no_eb_request','manual_review:ambiguous','manual_review:identity_contradiction','already_linked','conflict')),
 correlation_reason TEXT, correlated_at TIMESTAMPTZ);
CREATE TABLE IF NOT EXISTS public.easybroker_i24_request_links (
 eb_request_id BIGINT PRIMARY KEY NOT NULL UNIQUE REFERENCES public.easybroker_contact_request_inbox(eb_request_id),
 i24_capture_event_id BIGINT NOT NULL REFERENCES public.i24_capture_events(capture_event_id),
 opportunity_id BIGINT REFERENCES public.lead_routing_opportunities(opportunity_id), idempotency_key TEXT NOT NULL UNIQUE,
 evidence JSONB NOT NULL DEFAULT '{}'::JSONB, match_basis TEXT NOT NULL CHECK(match_basis IN('email','phone','email+phone')),
 delta JSONB NOT NULL DEFAULT '{}'::JSONB, linked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 UNIQUE (i24_capture_event_id));
CREATE TABLE IF NOT EXISTS public.easybroker_ingestion_checkpoints (
 account_key TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'easybroker' CHECK(source='easybroker'), watermark_at TIMESTAMPTZ,
 watermark_request_id BIGINT, overlap INTERVAL NOT NULL DEFAULT INTERVAL '10 minutes', updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), PRIMARY KEY(account_key,source));
CREATE INDEX IF NOT EXISTS easybroker_request_inbox_candidate_idx ON public.easybroker_contact_request_inbox(account_key,property_public_id,happened_at,eb_request_id);
CREATE INDEX IF NOT EXISTS easybroker_request_inbox_pending_idx ON public.easybroker_contact_request_inbox(account_key,fetched_at,eb_request_id) WHERE correlation_state='pending';
ALTER TABLE public.i24_capture_events ENABLE ROW LEVEL SECURITY; ALTER TABLE public.easybroker_contact_request_inbox ENABLE ROW LEVEL SECURITY; ALTER TABLE public.easybroker_i24_request_links ENABLE ROW LEVEL SECURITY; ALTER TABLE public.easybroker_ingestion_checkpoints ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.i24_capture_events,public.easybroker_contact_request_inbox,public.easybroker_i24_request_links,public.easybroker_ingestion_checkpoints FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON TABLE public.i24_capture_events,public.easybroker_contact_request_inbox,public.easybroker_ingestion_checkpoints TO service_role; GRANT SELECT,INSERT ON TABLE public.easybroker_i24_request_links TO service_role;
REVOKE ALL ON SEQUENCE public.i24_capture_events_capture_event_id_seq FROM PUBLIC,anon,authenticated,service_role;
GRANT USAGE,SELECT ON SEQUENCE public.i24_capture_events_capture_event_id_seq TO service_role;
CREATE OR REPLACE FUNCTION public.reject_easybroker_link_mutation() RETURNS TRIGGER AS $$ BEGIN RAISE EXCEPTION 'easybroker_i24_request_links is immutable'; END; $$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;
CREATE OR REPLACE TRIGGER easybroker_i24_request_links_immutable BEFORE UPDATE OR DELETE ON public.easybroker_i24_request_links FOR EACH ROW EXECUTE FUNCTION public.reject_easybroker_link_mutation();

CREATE OR REPLACE FUNCTION public.ingest_easybroker_contact_request_batch(p_account_key TEXT,p_requests JSONB,p_fetched_at TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB AS $$
DECLARE r JSONB; processed_count INTEGER:=0; inserted_count INTEGER:=0; n INTEGER; last_id BIGINT; last_at TIMESTAMPTZ;
BEGIN
 IF NULLIF(BTRIM(p_account_key),'') IS NULL OR p_requests IS NULL OR jsonb_typeof(p_requests)<>'array' OR p_fetched_at IS NULL THEN RAISE EXCEPTION 'invalid EasyBroker inbox batch'; END IF;
 FOR r IN SELECT value FROM jsonb_array_elements(p_requests) LOOP
  IF (r->>'id') !~ '^[0-9]{1,18}$' OR NULLIF(r->>'happened_at','') IS NULL THEN RAISE EXCEPTION 'invalid EasyBroker request'; END IF;
  INSERT INTO public.easybroker_contact_request_inbox(eb_request_id,account_key,eb_person_contact_id,property_public_id,normalized_email,e164_phone,email_hash,phone_hash,sanitized_evidence,happened_at,fetched_at) VALUES((r->>'id')::BIGINT,p_account_key,NULLIF(r->>'contact_id','')::BIGINT,NULLIF(BTRIM(r->>'property_id'),''),NULLIF(LOWER(BTRIM(r->>'email')),''),NULLIF(BTRIM(r->>'phone_e164'),''),NULLIF(r->>'email_hash',''),NULLIF(r->>'phone_hash',''),COALESCE(r->'sanitized_evidence','{}'::JSONB),(r->>'happened_at')::TIMESTAMPTZ,p_fetched_at) ON CONFLICT(eb_request_id) DO NOTHING;
  GET DIAGNOSTICS n=ROW_COUNT; inserted_count:=inserted_count+n; processed_count:=processed_count+1;
  IF last_at IS NULL OR (r->>'happened_at')::TIMESTAMPTZ>last_at OR ((r->>'happened_at')::TIMESTAMPTZ=last_at AND (r->>'id')::BIGINT>COALESCE(last_id,0)) THEN last_at:=(r->>'happened_at')::TIMESTAMPTZ; last_id:=(r->>'id')::BIGINT; END IF;
 END LOOP;
 IF processed_count>0 THEN INSERT INTO public.easybroker_ingestion_checkpoints(account_key,source,watermark_at,watermark_request_id,updated_at) VALUES(p_account_key,'easybroker',last_at,last_id,p_fetched_at) ON CONFLICT(account_key,source) DO UPDATE SET watermark_at=CASE WHEN public.easybroker_ingestion_checkpoints.watermark_at IS NULL OR EXCLUDED.watermark_at>public.easybroker_ingestion_checkpoints.watermark_at OR (EXCLUDED.watermark_at=public.easybroker_ingestion_checkpoints.watermark_at AND EXCLUDED.watermark_request_id>COALESCE(public.easybroker_ingestion_checkpoints.watermark_request_id,0)) THEN EXCLUDED.watermark_at ELSE public.easybroker_ingestion_checkpoints.watermark_at END,watermark_request_id=CASE WHEN public.easybroker_ingestion_checkpoints.watermark_at IS NULL OR EXCLUDED.watermark_at>public.easybroker_ingestion_checkpoints.watermark_at OR (EXCLUDED.watermark_at=public.easybroker_ingestion_checkpoints.watermark_at AND EXCLUDED.watermark_request_id>COALESCE(public.easybroker_ingestion_checkpoints.watermark_request_id,0)) THEN EXCLUDED.watermark_request_id ELSE public.easybroker_ingestion_checkpoints.watermark_request_id END,updated_at=EXCLUDED.updated_at; END IF;
 RETURN jsonb_build_object('ok',true,'persisted',inserted_count,'processed',processed_count,'checkpoint_advanced',processed_count>0);
END; $$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path=pg_catalog,public;

CREATE OR REPLACE FUNCTION public.correlate_easybroker_request(p_exact_request_id BIGINT,p_i24_capture_event_id BIGINT,p_opportunity_id BIGINT,p_idempotency_key TEXT,p_evidence JSONB,p_now TIMESTAMPTZ DEFAULT NOW()) RETURNS JSONB AS $$
DECLARE e public.i24_capture_events; q public.easybroker_contact_request_inbox; candidate BIGINT; candidates INTEGER; state TEXT; basis TEXT;
BEGIN
 IF p_i24_capture_event_id IS NULL OR NULLIF(BTRIM(p_idempotency_key),'') IS NULL OR p_now IS NULL THEN RAISE EXCEPTION 'invalid capture correlation input'; END IF;
 PERFORM pg_advisory_xact_lock(p_i24_capture_event_id); SELECT * INTO e FROM public.i24_capture_events WHERE capture_event_id=p_i24_capture_event_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'capture event not found'; END IF;
 IF p_opportunity_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.lead_routing_opportunities o JOIN public.conversations c ON c.conversation_id=o.conversation_id WHERE o.opportunity_id=p_opportunity_id AND UPPER(NULLIF(BTRIM(c.property_public_id),''))=UPPER(NULLIF(BTRIM(e.property_public_id),''))) THEN RAISE EXCEPTION 'contextual opportunity property mismatch'; END IF;
 IF p_exact_request_id IS NULL THEN state:=CASE WHEN NOT EXISTS(SELECT 1 FROM public.easybroker_ingestion_checkpoints cp WHERE cp.account_key=e.account_key AND cp.source='easybroker' AND cp.watermark_at>=e.correlation_horizon_at) THEN 'awaiting_eb_request' ELSE 'manual_review:no_eb_request' END; UPDATE public.i24_capture_events SET correlation_state=state,correlation_reason=state,correlated_at=p_now WHERE capture_event_id=p_i24_capture_event_id; RETURN jsonb_build_object('ok',false,'state',state,'correlated_at',p_now); END IF;
 SELECT * INTO q FROM public.easybroker_contact_request_inbox WHERE eb_request_id=p_exact_request_id FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'exact request not found'; END IF;
 IF EXISTS(SELECT 1 FROM public.easybroker_i24_request_links l WHERE l.eb_request_id=p_exact_request_id) THEN IF EXISTS(SELECT 1 FROM public.easybroker_i24_request_links l WHERE l.eb_request_id=p_exact_request_id AND l.i24_capture_event_id=p_i24_capture_event_id AND (p_opportunity_id IS NULL OR l.opportunity_id=p_opportunity_id)) THEN UPDATE public.easybroker_contact_request_inbox SET correlation_state='already_linked',correlation_reason='already_linked',correlated_at=p_now WHERE eb_request_id=p_exact_request_id; UPDATE public.i24_capture_events SET correlation_state='already_linked',correlation_reason='already_linked',correlated_at=p_now WHERE capture_event_id=p_i24_capture_event_id; RETURN jsonb_build_object('ok',true,'state','already_linked','correlated_at',p_now); END IF; UPDATE public.easybroker_contact_request_inbox SET correlation_state='conflict',correlation_reason='conflict',correlated_at=p_now WHERE eb_request_id=p_exact_request_id; UPDATE public.i24_capture_events SET correlation_state='conflict',correlation_reason='conflict',correlated_at=p_now WHERE capture_event_id=p_i24_capture_event_id; RETURN jsonb_build_object('ok',false,'state','conflict','correlated_at',p_now); END IF;
 SELECT COUNT(DISTINCT i.eb_request_id)::INTEGER,MIN(i.eb_request_id) INTO candidates,candidate FROM public.easybroker_contact_request_inbox i WHERE i.account_key=e.account_key AND UPPER(NULLIF(BTRIM(i.property_public_id),''))=UPPER(NULLIF(BTRIM(e.property_public_id),'')) AND i.happened_at BETWEEN e.correlation_window_start_at AND e.correlation_horizon_at AND ((e.normalized_email IS NOT NULL AND i.normalized_email IS NOT NULL AND LOWER(BTRIM(e.normalized_email))=LOWER(BTRIM(i.normalized_email))) OR (e.e164_phone IS NOT NULL AND i.e164_phone IS NOT NULL AND BTRIM(e.e164_phone)=BTRIM(i.e164_phone))) AND NOT ((e.normalized_email IS NOT NULL AND i.normalized_email IS NOT NULL AND LOWER(BTRIM(e.normalized_email))<>LOWER(BTRIM(i.normalized_email))) OR (e.e164_phone IS NOT NULL AND i.e164_phone IS NOT NULL AND BTRIM(e.e164_phone)<>BTRIM(i.e164_phone)));
 IF candidates=1 AND candidate=p_exact_request_id THEN basis:=CASE WHEN e.normalized_email IS NOT NULL AND q.normalized_email IS NOT NULL AND e.e164_phone IS NOT NULL AND q.e164_phone IS NOT NULL THEN 'email+phone' WHEN e.normalized_email IS NOT NULL THEN 'email' ELSE 'phone' END; INSERT INTO public.easybroker_i24_request_links(eb_request_id,i24_capture_event_id,opportunity_id,idempotency_key,evidence,match_basis,delta,linked_at) VALUES(p_exact_request_id,p_i24_capture_event_id,p_opportunity_id,p_idempotency_key,COALESCE(p_evidence,'{}'::JSONB),basis,'{}'::JSONB,p_now); state:='linked'; ELSIF candidates>1 THEN state:='manual_review:ambiguous'; ELSE state:='manual_review:identity_contradiction'; END IF;
 UPDATE public.easybroker_contact_request_inbox SET correlation_state=state,correlation_reason=state,correlated_at=p_now WHERE eb_request_id=p_exact_request_id; UPDATE public.i24_capture_events SET correlation_state=state,correlation_reason=state,correlated_at=p_now WHERE capture_event_id=p_i24_capture_event_id; RETURN jsonb_build_object('ok',state='linked','state',state,'eb_request_id',p_exact_request_id,'opportunity_id',p_opportunity_id,'match_basis',basis,'candidate_count',candidates,'correlated_at',p_now);
EXCEPTION WHEN unique_violation THEN
 UPDATE public.easybroker_contact_request_inbox SET correlation_state='conflict',correlation_reason='unique_link_conflict',correlated_at=p_now WHERE eb_request_id=p_exact_request_id;
 UPDATE public.i24_capture_events SET correlation_state='conflict',correlation_reason='unique_link_conflict',correlated_at=p_now WHERE capture_event_id=p_i24_capture_event_id;
 RETURN jsonb_build_object('ok',false,'state','conflict','eb_request_id',p_exact_request_id,'candidate_count',candidates,'correlated_at',p_now);
END; $$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path=pg_catalog,public;
REVOKE ALL ON FUNCTION public.reject_easybroker_link_mutation(),public.ingest_easybroker_contact_request_batch(TEXT,JSONB,TIMESTAMPTZ),public.correlate_easybroker_request(BIGINT,BIGINT,BIGINT,TEXT,JSONB,TIMESTAMPTZ) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_easybroker_contact_request_batch(TEXT,JSONB,TIMESTAMPTZ),public.correlate_easybroker_request(BIGINT,BIGINT,BIGINT,TEXT,JSONB,TIMESTAMPTZ) TO service_role;
