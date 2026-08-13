-- LRV2-009: one locked transaction decides and persists routing-v2 claims.
REVOKE ALL ON TABLE public.conversations FROM service_role;
GRANT SELECT,UPDATE ON TABLE public.conversations TO service_role;
REVOKE ALL ON TABLE public.agents FROM service_role;
GRANT SELECT ON TABLE public.agents TO service_role;

CREATE OR REPLACE FUNCTION public.claim_lead_opportunity(
  p_opportunity_id BIGINT,
  p_tier TEXT,
  p_agent_id TEXT,
  p_actor_phone_hash TEXT,
  p_idempotency_key TEXT
)
RETURNS TABLE (
  claim_status TEXT,
  result_opportunity_id BIGINT,
  result_assigned_agent_id TEXT,
  result_routing_tier TEXT
) AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_event public.lead_routing_events;
  v_authorized_agent_id TEXT;
  v_status TEXT;
  v_event_key TEXT;
  v_metadata JSONB;
  v_expected_phone_hash TEXT;
BEGIN
  IF p_tier NOT IN ('owner','primary_guard','backup_guard')
     OR NULLIF(btrim(p_agent_id),'') IS NULL
     OR NULLIF(btrim(p_actor_phone_hash),'') IS NULL
     OR p_actor_phone_hash !~ '^[0-9a-f]{64}$'
     OR NULLIF(btrim(p_idempotency_key),'') IS NULL
     OR length(p_idempotency_key)>200 THEN
    RAISE EXCEPTION 'invalid claim request';
  END IF;

  v_event_key:='claim:'||p_idempotency_key;
  SELECT e.* INTO v_event FROM public.lead_routing_events e WHERE e.idempotency_key=v_event_key;
  IF FOUND THEN
    IF v_event.opportunity_id IS DISTINCT FROM p_opportunity_id
       OR v_event.routing_tier IS DISTINCT FROM p_tier
       OR v_event.actor_id IS DISTINCT FROM p_agent_id
       OR v_event.metadata->>'actor_phone_hash' IS DISTINCT FROM p_actor_phone_hash
       OR jsonb_typeof(v_event.metadata)<>'object'
       OR jsonb_typeof(v_event.metadata->'result') IS DISTINCT FROM 'string'
       OR v_event.metadata - ARRAY['result','actor_phone_hash','assigned_agent_id'] <> '{}'::jsonb
       OR (
         v_event.event_type='claim_accepted'
         AND (v_event.metadata->>'result' IS DISTINCT FROM 'accepted'
              OR v_event.metadata->>'assigned_agent_id' IS DISTINCT FROM p_agent_id)
       )
       OR (
         v_event.event_type='late_claim_rejected'
         AND (NOT COALESCE(v_event.metadata->>'result' IN ('already_assigned','expired','not_authorized','delivery_pending'),false)
              OR (v_event.metadata->>'result'='already_assigned' AND v_event.metadata->>'assigned_agent_id' IS NULL)
              OR (v_event.metadata->>'result'<>'already_assigned' AND v_event.metadata->>'assigned_agent_id' IS NOT NULL))
       )
       OR v_event.event_type NOT IN ('claim_accepted','late_claim_rejected') THEN
      RAISE EXCEPTION 'claim idempotency event collision';
    END IF;
    RETURN QUERY SELECT v_event.metadata->>'result',v_event.opportunity_id,
      NULLIF(v_event.metadata->>'assigned_agent_id',''),v_event.routing_tier;
    RETURN;
  END IF;

  SELECT encode(digest(a.whatsapp_number,'sha256'),'hex') INTO v_expected_phone_hash
  FROM public.agents a
  WHERE a.agent_id=p_agent_id AND a.is_available
    AND NULLIF(btrim(a.whatsapp_number),'') IS NOT NULL;
  IF v_expected_phone_hash IS DISTINCT FROM p_actor_phone_hash THEN
    RAISE EXCEPTION 'claim actor authentication failed';
  END IF;

  SELECT o.* INTO v_opp FROM public.lead_routing_opportunities o
  WHERE o.opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND THEN RETURN QUERY SELECT 'expired'::TEXT,p_opportunity_id,NULL::TEXT,p_tier; RETURN; END IF;

  IF v_opp.assigned_agent_id IS NOT NULL THEN
    v_status:=CASE WHEN v_opp.assigned_agent_id=p_agent_id THEN 'accepted' ELSE 'already_assigned' END;
  ELSIF v_opp.routing_tier IS DISTINCT FROM p_tier THEN v_status:='expired';
  ELSIF v_opp.delivered_at IS NULL THEN v_status:='delivery_pending';
  ELSIF v_opp.state NOT IN ('owner_open','primary_guard_open','backup_guard_open')
        OR v_opp.expires_at IS NULL OR v_opp.expires_at<=NOW() THEN v_status:='expired';
  ELSE
    SELECT a.target_agent_id INTO v_authorized_agent_id
    FROM public.lead_routing_delivery_attempts a
    WHERE a.attempt_id=v_opp.current_delivery_attempt_id
      AND a.opportunity_id=p_opportunity_id AND a.routing_tier=p_tier AND a.status='delivered';
    v_status:=CASE WHEN v_authorized_agent_id=p_agent_id THEN 'accepted' ELSE 'not_authorized' END;
  END IF;

  v_metadata:=jsonb_build_object(
    'result',v_status,'actor_phone_hash',p_actor_phone_hash,
    'assigned_agent_id',CASE WHEN v_status='accepted' THEN p_agent_id ELSE v_opp.assigned_agent_id END
  );
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,actor_id,idempotency_key,metadata)
  VALUES(p_opportunity_id,CASE WHEN v_status='accepted' THEN 'claim_accepted' ELSE 'late_claim_rejected' END,
    p_tier,p_agent_id,v_event_key,v_metadata)
  ON CONFLICT(idempotency_key) DO NOTHING;
  SELECT e.* INTO v_event FROM public.lead_routing_events e WHERE e.idempotency_key=v_event_key;
  IF v_event.opportunity_id IS DISTINCT FROM p_opportunity_id
     OR v_event.event_type IS DISTINCT FROM (CASE WHEN v_status='accepted' THEN 'claim_accepted' ELSE 'late_claim_rejected' END)
     OR v_event.routing_tier IS DISTINCT FROM p_tier OR v_event.actor_id IS DISTINCT FROM p_agent_id
     OR v_event.metadata IS DISTINCT FROM v_metadata THEN RAISE EXCEPTION 'claim event collision'; END IF;

  IF v_status='accepted' AND v_opp.assigned_agent_id IS NULL THEN
    UPDATE public.lead_routing_opportunities
    SET state='assigned',assigned_agent_id=p_agent_id,accepted_at=NOW(),assigned_at=NOW(),updated_at=NOW()
    WHERE opportunity_id=p_opportunity_id AND routing_tier=p_tier
      AND v_authorized_agent_id=p_agent_id AND delivered_at IS NOT NULL
      AND expires_at>NOW() AND assigned_agent_id IS NULL
    RETURNING * INTO v_opp;
    IF NOT FOUND THEN RAISE EXCEPTION 'claim assignment precondition changed'; END IF;

    IF v_opp.conversation_id IS NOT NULL THEN
      UPDATE public.conversations c SET assigned_agent_id=p_agent_id,
        assigned_at=COALESCE(c.assigned_at,NOW()),
        claimed_via=CASE WHEN p_tier='owner' THEN 'owner' ELSE 'tomo_auction' END,mode='ai'
      WHERE c.conversation_id=v_opp.conversation_id
        AND (c.assigned_agent_id IS NULL OR c.assigned_agent_id=p_agent_id);
      IF NOT FOUND THEN RAISE EXCEPTION 'conversation already assigned to another agent'; END IF;
    END IF;
  END IF;

  RETURN QUERY SELECT v_status,v_opp.opportunity_id,v_opp.assigned_agent_id,v_opp.routing_tier;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

REVOKE ALL ON FUNCTION public.claim_lead_opportunity(BIGINT,TEXT,TEXT,TEXT,TEXT)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_lead_opportunity(BIGINT,TEXT,TEXT,TEXT,TEXT)
  TO service_role;
