-- LRV2-008: durable delivery outbox/inbox. 0026-0029 are reserved by later tickets.
CREATE TABLE IF NOT EXISTS public.lead_routing_delivery_attempts (
  attempt_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  opportunity_id BIGINT NOT NULL REFERENCES public.lead_routing_opportunities(opportunity_id),
  routing_tier TEXT NOT NULL CHECK (routing_tier IN ('owner','primary_guard','backup_guard')),
  client_request_id TEXT NOT NULL UNIQUE,
  provider_message_id TEXT UNIQUE,
  status TEXT NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','sent','delivered','failed')),
  target_agent_id TEXT,
  target_number TEXT,
  claimed_at TIMESTAMPTZ,
  lease_expires_at TIMESTAMPTZ,
  lease_token TEXT,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  bound_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (opportunity_id, routing_tier, client_request_id)
);

CREATE TABLE IF NOT EXISTS public.lead_routing_delivery_callbacks (
  callback_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider_message_id TEXT NOT NULL,
  delivery_status TEXT NOT NULL CHECK (delivery_status IN ('sent','delivered','failed')),
  provider_timestamp TIMESTAMPTZ,
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reconciled_at TIMESTAMPTZ,
  UNIQUE (provider_message_id, delivery_status)
);

ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS current_delivery_attempt_id BIGINT;
ALTER TABLE public.lead_routing_opportunities DROP CONSTRAINT IF EXISTS lead_routing_opportunities_state_check;
ALTER TABLE public.lead_routing_opportunities ADD CONSTRAINT lead_routing_opportunities_state_check CHECK (state IN ('captured','deduplicated','resolved','delivery_requested','guard_delivery_pending','delivered','owner_open','primary_guard_open','backup_guard_open','assigned','unassigned_alerted','queued_night','manual_non_deduplicable','safe_mode','closed_won','closed_lost'));
ALTER TABLE public.lead_routing_opportunities DROP CONSTRAINT IF EXISTS lead_routing_opportunities_current_delivery_attempt_fk;
ALTER TABLE public.lead_routing_opportunities ADD CONSTRAINT lead_routing_opportunities_current_delivery_attempt_fk FOREIGN KEY(current_delivery_attempt_id) REFERENCES public.lead_routing_delivery_attempts(attempt_id);

ALTER TABLE public.lead_routing_delivery_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lead_routing_delivery_callbacks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lead_routing_delivery_attempts, public.lead_routing_delivery_callbacks FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.lead_routing_delivery_attempts, public.lead_routing_delivery_callbacks FROM service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.lead_routing_delivery_attempts TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.lead_routing_delivery_callbacks TO service_role;
REVOKE ALL ON SEQUENCE public.lead_routing_delivery_attempts_attempt_id_seq, public.lead_routing_delivery_callbacks_callback_id_seq FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lead_routing_delivery_attempts_attempt_id_seq, public.lead_routing_delivery_callbacks_callback_id_seq FROM service_role;
GRANT USAGE, SELECT ON SEQUENCE public.lead_routing_delivery_attempts_attempt_id_seq, public.lead_routing_delivery_callbacks_callback_id_seq TO service_role;

DROP FUNCTION IF EXISTS public.create_delivery_attempt(BIGINT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public.create_delivery_attempt(BIGINT,TEXT,TEXT,TEXT,TEXT);
CREATE FUNCTION public.create_delivery_attempt(p_opportunity_id BIGINT, p_tier TEXT, p_client_request_id TEXT, p_target_agent_id TEXT, p_target_number TEXT)
RETURNS TABLE (
  attempt_id BIGINT, opportunity_id BIGINT, routing_tier TEXT, client_request_id TEXT,
  provider_message_id TEXT, status TEXT, target_agent_id TEXT, target_number TEXT,
  claimed_at TIMESTAMPTZ, lease_expires_at TIMESTAMPTZ, lease_token TEXT,
  requested_at TIMESTAMPTZ, bound_at TIMESTAMPTZ, delivered_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ, created_at TIMESTAMPTZ, should_send BOOLEAN
) AS $$
DECLARE v_attempt public.lead_routing_delivery_attempts; v_opportunity public.lead_routing_opportunities; v_event public.lead_routing_events; v_should_send BOOLEAN:=false;
BEGIN
  IF p_tier NOT IN ('owner','primary_guard','backup_guard') OR NULLIF(btrim(p_client_request_id),'') IS NULL OR NULLIF(btrim(p_target_number),'') IS NULL THEN RAISE EXCEPTION 'invalid delivery attempt'; END IF;
  SELECT o.* INTO v_opportunity FROM public.lead_routing_opportunities o WHERE o.opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR v_opportunity.state IN ('assigned','unassigned_alerted','closed_won','closed_lost') THEN RAISE EXCEPTION 'opportunity cannot request delivery'; END IF;
  INSERT INTO public.lead_routing_events AS e(opportunity_id,event_type,routing_tier,idempotency_key,external_evidence)
  VALUES(p_opportunity_id,'delivery_requested',p_tier,'delivery-requested:'||p_client_request_id,jsonb_build_object('client_request_id',p_client_request_id)) ON CONFLICT(idempotency_key) DO NOTHING;
  SELECT e.* INTO v_event FROM public.lead_routing_events e WHERE e.idempotency_key='delivery-requested:'||p_client_request_id;
  IF v_event.opportunity_id IS DISTINCT FROM p_opportunity_id OR v_event.event_type<>'delivery_requested' OR v_event.routing_tier IS DISTINCT FROM p_tier THEN RAISE EXCEPTION 'delivery request event collision'; END IF;
  INSERT INTO public.lead_routing_delivery_attempts AS a(opportunity_id,routing_tier,client_request_id,target_agent_id,target_number,claimed_at,lease_expires_at,lease_token)
  VALUES(p_opportunity_id,p_tier,p_client_request_id,p_target_agent_id,p_target_number,NOW(),NOW()+INTERVAL '2 minutes',gen_random_uuid()::text) ON CONFLICT ON CONSTRAINT lead_routing_delivery_attempts_client_request_id_key DO NOTHING RETURNING * INTO v_attempt;
  v_should_send:=FOUND;
  IF NOT v_should_send THEN SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts a WHERE a.client_request_id=p_client_request_id FOR UPDATE;
    IF v_attempt.opportunity_id IS DISTINCT FROM p_opportunity_id OR v_attempt.routing_tier IS DISTINCT FROM p_tier OR v_attempt.target_agent_id IS DISTINCT FROM p_target_agent_id OR v_attempt.target_number IS DISTINCT FROM p_target_number THEN RAISE EXCEPTION 'client_request_id collision'; END IF;
    IF v_attempt.status='requested' AND v_attempt.provider_message_id IS NULL AND v_attempt.lease_expires_at<=NOW() AND v_opportunity.current_delivery_attempt_id=v_attempt.attempt_id THEN
      UPDATE public.lead_routing_delivery_attempts a SET claimed_at=NOW(),lease_expires_at=NOW()+INTERVAL '2 minutes',lease_token=gen_random_uuid()::text WHERE a.attempt_id=v_attempt.attempt_id RETURNING a.* INTO v_attempt;
      v_should_send:=true;
    END IF;
  END IF;
  IF v_should_send THEN
    UPDATE public.lead_routing_opportunities o SET state='delivery_requested',routing_tier=p_tier,delivery_status='requested',delivery_requested_at=NOW(),current_delivery_attempt_id=v_attempt.attempt_id,updated_at=NOW()
    WHERE o.opportunity_id=p_opportunity_id AND o.delivered_at IS NULL
      AND ((p_tier='owner' AND (o.state='resolved' OR (o.state='delivery_requested' AND o.routing_tier='owner' AND (o.current_delivery_attempt_id IS NULL OR o.current_delivery_attempt_id=v_attempt.attempt_id)))) OR (p_tier IN ('primary_guard','backup_guard') AND o.routing_tier=p_tier AND o.state='guard_delivery_pending'));
    IF NOT FOUND THEN RAISE EXCEPTION 'stale delivery attempt tier/state'; END IF;
  END IF;
  RETURN QUERY SELECT v_attempt.attempt_id,v_attempt.opportunity_id,v_attempt.routing_tier,v_attempt.client_request_id,v_attempt.provider_message_id,v_attempt.status,v_attempt.target_agent_id,v_attempt.target_number,v_attempt.claimed_at,v_attempt.lease_expires_at,v_attempt.lease_token,v_attempt.requested_at,v_attempt.bound_at,v_attempt.delivered_at,v_attempt.failed_at,v_attempt.created_at,v_should_send;
END; $$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

CREATE OR REPLACE FUNCTION public.reconcile_delivery_callback(p_provider_message_id TEXT)
RETURNS public.lead_routing_opportunities AS $$
DECLARE v_attempt public.lead_routing_delivery_attempts; v_cb public.lead_routing_delivery_callbacks; v_opp public.lead_routing_opportunities; v_event public.lead_routing_events;
BEGIN
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts WHERE provider_message_id=p_provider_message_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO v_cb FROM public.lead_routing_delivery_callbacks
  WHERE provider_message_id=p_provider_message_id
  ORDER BY CASE delivery_status WHEN 'delivered' THEN 3 WHEN 'failed' THEN 2 WHEN 'sent' THEN 1 END DESC,
           received_at DESC, callback_id DESC
  LIMIT 1;
  IF NOT FOUND OR v_cb.delivery_status='sent' THEN RETURN NULL; END IF;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities WHERE opportunity_id=v_attempt.opportunity_id FOR UPDATE;
  IF v_opp.current_delivery_attempt_id IS DISTINCT FROM v_attempt.attempt_id OR v_opp.routing_tier IS DISTINCT FROM v_attempt.routing_tier OR v_opp.state IN ('assigned','unassigned_alerted','closed_won','closed_lost') THEN RETURN v_opp; END IF;
  IF v_cb.delivery_status='delivered' THEN
    INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,external_evidence) VALUES(v_attempt.opportunity_id,'delivery_confirmed',v_attempt.routing_tier,'delivery:'||p_provider_message_id||':delivered',v_cb.evidence) ON CONFLICT(idempotency_key) DO NOTHING;
    SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key='delivery:'||p_provider_message_id||':delivered';
    IF v_event.opportunity_id IS DISTINCT FROM v_attempt.opportunity_id OR v_event.event_type<>'delivery_confirmed' OR v_event.routing_tier IS DISTINCT FROM v_attempt.routing_tier THEN RAISE EXCEPTION 'delivery event collision'; END IF;
    UPDATE public.lead_routing_delivery_attempts SET status='delivered',delivered_at=COALESCE(delivered_at,v_cb.received_at) WHERE attempt_id=v_attempt.attempt_id AND status<>'delivered';
    UPDATE public.lead_routing_opportunities SET state=CASE v_attempt.routing_tier WHEN 'owner' THEN 'owner_open' WHEN 'primary_guard' THEN 'primary_guard_open' ELSE 'backup_guard_open' END,delivery_status='delivered',delivered_at=COALESCE(delivered_at,v_cb.received_at),expires_at=COALESCE(expires_at,v_cb.received_at+INTERVAL '5 minutes'),updated_at=NOW() WHERE opportunity_id=v_attempt.opportunity_id AND delivered_at IS NULL;
  ELSIF v_attempt.status<>'delivered' AND v_opp.delivered_at IS NULL THEN
    INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,external_evidence) VALUES(v_attempt.opportunity_id,'delivery_failed',v_attempt.routing_tier,'delivery:'||p_provider_message_id||':failed',v_cb.evidence) ON CONFLICT(idempotency_key) DO NOTHING;
    SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key='delivery:'||p_provider_message_id||':failed';
    IF v_event.opportunity_id IS DISTINCT FROM v_attempt.opportunity_id OR v_event.event_type<>'delivery_failed' OR v_event.routing_tier IS DISTINCT FROM v_attempt.routing_tier THEN RAISE EXCEPTION 'delivery failure event collision'; END IF;
    UPDATE public.lead_routing_delivery_attempts SET status='failed',failed_at=COALESCE(failed_at,v_cb.received_at) WHERE attempt_id=v_attempt.attempt_id;
    UPDATE public.lead_routing_opportunities SET delivery_status='failed',expires_at=NULL,updated_at=NOW() WHERE opportunity_id=v_attempt.opportunity_id AND delivered_at IS NULL;
    PERFORM public.fallback_failed_owner_delivery(v_attempt.attempt_id,'provider_delivery_failed');
  END IF;
  UPDATE public.lead_routing_delivery_callbacks SET reconciled_at=NOW() WHERE provider_message_id=p_provider_message_id AND reconciled_at IS NULL;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities WHERE opportunity_id=v_attempt.opportunity_id; RETURN v_opp;
END; $$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

CREATE OR REPLACE FUNCTION public.fallback_failed_owner_delivery(p_attempt_id BIGINT,p_reason TEXT)
RETURNS public.lead_routing_opportunities AS $$
DECLARE v_attempt public.lead_routing_delivery_attempts; v_coverage RECORD; v_opp public.lead_routing_opportunities; v_tier TEXT; v_state TEXT; v_event public.lead_routing_events; v_key TEXT; v_meta JSONB;
BEGIN
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts WHERE attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities WHERE opportunity_id=v_attempt.opportunity_id FOR UPDATE;
  IF v_opp.current_delivery_attempt_id IS DISTINCT FROM p_attempt_id OR v_opp.delivered_at IS NOT NULL THEN RETURN v_opp; END IF;
  v_tier:=CASE v_attempt.routing_tier WHEN 'owner' THEN 'primary_guard' WHEN 'primary_guard' THEN 'backup_guard' ELSE NULL END;
  SELECT * INTO v_coverage FROM public.get_guard_coverage_slots() c WHERE c.coverage_role=CASE v_tier WHEN 'primary_guard' THEN 'primary' WHEN 'backup_guard' THEN 'backup' END LIMIT 1;
  IF v_coverage.agent_id IS NULL AND v_attempt.routing_tier='owner' THEN
    v_tier:='backup_guard';
    SELECT * INTO v_coverage FROM public.get_guard_coverage_slots() c WHERE c.coverage_role='backup' LIMIT 1;
  END IF;
  IF v_coverage.agent_id IS NULL THEN v_tier:=NULL; END IF;
  v_state:=CASE WHEN v_tier IS NULL THEN 'unassigned_alerted' ELSE 'guard_delivery_pending' END;
  v_key:='delivery-fallback:'||p_attempt_id::text; v_meta:=jsonb_strip_nulls(jsonb_build_object('reason',left(COALESCE(p_reason,'delivery_failed'),120),'agent_id',v_coverage.agent_id));
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,metadata) VALUES(v_attempt.opportunity_id,CASE WHEN v_tier IS NULL THEN 'unassigned_alerted' ELSE 'escalated' END,v_tier,v_key,v_meta) ON CONFLICT(idempotency_key) DO NOTHING;
  SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key=v_key;
  IF v_event.opportunity_id IS DISTINCT FROM v_attempt.opportunity_id OR v_event.event_type IS DISTINCT FROM (CASE WHEN v_tier IS NULL THEN 'unassigned_alerted' ELSE 'escalated' END) OR v_event.routing_tier IS DISTINCT FROM v_tier OR v_event.metadata IS DISTINCT FROM v_meta THEN RAISE EXCEPTION 'delivery fallback event collision'; END IF;
  UPDATE public.lead_routing_delivery_attempts SET status='failed',failed_at=COALESCE(failed_at,NOW()) WHERE attempt_id=p_attempt_id AND status<>'delivered';
  UPDATE public.lead_routing_opportunities SET state=v_state,routing_tier=v_tier,current_delivery_attempt_id=NULL,delivery_status='failed',delivered_at=NULL,expires_at=NULL,updated_at=NOW() WHERE opportunity_id=v_attempt.opportunity_id RETURNING * INTO v_opp;
  RETURN v_opp;
END; $$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

CREATE OR REPLACE FUNCTION public.sweep_owner_delivery_no_callback(p_timeout INTERVAL DEFAULT INTERVAL '2 minutes',p_limit INTEGER DEFAULT 100)
RETURNS SETOF public.lead_routing_opportunities AS $$
DECLARE v_attempt public.lead_routing_delivery_attempts;
BEGIN
  FOR v_attempt IN
    SELECT a.*
    FROM public.lead_routing_delivery_attempts a
    JOIN public.lead_routing_opportunities o ON o.opportunity_id=a.opportunity_id
    WHERE (
      (a.status='sent' AND a.bound_at IS NOT NULL AND a.bound_at<=NOW()-p_timeout)
      OR (a.status='requested' AND a.provider_message_id IS NULL AND a.lease_expires_at IS NOT NULL AND a.lease_expires_at<=NOW())
    )
      AND o.current_delivery_attempt_id=a.attempt_id
      AND o.delivered_at IS NULL
    ORDER BY COALESCE(a.bound_at,a.lease_expires_at,a.claimed_at),a.attempt_id
    FOR UPDATE OF a SKIP LOCKED
    LIMIT p_limit
  LOOP
    RETURN NEXT public.fallback_failed_owner_delivery(v_attempt.attempt_id,CASE WHEN v_attempt.status='requested' THEN 'delivery_send_lease_timeout' ELSE 'delivery_callback_timeout' END);
  END LOOP;
END; $$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

DROP FUNCTION IF EXISTS public.claim_pending_guard_deliveries(INTEGER);
CREATE OR REPLACE FUNCTION public.claim_pending_guard_deliveries(p_limit INTEGER DEFAULT 100)
RETURNS SETOF public.lead_routing_delivery_attempts AS $$
DECLARE v_opp public.lead_routing_opportunities; v_coverage RECORD; v_attempt public.lead_routing_delivery_attempts; v_key TEXT; v_event public.lead_routing_events; v_tier TEXT; v_meta JSONB;
BEGIN
  FOR v_opp IN SELECT * FROM public.lead_routing_opportunities WHERE state='guard_delivery_pending' AND current_delivery_attempt_id IS NULL ORDER BY updated_at,opportunity_id FOR UPDATE SKIP LOCKED LIMIT p_limit LOOP
    v_tier:=v_opp.routing_tier;
    SELECT * INTO v_coverage FROM public.get_guard_coverage_slots() c WHERE c.coverage_role=CASE v_tier WHEN 'primary_guard' THEN 'primary' WHEN 'backup_guard' THEN 'backup' END LIMIT 1;
    IF v_coverage.agent_id IS NULL AND v_tier='primary_guard' THEN
      v_tier:='backup_guard';
      SELECT * INTO v_coverage FROM public.get_guard_coverage_slots() c WHERE c.coverage_role='backup' LIMIT 1;
    END IF;
    IF v_coverage.agent_id IS NULL THEN
      v_key:='guard-coverage-unavailable:'||v_opp.opportunity_id::text||':'||v_opp.routing_tier;
      v_meta:=jsonb_build_object('reason','guard_coverage_unavailable');
      INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,metadata) VALUES(v_opp.opportunity_id,'unassigned_alerted',NULL,v_key,v_meta) ON CONFLICT(idempotency_key) DO NOTHING;
      SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key=v_key;
      IF v_event.opportunity_id IS DISTINCT FROM v_opp.opportunity_id OR v_event.event_type<>'unassigned_alerted' OR v_event.routing_tier IS NOT NULL OR v_event.metadata IS DISTINCT FROM v_meta THEN RAISE EXCEPTION 'guard coverage event collision'; END IF;
      UPDATE public.lead_routing_opportunities SET state='unassigned_alerted',routing_tier=NULL,delivery_status='failed',current_delivery_attempt_id=NULL,expires_at=NULL,updated_at=NOW() WHERE opportunity_id=v_opp.opportunity_id;
      CONTINUE;
    END IF;
    v_key:='guard-offer:'||v_opp.opportunity_id::text||':'||v_tier;
    v_meta:=jsonb_build_object('client_request_id',v_key,'agent_id',v_coverage.agent_id);
    INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,metadata) VALUES(v_opp.opportunity_id,'delivery_requested',v_tier,'delivery-requested:'||v_key,v_meta) ON CONFLICT(idempotency_key) DO NOTHING;
    SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key='delivery-requested:'||v_key;
    IF v_event.opportunity_id IS DISTINCT FROM v_opp.opportunity_id OR v_event.event_type<>'delivery_requested' OR v_event.routing_tier IS DISTINCT FROM v_tier OR v_event.metadata IS DISTINCT FROM v_meta THEN RAISE EXCEPTION 'guard delivery event collision'; END IF;
    INSERT INTO public.lead_routing_delivery_attempts(opportunity_id,routing_tier,client_request_id,target_agent_id,target_number,claimed_at,lease_expires_at,lease_token)
    VALUES(v_opp.opportunity_id,v_tier,v_key,v_coverage.agent_id,v_coverage.whatsapp_number,NOW(),NOW()+INTERVAL '2 minutes',gen_random_uuid()::text) ON CONFLICT(client_request_id) DO NOTHING RETURNING * INTO v_attempt;
    IF NOT FOUND THEN
      SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts WHERE client_request_id=v_key FOR UPDATE;
      IF v_attempt.opportunity_id IS DISTINCT FROM v_opp.opportunity_id OR v_attempt.routing_tier IS DISTINCT FROM v_tier OR v_attempt.target_agent_id IS DISTINCT FROM v_coverage.agent_id OR v_attempt.target_number IS DISTINCT FROM v_coverage.whatsapp_number THEN RAISE EXCEPTION 'guard delivery request collision'; END IF;
      IF v_attempt.status='requested' AND v_attempt.lease_expires_at<=NOW() THEN
        UPDATE public.lead_routing_delivery_attempts SET claimed_at=NOW(),lease_expires_at=NOW()+INTERVAL '2 minutes',lease_token=gen_random_uuid()::text WHERE attempt_id=v_attempt.attempt_id RETURNING * INTO v_attempt;
      ELSE
        CONTINUE;
      END IF;
    END IF;
    UPDATE public.lead_routing_opportunities SET state='delivery_requested',routing_tier=v_tier,delivery_status='requested',delivery_requested_at=NOW(),current_delivery_attempt_id=v_attempt.attempt_id,updated_at=NOW() WHERE opportunity_id=v_opp.opportunity_id AND state='guard_delivery_pending' AND current_delivery_attempt_id IS NULL;
    IF FOUND THEN RETURN NEXT v_attempt; END IF;
  END LOOP;
END; $$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

CREATE OR REPLACE FUNCTION public.purge_delivery_callback_evidence(p_before TIMESTAMPTZ DEFAULT NOW()-INTERVAL '30 days') RETURNS BIGINT AS $$
DECLARE v_count BIGINT;
BEGIN
  DELETE FROM public.lead_routing_delivery_callbacks WHERE received_at<p_before;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  UPDATE public.lead_routing_delivery_attempts SET target_number=NULL
  WHERE target_number IS NOT NULL AND COALESCE(delivered_at,failed_at,bound_at,requested_at,created_at)<p_before;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

DROP FUNCTION IF EXISTS public.bind_delivery_message(BIGINT,TEXT);
CREATE OR REPLACE FUNCTION public.bind_delivery_message(p_attempt_id BIGINT,p_provider_message_id TEXT,p_lease_token TEXT)
RETURNS public.lead_routing_opportunities AS $$
DECLARE v_attempt public.lead_routing_delivery_attempts; v_event public.lead_routing_events;
BEGIN
  IF NULLIF(btrim(p_provider_message_id),'') IS NULL THEN RAISE EXCEPTION 'provider_message_id required'; END IF;
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts WHERE attempt_id=p_attempt_id FOR UPDATE;
  IF NOT FOUND OR v_attempt.lease_token IS DISTINCT FROM p_lease_token OR v_attempt.lease_expires_at<=NOW() THEN RAISE EXCEPTION 'delivery attempt lease invalid'; END IF;
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,external_evidence) VALUES(v_attempt.opportunity_id,'delivery_bound',v_attempt.routing_tier,'delivery-bound:'||p_provider_message_id,jsonb_build_object('provider_message_id',p_provider_message_id)) ON CONFLICT(idempotency_key) DO NOTHING;
  SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key='delivery-bound:'||p_provider_message_id;
  IF v_event.opportunity_id IS DISTINCT FROM v_attempt.opportunity_id OR v_event.event_type<>'delivery_bound' OR v_event.routing_tier IS DISTINCT FROM v_attempt.routing_tier THEN RAISE EXCEPTION 'delivery binding event collision'; END IF;
  UPDATE public.lead_routing_delivery_attempts SET provider_message_id=p_provider_message_id,status=CASE WHEN status='requested' THEN 'sent' ELSE status END,bound_at=COALESCE(bound_at,NOW()) WHERE attempt_id=p_attempt_id AND (provider_message_id IS NULL OR provider_message_id=p_provider_message_id) RETURNING * INTO v_attempt;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery attempt cannot bind message'; END IF;
  RETURN public.reconcile_delivery_callback(p_provider_message_id);
END; $$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

CREATE OR REPLACE FUNCTION public.record_delivery_callback(p_provider_message_id TEXT,p_status TEXT,p_provider_timestamp TIMESTAMPTZ,p_evidence JSONB)
RETURNS public.lead_routing_opportunities AS $$
BEGIN
  IF NULLIF(btrim(p_provider_message_id),'') IS NULL OR p_status NOT IN ('sent','delivered','failed') THEN RAISE EXCEPTION 'invalid delivery callback'; END IF;
  INSERT INTO public.lead_routing_delivery_callbacks(provider_message_id,delivery_status,provider_timestamp,evidence)
  VALUES(p_provider_message_id,p_status,p_provider_timestamp,COALESCE(p_evidence,'{}'::jsonb)) ON CONFLICT(provider_message_id,delivery_status) DO NOTHING;
  RETURN public.reconcile_delivery_callback(p_provider_message_id);
END; $$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

DROP FUNCTION IF EXISTS public.fail_unbound_delivery_attempt(BIGINT,TEXT);
CREATE OR REPLACE FUNCTION public.fail_unbound_delivery_attempt(p_attempt_id BIGINT,p_reason TEXT,p_lease_token TEXT)
RETURNS public.lead_routing_opportunities AS $$
DECLARE v_attempt public.lead_routing_delivery_attempts; v_opp public.lead_routing_opportunities; v_event public.lead_routing_events; v_meta JSONB; v_key TEXT;
BEGIN
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts WHERE attempt_id=p_attempt_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery attempt lease invalid'; END IF;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities WHERE opportunity_id=v_attempt.opportunity_id FOR UPDATE;
  IF v_attempt.status<>'requested' OR v_attempt.provider_message_id IS NOT NULL THEN RETURN v_opp; END IF;
  IF v_attempt.lease_token IS DISTINCT FROM p_lease_token OR v_attempt.lease_expires_at<=NOW() OR v_opp.current_delivery_attempt_id IS DISTINCT FROM v_attempt.attempt_id THEN RAISE EXCEPTION 'delivery attempt lease invalid'; END IF;
  v_key:='delivery-unbound:'||v_attempt.attempt_id::text; v_meta:=jsonb_build_object('reason',left(COALESCE(p_reason,'send_failed'),120));
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,external_evidence)
  VALUES(v_attempt.opportunity_id,'delivery_failed',v_attempt.routing_tier,v_key,v_meta) ON CONFLICT(idempotency_key) DO NOTHING;
  SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key=v_key;
  IF v_event.opportunity_id IS DISTINCT FROM v_attempt.opportunity_id OR v_event.event_type<>'delivery_failed' OR v_event.routing_tier IS DISTINCT FROM v_attempt.routing_tier OR v_event.external_evidence IS DISTINCT FROM v_meta THEN RAISE EXCEPTION 'unbound failure event collision'; END IF;
  UPDATE public.lead_routing_delivery_attempts SET status='failed',failed_at=COALESCE(failed_at,NOW()) WHERE attempt_id=p_attempt_id AND provider_message_id IS NULL AND status='requested' AND lease_token=p_lease_token AND lease_expires_at>NOW() RETURNING * INTO v_attempt;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery attempt lease invalid'; END IF;
  PERFORM public.fallback_failed_owner_delivery(v_attempt.attempt_id,p_reason);
  SELECT * INTO v_opp FROM public.lead_routing_opportunities WHERE opportunity_id=v_attempt.opportunity_id; RETURN v_opp;
END; $$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

REVOKE ALL ON FUNCTION public.create_delivery_attempt(BIGINT,TEXT,TEXT,TEXT,TEXT), public.bind_delivery_message(BIGINT,TEXT,TEXT), public.record_delivery_callback(TEXT,TEXT,TIMESTAMPTZ,JSONB), public.reconcile_delivery_callback(TEXT), public.fail_unbound_delivery_attempt(BIGINT,TEXT,TEXT), public.purge_delivery_callback_evidence(TIMESTAMPTZ), public.fallback_failed_owner_delivery(BIGINT,TEXT), public.sweep_owner_delivery_no_callback(INTERVAL,INTEGER), public.claim_pending_guard_deliveries(INTEGER) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_delivery_attempt(BIGINT,TEXT,TEXT,TEXT,TEXT), public.bind_delivery_message(BIGINT,TEXT,TEXT), public.record_delivery_callback(TEXT,TEXT,TIMESTAMPTZ,JSONB), public.reconcile_delivery_callback(TEXT), public.fail_unbound_delivery_attempt(BIGINT,TEXT,TEXT), public.purge_delivery_callback_evidence(TIMESTAMPTZ), public.fallback_failed_owner_delivery(BIGINT,TEXT), public.sweep_owner_delivery_no_callback(INTERVAL,INTEGER), public.claim_pending_guard_deliveries(INTEGER) TO service_role;
REVOKE ALL ON FUNCTION public.mark_offer_delivered(BIGINT,TEXT,JSONB), public.mark_offer_delivery_failed(BIGINT,TEXT,JSONB) FROM service_role;
