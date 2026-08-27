-- 0038_recover_legacy_i24_intake.sql
-- Reconciles retries of legacy Inmuebles24 intake rows that were stored as
-- manual_non_deduplicable before phone normalization was fixed.
-- Rollback: DROP FUNCTION IF EXISTS public.upsert_i24_lead_opportunity_recovering(
--   uuid, text, text, text, text, text, text, text
-- );

CREATE OR REPLACE FUNCTION public.upsert_i24_lead_opportunity_recovering(
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
  v_external_id TEXT := NULLIF(btrim(p_external_id), '');
  v_property_id TEXT := NULLIF(btrim(p_property_id), '');
  v_portal_person_id TEXT;
  v_normalized_email TEXT := NULLIF(lower(btrim(p_email)), '');
  v_e164_phone TEXT;
  v_identity_key TEXT;
  v_identity_reason TEXT;
  v_event public.lead_routing_events;
  v_opportunity public.lead_routing_opportunities;
  v_promoted BOOLEAN := FALSE;
BEGIN
  IF v_source IS DISTINCT FROM 'inmuebles24' THEN
    RAISE EXCEPTION 'legacy intake recovery is restricted to inmuebles24';
  END IF;

  RETURN QUERY
  SELECT *
  FROM public.upsert_lead_opportunity(
    p_conversation_id, p_property_id, p_portal_person_id, p_email, p_phone,
    p_source, p_external_id, p_initial_state
  );
  RETURN;
EXCEPTION
  WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'intake idempotency key collision:%'
       OR v_external_id IS NULL THEN
      RAISE;
    END IF;

    SELECT e.* INTO v_event
    FROM public.lead_routing_events AS e
    WHERE e.idempotency_key = 'intake:inmuebles24:' || v_external_id
    FOR UPDATE;

    IF NOT FOUND
       OR v_event.event_type NOT IN ('detected', 'deduplicated')
       OR v_event.external_evidence IS DISTINCT FROM jsonb_build_object(
         'source', 'inmuebles24', 'external_id', v_external_id
       ) THEN
      RAISE;
    END IF;

    SELECT o.* INTO v_opportunity
    FROM public.lead_routing_opportunities AS o
    WHERE o.opportunity_id = v_event.opportunity_id
    FOR UPDATE;

    IF NOT FOUND OR v_opportunity.state IS DISTINCT FROM 'manual_non_deduplicable' THEN
      RAISE;
    END IF;

    v_portal_person_id := NULLIF(btrim(p_portal_person_id), '');
    IF btrim(COALESCE(p_phone, '')) ~ '^\+[0-9][0-9 ()-]*[0-9]$'
       AND regexp_replace(btrim(p_phone), '[ ()-]', '', 'g') ~ '^\+[0-9]{8,15}$' THEN
      v_e164_phone := regexp_replace(btrim(p_phone), '[ ()-]', '', 'g');
    END IF;

    IF v_portal_person_id IS NOT NULL THEN
      v_identity_key := 'portal:inmuebles24:' || v_portal_person_id;
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

    v_promoted := v_identity_key IS NOT NULL AND v_property_id IS NOT NULL;

    IF v_promoted AND EXISTS (
      SELECT 1
      FROM public.lead_routing_opportunities AS other
      WHERE other.opportunity_id <> v_opportunity.opportunity_id
        AND other.identity_key = v_identity_key
        AND other.property_id = v_property_id
        AND other.state NOT IN ('closed_won', 'closed_lost')
    ) THEN
      RAISE EXCEPTION 'legacy intake recovery conflicts with canonical opportunity';
    END IF;

    UPDATE public.lead_routing_opportunities AS o
    SET conversation_id = COALESCE(o.conversation_id, p_conversation_id),
        property_id = COALESCE(v_property_id, o.property_id),
        portal_person_id = COALESCE(v_portal_person_id, o.portal_person_id),
        normalized_email = COALESCE(v_normalized_email, o.normalized_email),
        e164_phone = COALESCE(v_e164_phone, o.e164_phone),
        identity_key = CASE WHEN v_promoted THEN v_identity_key ELSE o.identity_key END,
        identity_reason = CASE WHEN v_promoted THEN v_identity_reason ELSE o.identity_reason END,
        state = CASE WHEN v_promoted THEN p_initial_state ELSE o.state END,
        updated_at = NOW()
    WHERE o.opportunity_id = v_opportunity.opportunity_id
    RETURNING * INTO v_opportunity;

    IF v_promoted THEN
      INSERT INTO public.lead_routing_events (
        opportunity_id, event_type, idempotency_key, external_evidence, metadata
      ) VALUES (
        v_opportunity.opportunity_id,
        'identity_recovered',
        'recovery:intake:inmuebles24:' || v_external_id,
        jsonb_build_object('source', 'inmuebles24', 'external_id', v_external_id),
        jsonb_build_object('identity_reason', v_identity_reason)
      ) ON CONFLICT (idempotency_key) DO NOTHING;
    END IF;

    RETURN QUERY SELECT
      v_opportunity.opportunity_id,
      v_opportunity.identity_key,
      v_opportunity.identity_reason,
      v_opportunity.state,
      FALSE,
      v_promoted;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog;

REVOKE ALL ON FUNCTION public.upsert_i24_lead_opportunity_recovering(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_i24_lead_opportunity_recovering(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
) TO service_role;
