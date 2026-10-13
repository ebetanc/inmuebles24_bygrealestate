-- Tokko leads get Contactado + internal note in Inmuebles24 again (2026-10-13), at TOMO only.
-- The Pi no longer captures; it reads the i24 inbox, pairs each assigned Tokko opportunity with
-- its i24 conversation (same listing + same email or phone) and enqueues it in i24_note_ledger.
-- The note worker then flips the conversation to Contactado and writes '<Nombre> · V3 HH:MM'.
-- Unassigned leads stay Pendiente in i24 on purpose: nobody took them.
-- The trigger v3_enqueue_i24_note stays disabled: Tokko captures carry no i24 conversation id.

-- Assigned Tokko/Inmuebles24 opportunities still without an i24 conversation paired.
CREATE OR REPLACE FUNCTION public.v3_i24_tokko_unpaired(p_since timestamptz)
RETURNS TABLE(opportunity_id bigint, email text, phone text, listing_id text,
              property_public_id text, assigned_at timestamptz)
LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT o.opportunity_id, o.normalized_email, o.e164_phone,
         o.v3_offer_context->>'listing_id', o.property_id, o.assigned_at
  FROM public.lead_routing_opportunities o
  WHERE o.v3_enabled
    AND o.state = 'assigned'
    AND o.assigned_at >= p_since
    AND o.v3_offer_context->>'origin' = 'tokko'
    AND o.v3_offer_context->>'portal' = 'inmuebles24'
    AND NOT EXISTS (SELECT 1 FROM public.i24_note_ledger l WHERE l.opportunity_id = o.opportunity_id)
  ORDER BY o.assigned_at;
$$;

-- Enqueue the Contactado + note job for one paired opportunity. Same note text as the
-- old trigger. Replays are no-ops.
CREATE OR REPLACE FUNCTION public.v3_i24_tokko_pair(p_opportunity_id bigint, p_i24_lead_id text)
RETURNS boolean
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_note text; v_capture bigint; v_rows integer;
BEGIN
  IF p_i24_lead_id !~ '^\d+$' THEN RETURN false; END IF;
  SELECT split_part(regexp_replace(BTRIM(a.name), '\s+', ' ', 'g'), ' ', 1)
         || ' · V3 ' || to_char(o.assigned_at AT TIME ZONE 'America/Mexico_City', 'HH24:MI'),
         (SELECT max(e.capture_event_id) FROM public.i24_capture_events e
          WHERE e.opportunity_id = o.opportunity_id)
    INTO v_note, v_capture
  FROM public.lead_routing_opportunities o
  JOIN public.agents a ON a.agent_id = o.assigned_agent_id
  WHERE o.opportunity_id = p_opportunity_id
    AND o.state = 'assigned'
    AND NULLIF(BTRIM(a.name), '') IS NOT NULL;
  IF v_note IS NULL THEN RETURN false; END IF;

  INSERT INTO public.i24_note_ledger(opportunity_id, capture_event_id, i24_lead_id, note_text)
  VALUES (p_opportunity_id, v_capture, p_i24_lead_id, v_note)
  ON CONFLICT (opportunity_id) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows = 1;
END $$;

REVOKE ALL ON FUNCTION public.v3_i24_tokko_unpaired(TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v3_i24_tokko_unpaired(TIMESTAMPTZ) TO service_role;
REVOKE ALL ON FUNCTION public.v3_i24_tokko_pair(BIGINT,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v3_i24_tokko_pair(BIGINT,TEXT) TO service_role;
