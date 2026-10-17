-- 2026-10-16 (Marusa): la regla "cliente que regresa en 90 días → misma asesora"
-- (073d543) no debe aplicar a asesores de otras inmobiliarias. Dos marcas:
--   A) la asesora contesta "asesor" por WhatsApp (lead_advisor_flags, 100 % humano);
--   B) heurística: correo de empresa, nombre de inmobiliaria o mensaje de colega.
-- Cualquiera de las dos manda el lead al reparto normal. Nada más cambia.

CREATE TABLE IF NOT EXISTS public.lead_advisor_flags (
  flag_id BIGSERIAL PRIMARY KEY,
  opportunity_id BIGINT NOT NULL UNIQUE REFERENCES public.lead_routing_opportunities(opportunity_id),
  normalized_email TEXT,
  e164_phone TEXT,
  flagged_by_agent_id TEXT NOT NULL REFERENCES public.agents(agent_id),
  webhook_event_id BIGINT,
  flagged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (normalized_email IS NOT NULL OR e164_phone IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS lead_advisor_flags_email_idx
  ON public.lead_advisor_flags(normalized_email) WHERE normalized_email IS NOT NULL;
CREATE INDEX IF NOT EXISTS lead_advisor_flags_phone_idx
  ON public.lead_advisor_flags(e164_phone) WHERE e164_phone IS NOT NULL;
ALTER TABLE public.lead_advisor_flags ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lead_advisor_flags FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.lead_advisor_flags TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.lead_advisor_flags_flag_id_seq TO service_role;

-- B) Heurística. Devuelve 'name' | 'message' | 'email' | NULL. Un falso positivo
-- solo cuesta una subasta normal, así que las listas son cortas y legibles.
CREATE OR REPLACE FUNCTION public.v3_identity_looks_like_advisor(p_email text, p_name text, p_message text)
RETURNS text
LANGUAGE sql IMMUTABLE SET search_path TO 'pg_catalog','public' AS $$
  SELECT CASE
    WHEN COALESCE(p_name,'') ~* '(inmobiliaria|bienes\s*ra[ií]ces|real\s*estate|realty|propiedades|asesor|broker|century\s*21|re/?max|keller|coldwell|sotheby|engel)'
      THEN 'name'
    WHEN COALESCE(p_message,'') ~* '(soy\s+asesor|soy\s+broker|tengo\s+(un|una)\s+client|mi\s+client|colega|inmobiliaria|bolsa\s+inmobiliaria|comparti\w*\s+comisi)'
      THEN 'message'
    WHEN p_email ~ '@'
     AND p_email !~* '@(gmail|googlemail|hotmail|outlook|live|msn|yahoo|ymail|icloud|me|mac|aol|proton|protonmail|prodigy|infinitum|telmex|terra|axtel|att)\.'
      THEN 'email'
    ELSE NULL
  END;
$$;
REVOKE ALL ON FUNCTION public.v3_identity_looks_like_advisor(text, text, text) FROM PUBLIC, anon, authenticated;

-- Por qué una oportunidad cuenta como asesor: 'agent_flag' (A) gana sobre la heurística (B).
CREATE OR REPLACE FUNCTION public.v3_advisor_reason(p_opportunity_id bigint)
RETURNS text
LANGUAGE sql STABLE SET search_path TO 'pg_catalog','public' AS $$
  SELECT COALESCE(
    (SELECT 'agent_flag'
     FROM public.lead_routing_opportunities o
     JOIN public.lead_advisor_flags f
       ON (o.normalized_email IS NOT NULL AND f.normalized_email = o.normalized_email)
       OR (o.e164_phone IS NOT NULL AND f.e164_phone = o.e164_phone)
     WHERE o.opportunity_id = p_opportunity_id
     LIMIT 1),
    (SELECT 'heuristic_' || public.v3_identity_looks_like_advisor(
        o.normalized_email, o.v3_offer_context->>'name', o.v3_offer_context->>'message')
     FROM public.lead_routing_opportunities o
     WHERE o.opportunity_id = p_opportunity_id
       AND public.v3_identity_looks_like_advisor(
        o.normalized_email, o.v3_offer_context->>'name', o.v3_offer_context->>'message') IS NOT NULL));
$$;
REVOKE ALL ON FUNCTION public.v3_advisor_reason(bigint) FROM PUBLIC, anon, authenticated;

-- Misma regla que 20261016200000 más la exclusión de asesores.
CREATE OR REPLACE FUNCTION public.v3_returning_client_agent(p_opportunity_id bigint, p_now timestamptz DEFAULT now())
RETURNS TABLE(agent_id text, whatsapp_number text, previous_opportunity_id bigint)
LANGUAGE sql STABLE SET search_path TO 'pg_catalog','public' AS $$
  SELECT a.agent_id, a.whatsapp_number, prev.opportunity_id
  FROM public.lead_routing_opportunities o
  JOIN public.lead_routing_opportunities prev
    ON prev.v3_enabled AND prev.opportunity_id <> o.opportunity_id
   AND prev.assigned_agent_id IS NOT NULL
   AND prev.assigned_at >= p_now - INTERVAL '90 days' AND prev.assigned_at < p_now
   AND ((o.normalized_email IS NOT NULL AND prev.normalized_email = o.normalized_email)
     OR (o.e164_phone IS NOT NULL AND prev.e164_phone = o.e164_phone))
  JOIN public.agents a ON a.agent_id = prev.assigned_agent_id
   AND a.is_available AND NULLIF(BTRIM(a.whatsapp_number),'') IS NOT NULL
  WHERE o.opportunity_id = p_opportunity_id
    AND COALESCE(o.v3_offer_context->>'portal','') !~* '^\s*mls\s*$'
    AND NOT EXISTS (SELECT 1 FROM public.agents b
      WHERE NULLIF(BTRIM(b.whatsapp_number),'') IS NOT NULL AND o.e164_phone IS NOT NULL
        AND right(regexp_replace(b.whatsapp_number,'\D','','g'),10) = right(regexp_replace(o.e164_phone,'\D','','g'),10))
    AND public.v3_advisor_reason(o.opportunity_id) IS NULL
  ORDER BY prev.assigned_at, prev.opportunity_id
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.v3_returning_client_agent(bigint, timestamptz) FROM PUBLIC, anon, authenticated;

-- A) La asesora contesta "asesor". Si cita (context) la oferta o el aviso del lead,
-- ese lead; si no, su único lead de las últimas 24 h (asignado a ella u ofrecido
-- ahora a ella). Dos o más → ambiguo; cero → sin lead. Mismas validaciones que "tomo".
CREATE OR REPLACE FUNCTION public.v3_flag_advisor_from_webhook(p_webhook_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'pg_catalog','public' AS $$
DECLARE
  v_webhook public.lead_routing_meta_webhook_inbox;
  v_event JSONB;
  v_sender TEXT;
  v_context_wamid TEXT;
  v_agent public.agents;
  v_opp public.lead_routing_opportunities;
  v_ids BIGINT[];
BEGIN
  IF p_webhook_event_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'invalid_webhook_event_id');
  END IF;
  SELECT i.* INTO v_webhook FROM public.lead_routing_meta_webhook_inbox i
  WHERE i.webhook_event_id = p_webhook_event_id;
  IF NOT FOUND OR v_webhook.event_kind IS DISTINCT FROM 'message'
     OR v_webhook.hmac_verified IS DISTINCT FROM TRUE OR v_webhook.created_at IS NULL
     OR jsonb_typeof(v_webhook.sanitized_payload->'event') IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'verified_webhook_not_found');
  END IF;
  v_event := v_webhook.sanitized_payload->'event';
  IF NULLIF(BTRIM(v_event->>'id'),'') IS DISTINCT FROM v_webhook.wamid
     OR v_event->>'type' IS DISTINCT FROM 'text'
     OR COALESCE(v_event #>> '{text,body}','') !~* '^\s*asesor[^[:alnum:]]*$' THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'verified_webhook_mismatch');
  END IF;
  v_sender := REGEXP_REPLACE(COALESCE(v_event->>'from',''), '[ +()-]', '', 'g');
  v_context_wamid := NULLIF(BTRIM(v_event #>> '{context,id}'), '');
  IF v_sender !~ '^[1-9][0-9]{7,14}$' THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender_number');
  END IF;
  SELECT a.* INTO v_agent FROM public.agents a
  WHERE REGEXP_REPLACE(COALESCE(a.whatsapp_number,''), '[ +()-]', '', 'g') = v_sender
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'wrong_sender_number');
  END IF;

  IF v_context_wamid IS NOT NULL THEN
    SELECT array_agg(DISTINCT a.opportunity_id) INTO v_ids
    FROM public.lead_routing_delivery_attempts a
    WHERE a.provider_message_id = v_context_wamid
      AND REGEXP_REPLACE(a.target_number, '[ +()-]', '', 'g') = v_sender;
  END IF;
  IF v_ids IS NULL THEN
    SELECT array_agg(DISTINCT o.opportunity_id) INTO v_ids
    FROM public.lead_routing_opportunities o
    LEFT JOIN public.lead_routing_delivery_attempts cur ON cur.attempt_id = o.current_delivery_attempt_id
    WHERE o.v3_enabled
      AND ((o.assigned_agent_id = v_agent.agent_id
            AND o.assigned_at >= v_webhook.created_at - INTERVAL '24 hours')
        OR (o.assigned_agent_id IS NULL AND cur.delivery_kind = 'offer'
            AND REGEXP_REPLACE(cur.target_number, '[ +()-]', '', 'g') = v_sender
            AND cur.requested_at >= v_webhook.created_at - INTERVAL '24 hours'));
  END IF;
  IF v_ids IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'advisor_no_lead');
  END IF;
  IF cardinality(v_ids) > 1 THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'advisor_ambiguous', 'candidates', cardinality(v_ids));
  END IF;

  SELECT o.* INTO v_opp FROM public.lead_routing_opportunities o
  WHERE o.opportunity_id = v_ids[1] FOR UPDATE;
  IF v_opp.normalized_email IS NULL AND v_opp.e164_phone IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'outcome', 'advisor_no_identity', 'opportunity_id', v_opp.opportunity_id);
  END IF;
  INSERT INTO public.lead_advisor_flags(opportunity_id, normalized_email, e164_phone, flagged_by_agent_id, webhook_event_id)
  VALUES (v_opp.opportunity_id, v_opp.normalized_email, v_opp.e164_phone, v_agent.agent_id, p_webhook_event_id)
  ON CONFLICT (opportunity_id) DO NOTHING;
  INSERT INTO public.lead_routing_events(opportunity_id, event_type, actor_id, idempotency_key, metadata)
  VALUES (v_opp.opportunity_id, 'advisor_flagged', v_agent.agent_id,
    'v3-advisor-flag:' || v_opp.opportunity_id::TEXT,
    jsonb_build_object('webhook_event_id', p_webhook_event_id, 'quoted', v_context_wamid IS NOT NULL))
  ON CONFLICT (idempotency_key) DO NOTHING;
  RETURN jsonb_build_object('ok', TRUE, 'outcome', 'advisor_flagged',
    'opportunity_id', v_opp.opportunity_id, 'agent_id', v_agent.agent_id);
END;
$$;
REVOKE ALL ON FUNCTION public.v3_flag_advisor_from_webhook(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v3_flag_advisor_from_webhook(bigint) TO service_role;
NOTIFY pgrst, 'reload schema';
