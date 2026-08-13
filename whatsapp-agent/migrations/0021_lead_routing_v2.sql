-- 0021_lead_routing_v2.sql
-- Estado durable y auditoria para Lead Routing v2. Aditiva; no cambia consumers actuales.
-- Rollback de emergencia (solo runbook aprobado): DROP FUNCTION public.mark_offer_delivery_failed(bigint,text,jsonb);
-- DROP FUNCTION public.mark_offer_delivered(bigint,text,jsonb); DROP TRIGGER lead_routing_events_append_only ON public.lead_routing_events;
-- DROP FUNCTION public.reject_lead_routing_event_mutation(); DROP TABLE public.lead_routing_events;
-- DROP TABLE public.lead_routing_opportunities;

CREATE TABLE IF NOT EXISTS public.lead_routing_opportunities (
  opportunity_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id UUID REFERENCES public.conversations(conversation_id),
  property_id TEXT,
  portal_person_id TEXT,
  normalized_email TEXT,
  e164_phone TEXT,
  identity_key TEXT,
  identity_reason TEXT,
  state TEXT NOT NULL DEFAULT 'captured' CHECK (state IN (
    'captured', 'deduplicated', 'resolved', 'delivery_requested', 'delivered',
    'owner_open', 'primary_guard_open', 'backup_guard_open', 'assigned',
    'unassigned_alerted', 'queued_night', 'manual_non_deduplicable', 'safe_mode',
    'closed_won', 'closed_lost'
  )),
  routing_tier TEXT CHECK (routing_tier IS NULL OR routing_tier IN (
    'owner', 'primary_guard', 'backup_guard'
  )),
  delivery_status TEXT CHECK (delivery_status IS NULL OR delivery_status IN (
    'requested', 'delivered', 'failed'
  )),
  detected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  delivery_requested_at TIMESTAMPTZ,
  delivered_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  accepted_at TIMESTAMPTZ,
  assigned_at TIMESTAMPTZ,
  closed_at TIMESTAMPTZ,
  assigned_agent_id TEXT REFERENCES public.agents(agent_id),
  external_conversation_id TEXT,
  delivery_evidence JSONB,
  external_evidence JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.lead_routing_opportunities IS
  'Routing-v2 source of truth. identity_key is canonical person identity; NULL identity/property cannot be safely deduplicated.';
COMMENT ON COLUMN public.lead_routing_opportunities.identity_key IS
  'Canonical priority selected by intake: portal_person_id, normalized email, then E.164 phone.';

CREATE UNIQUE INDEX IF NOT EXISTS lead_routing_opportunities_active_identity_uniq
  ON public.lead_routing_opportunities (identity_key, property_id)
  WHERE state NOT IN ('closed_won', 'closed_lost')
    AND identity_key IS NOT NULL
    AND property_id IS NOT NULL
;

CREATE INDEX IF NOT EXISTS lead_routing_opportunities_conversation_idx
  ON public.lead_routing_opportunities (conversation_id)
  WHERE conversation_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.lead_routing_events (
  event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  opportunity_id BIGINT NOT NULL REFERENCES public.lead_routing_opportunities(opportunity_id),
  event_type TEXT NOT NULL,
  routing_tier TEXT,
  actor_id TEXT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  idempotency_key TEXT NOT NULL UNIQUE,
  external_evidence JSONB,
  metadata JSONB
);

COMMENT ON TABLE public.lead_routing_events IS
  'Append-only routing transition audit. idempotency_key deduplicates provider and workflow retries.';

CREATE INDEX IF NOT EXISTS lead_routing_events_opportunity_occurred_idx
  ON public.lead_routing_events (opportunity_id, occurred_at DESC);

ALTER TABLE public.lead_routing_opportunities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lead_routing_events ENABLE ROW LEVEL SECURITY;
-- Deliberate default deny: existing n8n server connection uses postgres and bypasses RLS.
-- No anon/authenticated policy or grant is added until a dashboard has an authorized access model.
REVOKE ALL ON TABLE public.lead_routing_opportunities, public.lead_routing_events
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.lead_routing_opportunities, public.lead_routing_events
  FROM service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.lead_routing_opportunities TO service_role;
GRANT SELECT, INSERT ON TABLE public.lead_routing_events TO service_role;

REVOKE ALL ON SEQUENCE public.lead_routing_opportunities_opportunity_id_seq,
  public.lead_routing_events_event_id_seq FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lead_routing_opportunities_opportunity_id_seq,
  public.lead_routing_events_event_id_seq FROM service_role;
GRANT USAGE, SELECT ON SEQUENCE public.lead_routing_opportunities_opportunity_id_seq,
  public.lead_routing_events_event_id_seq TO service_role;

CREATE OR REPLACE FUNCTION public.reject_lead_routing_event_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'lead_routing_events is append-only';
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog;

REVOKE ALL ON FUNCTION public.reject_lead_routing_event_mutation()
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE TRIGGER lead_routing_events_append_only
  BEFORE UPDATE OR DELETE ON public.lead_routing_events
  FOR EACH ROW EXECUTE FUNCTION public.reject_lead_routing_event_mutation();

CREATE OR REPLACE FUNCTION public.mark_offer_delivered(
  p_opportunity_id BIGINT,
  p_idempotency_key TEXT,
  p_delivery_evidence JSONB DEFAULT '{}'::JSONB
) RETURNS public.lead_routing_opportunities AS $$
DECLARE
  v_opportunity public.lead_routing_opportunities;
  v_event_id BIGINT;
  v_existing_opportunity_id BIGINT;
  v_existing_event_type TEXT;
BEGIN
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
    RAISE EXCEPTION 'idempotency_key must not be blank';
  END IF;

  INSERT INTO public.lead_routing_events (
    opportunity_id, event_type, routing_tier, idempotency_key, external_evidence
  ) VALUES (
    p_opportunity_id, 'delivery_confirmed', 'owner', p_idempotency_key,
    COALESCE(p_delivery_evidence, '{}'::JSONB)
  ) ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING event_id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT opportunity_id, event_type
      INTO v_existing_opportunity_id, v_existing_event_type
      FROM public.lead_routing_events
     WHERE idempotency_key = p_idempotency_key;

    IF v_existing_opportunity_id IS DISTINCT FROM p_opportunity_id
       OR v_existing_event_type IS DISTINCT FROM 'delivery_confirmed' THEN
      RAISE EXCEPTION 'idempotency_key already belongs to another routing event';
    END IF;

    SELECT * INTO v_opportunity
      FROM public.lead_routing_opportunities
     WHERE opportunity_id = p_opportunity_id;
    RETURN v_opportunity;
  END IF;

  UPDATE public.lead_routing_opportunities
     SET state = 'owner_open',
         routing_tier = 'owner',
         delivery_status = 'delivered',
         delivered_at = COALESCE(delivered_at, NOW()),
         expires_at = COALESCE(
           delivered_at + INTERVAL '5 minutes', NOW() + INTERVAL '5 minutes'
         ),
         delivery_evidence = COALESCE(p_delivery_evidence, '{}'::JSONB),
         updated_at = NOW()
   WHERE opportunity_id = p_opportunity_id
     AND delivered_at IS NULL
   RETURNING * INTO v_opportunity;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'opportunity cannot accept delivery confirmation: %', p_opportunity_id;
  END IF;

  RETURN v_opportunity;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog;

REVOKE ALL ON FUNCTION public.mark_offer_delivered(BIGINT, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_offer_delivered(BIGINT, TEXT, JSONB) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_offer_delivered(BIGINT, TEXT, JSONB) TO service_role;

CREATE OR REPLACE FUNCTION public.mark_offer_delivery_failed(
  p_opportunity_id BIGINT,
  p_idempotency_key TEXT,
  p_delivery_evidence JSONB DEFAULT '{}'::JSONB
) RETURNS public.lead_routing_opportunities AS $$
DECLARE
  v_opportunity public.lead_routing_opportunities;
  v_event_id BIGINT;
  v_existing_opportunity_id BIGINT;
  v_existing_event_type TEXT;
BEGIN
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
    RAISE EXCEPTION 'idempotency_key must not be blank';
  END IF;

  INSERT INTO public.lead_routing_events (
    opportunity_id, event_type, routing_tier, idempotency_key, external_evidence
  ) VALUES (
    p_opportunity_id, 'delivery_failed', NULL, p_idempotency_key,
    COALESCE(p_delivery_evidence, '{}'::JSONB)
  ) ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING event_id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT opportunity_id, event_type
      INTO v_existing_opportunity_id, v_existing_event_type
      FROM public.lead_routing_events
     WHERE idempotency_key = p_idempotency_key;

    IF v_existing_opportunity_id IS DISTINCT FROM p_opportunity_id
       OR v_existing_event_type IS DISTINCT FROM 'delivery_failed' THEN
      RAISE EXCEPTION 'idempotency_key already belongs to another routing event';
    END IF;

    SELECT * INTO v_opportunity
      FROM public.lead_routing_opportunities
     WHERE opportunity_id = p_opportunity_id;
    RETURN v_opportunity;
  END IF;

  UPDATE public.lead_routing_opportunities
     SET delivery_status = 'failed',
         delivery_evidence = COALESCE(p_delivery_evidence, '{}'::JSONB),
         updated_at = NOW()
   WHERE opportunity_id = p_opportunity_id
     AND delivered_at IS NULL
   RETURNING * INTO v_opportunity;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'opportunity cannot accept delivery failure: %', p_opportunity_id;
  END IF;

  RETURN v_opportunity;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog;

REVOKE ALL ON FUNCTION public.mark_offer_delivery_failed(BIGINT, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_offer_delivery_failed(BIGINT, TEXT, JSONB) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_offer_delivery_failed(BIGINT, TEXT, JSONB) TO service_role;
