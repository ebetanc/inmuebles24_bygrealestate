-- LRV2-011: durable, exclusive lease for the Inmuebles24 Contactado effect.
CREATE TABLE IF NOT EXISTS public.lead_routing_i24_contact_effects (
  opportunity_id BIGINT PRIMARY KEY REFERENCES public.lead_routing_opportunities(opportunity_id),
  assigned_agent_id TEXT NOT NULL,
  i24_lead_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','leased','failed','succeeded')),
  lease_token UUID,
  lease_expires_at TIMESTAMPTZ,
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error_code TEXT,
  screenshot_path TEXT,
  completed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS lead_routing_i24_contact_effects_claimable_idx
  ON public.lead_routing_i24_contact_effects(status, lease_expires_at, opportunity_id);

ALTER TABLE public.lead_routing_i24_contact_effects ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lead_routing_i24_contact_effects FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.lead_routing_i24_contact_effects TO service_role;

CREATE OR REPLACE FUNCTION public.claim_i24_contact_effects(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE(opportunity_id BIGINT, i24_lead_id TEXT, assigned_agent_id TEXT, lease_token UUID) AS $$
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid i24 contact claim input';
  END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT o.opportunity_id, o.assigned_agent_id, c.i24_lead_id
    FROM public.lead_routing_opportunities o
    JOIN public.conversations c ON c.conversation_id=o.conversation_id
    LEFT JOIN public.lead_routing_i24_contact_effects e ON e.opportunity_id=o.opportunity_id
    WHERE o.state='assigned'
      AND o.assigned_agent_id IS NOT NULL
      AND c.source='inmuebles24'
      AND c.i24_lead_id IS NOT NULL
      AND c.assigned_agent_id=o.assigned_agent_id
      AND NOT EXISTS (
        SELECT 1 FROM public.lead_routing_events done
        WHERE done.opportunity_id=o.opportunity_id AND done.event_type='i24_contacted'
      )
      AND (e.opportunity_id IS NULL OR e.status IN ('pending','failed')
           OR (e.status='leased' AND e.lease_expires_at<=p_now))
    ORDER BY o.assigned_at, o.opportunity_id
    FOR UPDATE OF o, c SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    INSERT INTO public.lead_routing_i24_contact_effects AS e(
      opportunity_id, assigned_agent_id, i24_lead_id, status, lease_token,
      lease_expires_at, attempts, updated_at
    )
    SELECT candidate.opportunity_id, candidate.assigned_agent_id, candidate.i24_lead_id,
      'leased', gen_random_uuid(),
      p_now + INTERVAL '2 minutes', 1, p_now
    FROM candidates AS candidate
    ON CONFLICT ON CONSTRAINT lead_routing_i24_contact_effects_pkey DO UPDATE
      SET assigned_agent_id=EXCLUDED.assigned_agent_id,
          i24_lead_id=EXCLUDED.i24_lead_id,
          status='leased', lease_token=gen_random_uuid(),
          lease_expires_at=p_now + INTERVAL '2 minutes',
          attempts=e.attempts+1, updated_at=p_now
      WHERE e.status IN ('pending','failed')
         OR (e.status='leased' AND e.lease_expires_at<=p_now)
    RETURNING e.opportunity_id, e.i24_lead_id, e.assigned_agent_id, e.lease_token
  ), evidenced AS (
    INSERT INTO public.lead_routing_events(
      opportunity_id, event_type, actor_id, idempotency_key, external_evidence
    )
    SELECT claimed_effect.opportunity_id, 'i24_contact_claimed', claimed_effect.assigned_agent_id,
      'i24-contact-claim:'||claimed_effect.lease_token::text,
      jsonb_build_object('portal','inmuebles24','status','leased')
    FROM claimed AS claimed_effect
    ON CONFLICT(idempotency_key) DO NOTHING
    RETURNING idempotency_key
  )
  SELECT c.opportunity_id, c.i24_lead_id, c.assigned_agent_id, c.lease_token
  FROM claimed c
  JOIN evidenced e ON e.idempotency_key='i24-contact-claim:'||c.lease_token::text;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

CREATE OR REPLACE FUNCTION public.validate_i24_contact_effect(
  p_opportunity_id BIGINT,
  p_lease_token UUID
)
RETURNS BOOLEAN AS $$
BEGIN
  IF p_opportunity_id IS NULL OR p_lease_token IS NULL THEN RETURN FALSE; END IF;
  PERFORM 1
    FROM public.lead_routing_i24_contact_effects effect
    JOIN public.lead_routing_opportunities opportunity
      ON opportunity.opportunity_id=effect.opportunity_id
    JOIN public.conversations conversation
      ON conversation.conversation_id=opportunity.conversation_id
    WHERE effect.opportunity_id=p_opportunity_id
      AND effect.status='leased'
      AND effect.lease_token=p_lease_token
      AND effect.lease_expires_at>NOW()
      AND opportunity.state='assigned'
      AND opportunity.assigned_agent_id=effect.assigned_agent_id
      AND conversation.assigned_agent_id=effect.assigned_agent_id
      AND conversation.source='inmuebles24'
      AND conversation.i24_lead_id=effect.i24_lead_id
    FOR SHARE OF opportunity, conversation;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

CREATE OR REPLACE FUNCTION public.finish_i24_contact_effect(
  p_opportunity_id BIGINT,
  p_lease_token UUID,
  p_success BOOLEAN,
  p_error_code TEXT DEFAULT NULL,
  p_screenshot_path TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
  v_effect public.lead_routing_i24_contact_effects;
  v_event public.lead_routing_events;
  v_status TEXT;
  v_key TEXT;
  v_evidence JSONB;
  v_effective_success BOOLEAN;
  v_effective_error TEXT;
BEGIN
  IF p_opportunity_id IS NULL OR p_lease_token IS NULL OR p_success IS NULL
     OR length(COALESCE(p_error_code,''))>120 OR length(COALESCE(p_screenshot_path,''))>300 THEN
    RAISE EXCEPTION 'invalid i24 contact completion input';
  END IF;

  SELECT * INTO v_effect
  FROM public.lead_routing_i24_contact_effects
  WHERE opportunity_id=p_opportunity_id
  FOR UPDATE;
  IF NOT FOUND OR v_effect.status<>'leased' OR v_effect.lease_token IS DISTINCT FROM p_lease_token
     OR v_effect.lease_expires_at<=NOW() THEN
    RETURN FALSE;
  END IF;

  v_effective_success:=p_success AND public.validate_i24_contact_effect(p_opportunity_id,p_lease_token);
  v_effective_error:=CASE
    WHEN p_success AND NOT v_effective_success THEN 'assignment_changed_before_completion'
    ELSE p_error_code
  END;
  v_status:=CASE WHEN v_effective_success THEN 'success' ELSE 'error' END;
  v_key:=CASE WHEN v_effective_success THEN 'i24_contacted:'||p_opportunity_id::text
              ELSE 'i24_contact_failed:'||p_opportunity_id::text||':'||p_lease_token::text END;
  v_evidence:=jsonb_strip_nulls(jsonb_build_object(
    'portal','inmuebles24','status',v_status,
    'error_code',NULLIF(btrim(v_effective_error),''),
    'screenshot_path',NULLIF(btrim(p_screenshot_path),'')
  ));
  INSERT INTO public.lead_routing_events(
    opportunity_id, event_type, actor_id, idempotency_key, external_evidence
  ) VALUES(
    p_opportunity_id, CASE WHEN v_effective_success THEN 'i24_contacted' ELSE 'i24_contact_attempt' END,
    v_effect.assigned_agent_id, v_key, v_evidence
  ) ON CONFLICT(idempotency_key) DO NOTHING;
  SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key=v_key;
  IF v_event.opportunity_id IS DISTINCT FROM p_opportunity_id
     OR v_event.event_type IS DISTINCT FROM (CASE WHEN v_effective_success THEN 'i24_contacted' ELSE 'i24_contact_attempt' END)
     OR v_event.external_evidence IS DISTINCT FROM v_evidence THEN
    RAISE EXCEPTION 'i24 contact event collision';
  END IF;

  UPDATE public.lead_routing_i24_contact_effects
  SET status=CASE WHEN v_effective_success THEN 'succeeded' ELSE 'failed' END,
      lease_token=NULL, lease_expires_at=NULL,
      last_error_code=CASE WHEN v_effective_success THEN NULL ELSE NULLIF(btrim(v_effective_error),'') END,
      screenshot_path=CASE WHEN v_effective_success THEN NULL ELSE NULLIF(btrim(p_screenshot_path),'') END,
      completed_at=CASE WHEN v_effective_success THEN NOW() ELSE NULL END,
      updated_at=NOW()
  WHERE opportunity_id=p_opportunity_id AND lease_token=p_lease_token;
  RETURN FOUND AND v_effective_success=p_success;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

REVOKE ALL ON FUNCTION public.claim_i24_contact_effects(INTEGER,TIMESTAMPTZ),
  public.validate_i24_contact_effect(BIGINT,UUID),
  public.finish_i24_contact_effect(BIGINT,UUID,BOOLEAN,TEXT,TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_i24_contact_effects(INTEGER,TIMESTAMPTZ),
  public.validate_i24_contact_effect(BIGINT,UUID),
  public.finish_i24_contact_effect(BIGINT,UUID,BOOLEAN,TEXT,TEXT)
  TO service_role;
