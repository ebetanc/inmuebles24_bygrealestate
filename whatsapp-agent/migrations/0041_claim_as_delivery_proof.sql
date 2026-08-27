-- A signed, authenticated claim click is conclusive human delivery proof when
-- Meta accepted the wamid but the delivery callback was unavailable.
-- Rollback: DROP FUNCTION public.recover_delivery_from_authenticated_claim(bigint,text,text,text);

CREATE OR REPLACE FUNCTION public.recover_delivery_from_authenticated_claim(
  p_opportunity_id BIGINT,
  p_tier TEXT,
  p_agent_id TEXT,
  p_actor_phone_hash TEXT
) RETURNS BOOLEAN AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_attempt public.lead_routing_delivery_attempts;
  v_fallback public.lead_routing_events;
  v_event public.lead_routing_events;
  v_expected_hash TEXT;
  v_key TEXT;
  v_meta JSONB;
BEGIN
  IF p_tier NOT IN ('owner','primary_guard','backup_guard')
     OR NULLIF(btrim(p_agent_id),'') IS NULL
     OR p_actor_phone_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid delivery recovery claim';
  END IF;
  SELECT encode(extensions.digest(a.whatsapp_number,'sha256'),'hex')
  INTO v_expected_hash
  FROM public.agents a
  WHERE a.agent_id=p_agent_id AND a.is_available
    AND NULLIF(btrim(a.whatsapp_number),'') IS NOT NULL;
  IF v_expected_hash IS DISTINCT FROM p_actor_phone_hash THEN
    RAISE EXCEPTION 'claim actor authentication failed';
  END IF;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR v_opp.assigned_agent_id IS NOT NULL
     OR v_opp.state<>'unassigned_alerted' OR v_opp.current_delivery_attempt_id IS NOT NULL THEN
    RETURN FALSE;
  END IF;
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts
  WHERE opportunity_id=p_opportunity_id
  ORDER BY attempt_id DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR v_attempt.routing_tier IS DISTINCT FROM p_tier
     OR v_attempt.target_agent_id IS DISTINCT FROM p_agent_id
     OR v_attempt.status<>'failed' OR v_attempt.provider_message_id IS NULL THEN
    RETURN FALSE;
  END IF;
  SELECT * INTO v_fallback FROM public.lead_routing_events
  WHERE idempotency_key='delivery-fallback:'||v_attempt.attempt_id::text;
  IF NOT FOUND OR v_fallback.opportunity_id IS DISTINCT FROM p_opportunity_id
     OR v_fallback.event_type<>'unassigned_alerted'
     OR v_fallback.metadata->>'reason'<>'delivery_callback_timeout' THEN
    RETURN FALSE;
  END IF;
  v_key:='delivery-confirmed-by-claim:'||v_attempt.attempt_id::text;
  v_meta:=jsonb_build_object('proof','signed_authenticated_claim','attempt_id',v_attempt.attempt_id);
  INSERT INTO public.lead_routing_events(
    opportunity_id,event_type,routing_tier,actor_id,idempotency_key,external_evidence,metadata
  ) VALUES(
    p_opportunity_id,'delivery_confirmed_by_claim',p_tier,p_agent_id,v_key,
    jsonb_build_object('provider_message_id',v_attempt.provider_message_id),v_meta
  ) ON CONFLICT(idempotency_key) DO NOTHING;
  SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key=v_key;
  IF v_event.opportunity_id IS DISTINCT FROM p_opportunity_id
     OR v_event.event_type<>'delivery_confirmed_by_claim'
     OR v_event.routing_tier IS DISTINCT FROM p_tier
     OR v_event.actor_id IS DISTINCT FROM p_agent_id
     OR v_event.metadata IS DISTINCT FROM v_meta THEN
    RAISE EXCEPTION 'delivery recovery event collision';
  END IF;
  UPDATE public.lead_routing_delivery_attempts
  SET status='delivered',delivered_at=COALESCE(delivered_at,NOW()),failed_at=NULL
  WHERE attempt_id=v_attempt.attempt_id;
  UPDATE public.lead_routing_opportunities
  SET state=CASE p_tier
        WHEN 'owner' THEN 'owner_open'
        WHEN 'primary_guard' THEN 'primary_guard_open'
        ELSE 'backup_guard_open'
      END,
      routing_tier=p_tier,delivery_status='delivered',
      current_delivery_attempt_id=v_attempt.attempt_id,
      delivered_at=COALESCE(delivered_at,NOW()),expires_at=NOW()+INTERVAL '5 minutes',
      updated_at=NOW()
  WHERE opportunity_id=p_opportunity_id;
  RETURN TRUE;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path=pg_catalog,public,extensions;

REVOKE ALL ON FUNCTION public.recover_delivery_from_authenticated_claim(bigint,text,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recover_delivery_from_authenticated_claim(bigint,text,text,text)
  TO service_role;
