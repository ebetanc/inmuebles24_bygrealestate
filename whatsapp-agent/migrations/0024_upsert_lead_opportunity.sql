-- 0024_upsert_lead_opportunity.sql
-- Canonical, concurrent-safe opportunity upsert for every intake channel.

CREATE OR REPLACE FUNCTION public.upsert_lead_opportunity(
  p_conversation_id UUID,
  p_property_id TEXT,
  p_portal_person_id TEXT DEFAULT NULL,
  p_email TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_source TEXT DEFAULT NULL,
  p_external_id TEXT DEFAULT NULL,
  p_initial_state TEXT DEFAULT 'captured'
) RETURNS TABLE (
  opportunity_id BIGINT,
  identity_key TEXT,
  identity_reason TEXT,
  state TEXT,
  created BOOLEAN,
  should_route BOOLEAN
) AS $$
#variable_conflict use_column
DECLARE
  v_source TEXT := NULLIF(lower(btrim(p_source)), '');
  v_portal_person_id TEXT;
  v_normalized_email TEXT := NULLIF(lower(btrim(p_email)), '');
  v_e164_phone TEXT;
  v_identity_key TEXT;
  v_identity_reason TEXT;
  v_property_id TEXT := NULLIF(btrim(p_property_id), '');
  v_opportunity public.lead_routing_opportunities;
  v_created BOOLEAN := FALSE;
  v_event_type TEXT;
  v_event_key TEXT;
  v_event_id BIGINT;
  v_existing_event public.lead_routing_events;
  v_external_evidence JSONB;
BEGIN
  IF p_initial_state NOT IN ('captured', 'queued_night') THEN
    RAISE EXCEPTION 'invalid initial opportunity state: %', p_initial_state;
  END IF;

  -- Portal identifiers are meaningful only inside an allowlisted issuer namespace.
  IF v_source IN ('easybroker', 'inmuebles24') THEN
    v_portal_person_id := NULLIF(btrim(p_portal_person_id), '');
  END IF;

  -- Accept a literal international + and visual separators only; never infer a country code.
  IF btrim(COALESCE(p_phone, '')) ~ '^\+[0-9][0-9 ()-]*[0-9]$'
     AND regexp_replace(btrim(p_phone), '[ ()-]', '', 'g') ~ '^\+[0-9]{8,15}$' THEN
    v_e164_phone := regexp_replace(btrim(p_phone), '[ ()-]', '', 'g');
  END IF;

  IF v_portal_person_id IS NOT NULL THEN
    v_identity_key := 'portal:' || v_source || ':' || v_portal_person_id;
    v_identity_reason := 'portal_person_id';
  ELSIF v_normalized_email IS NOT NULL THEN
    v_identity_key := 'email:' || v_normalized_email;
    v_identity_reason := 'normalized_email';
  ELSIF v_e164_phone IS NOT NULL THEN
    v_identity_key := 'phone:' || v_e164_phone;
    v_identity_reason := 'e164_phone';
  ELSE
    v_identity_reason := 'missing_identity';
  END IF;

  IF v_source IS NOT NULL AND NULLIF(btrim(p_external_id), '') IS NOT NULL THEN
    v_event_key := 'intake:' || v_source || ':' || btrim(p_external_id);
    v_external_evidence := jsonb_build_object(
      'source', v_source, 'external_id', btrim(p_external_id)
    );
  END IF;

  IF v_identity_key IS NULL OR v_property_id IS NULL THEN
    INSERT INTO public.lead_routing_opportunities (
      conversation_id, property_id, portal_person_id, normalized_email, e164_phone,
      identity_key, identity_reason, state
    ) VALUES (
      p_conversation_id, v_property_id, v_portal_person_id, v_normalized_email,
      v_e164_phone, NULL, v_identity_reason, 'manual_non_deduplicable'
    ) RETURNING * INTO v_opportunity;
    v_created := TRUE;
  ELSE
    INSERT INTO public.lead_routing_opportunities (
      conversation_id, property_id, portal_person_id, normalized_email, e164_phone,
      identity_key, identity_reason, state
    ) VALUES (
      p_conversation_id, v_property_id, v_portal_person_id, v_normalized_email,
      v_e164_phone, v_identity_key, v_identity_reason, p_initial_state
    )
    ON CONFLICT (identity_key, property_id)
      WHERE state NOT IN ('closed_won', 'closed_lost')
        AND identity_key IS NOT NULL AND property_id IS NOT NULL
    DO NOTHING
    RETURNING * INTO v_opportunity;

    IF FOUND THEN
      v_created := TRUE;
    ELSE
      SELECT * INTO v_opportunity
      FROM public.lead_routing_opportunities AS o
      WHERE o.identity_key = v_identity_key
        AND o.property_id = v_property_id
        AND o.state NOT IN ('closed_won', 'closed_lost')
      ORDER BY o.opportunity_id
      LIMIT 1
      FOR UPDATE;

      UPDATE public.lead_routing_opportunities AS o
      SET conversation_id = COALESCE(o.conversation_id, p_conversation_id),
          portal_person_id = COALESCE(o.portal_person_id, v_portal_person_id),
          normalized_email = COALESCE(o.normalized_email, v_normalized_email),
          e164_phone = COALESCE(o.e164_phone, v_e164_phone),
          updated_at = NOW()
      WHERE o.opportunity_id = v_opportunity.opportunity_id
      RETURNING * INTO v_opportunity;
    END IF;
  END IF;

  -- A committed replay returns the canonical row without creating a second event.
  IF v_event_key IS NOT NULL THEN
    SELECT * INTO v_existing_event
    FROM public.lead_routing_events AS e
    WHERE e.idempotency_key = v_event_key;

    IF FOUND THEN
      IF v_existing_event.opportunity_id <> v_opportunity.opportunity_id
         OR v_existing_event.event_type NOT IN ('detected', 'deduplicated')
         OR v_existing_event.external_evidence IS DISTINCT FROM v_external_evidence THEN
        RAISE EXCEPTION 'intake idempotency key collision: %', v_event_key;
      END IF;
      RETURN QUERY SELECT
        v_opportunity.opportunity_id, v_opportunity.identity_key,
        v_opportunity.identity_reason, v_opportunity.state, FALSE, FALSE;
      RETURN;
    END IF;
  END IF;

  v_event_type := CASE WHEN v_created THEN 'detected' ELSE 'deduplicated' END;
  v_event_key := COALESCE(v_event_key,
    'intake:' || v_event_type || ':' || v_opportunity.opportunity_id::TEXT
      || ':' || COALESCE(p_conversation_id::TEXT, gen_random_uuid()::TEXT)
  );

  v_external_evidence := COALESCE(v_external_evidence, jsonb_strip_nulls(jsonb_build_object(
    'source', v_source, 'external_id', NULLIF(btrim(p_external_id), '')
  )));

  INSERT INTO public.lead_routing_events (
    opportunity_id, event_type, idempotency_key, external_evidence, metadata
  ) VALUES (
    v_opportunity.opportunity_id, v_event_type, v_event_key,
    v_external_evidence,
    jsonb_build_object('identity_reason', v_identity_reason)
  ) ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING event_id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT * INTO v_existing_event
    FROM public.lead_routing_events AS e
    WHERE e.idempotency_key = v_event_key;

    IF v_existing_event.opportunity_id <> v_opportunity.opportunity_id
       OR v_existing_event.event_type <> v_event_type
       OR v_existing_event.external_evidence IS DISTINCT FROM v_external_evidence THEN
      RAISE EXCEPTION 'intake idempotency key collision: %', v_event_key;
    END IF;
  END IF;

  RETURN QUERY SELECT
    v_opportunity.opportunity_id,
    v_opportunity.identity_key,
    v_opportunity.identity_reason,
    v_opportunity.state,
    v_created,
    v_created AND v_opportunity.state <> 'manual_non_deduplicable';
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog;

REVOKE ALL ON FUNCTION public.upsert_lead_opportunity(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_lead_opportunity(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO service_role;
