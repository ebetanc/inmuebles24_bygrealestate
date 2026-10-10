-- Tokko becomes the V3 lead source (2026-10-10). WF25 reads each Tokko notice from Gmail and
-- calls v3_tokko_intake; the Pi scraper no longer captures, marks Contactado or writes notes.
--
-- A Tokko lead enters through the same v3_intake as a scraper capture, so dedup, night queue,
-- route dispatch (Pi dispatcher -> WF10), EasyBroker effects and reports stay unchanged.
-- The only difference: there is no Inmuebles24 conversation to mark, so Contactado is not
-- required and the capture is verified on arrival. Without day_sla_version in the offer
-- context, the 15-minute day deadline does not apply.
-- ponytail: source stays 'inmuebles24' for every Tokko portal (JamesEdition included); the
-- real portal lives in offer_context.portal. A distinct source means touching v3_intake,
-- WF10 and the dispatcher; do it if a report ever needs to split by portal.

CREATE OR REPLACE FUNCTION public.v3_tokko_intake(
  p_account_key TEXT,
  p_idempotency_key TEXT,
  p_external_id TEXT,
  p_property_public_id TEXT,
  p_email TEXT,
  p_phone TEXT,
  p_offer_context JSONB,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS TABLE(
  disposition TEXT,
  opportunity_id BIGINT,
  capture_event_id BIGINT,
  contactado_status TEXT,
  reason TEXT
)
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
#variable_conflict use_column
DECLARE
  r RECORD;
BEGIN
  SELECT i.* INTO r
  FROM public.v3_intake(p_account_key, p_idempotency_key, 'inmuebles24', p_external_id, NULL,
    p_property_public_id, p_email, p_phone, p_offer_context, p_now) AS i;

  IF r.disposition <> 'non_routable' THEN
    UPDATE public.i24_capture_events AS e
    SET contactado_status = 'verified', contactado_verified_at = p_now
    WHERE e.capture_event_id = r.capture_event_id AND e.contactado_status = 'pending';
    UPDATE public.lead_routing_opportunities AS o
    SET v3_contactado_status = 'verified', v3_contactado_verified_at = p_now, updated_at = p_now
    WHERE o.opportunity_id = r.opportunity_id AND o.v3_contactado_status = 'pending';
  END IF;

  RETURN QUERY
  SELECT e.disposition, e.opportunity_id, e.capture_event_id, e.contactado_status, e.reason
  FROM public.i24_capture_events AS e
  WHERE e.capture_event_id = r.capture_event_id;
END;
$$;

REVOKE ALL ON FUNCTION public.v3_tokko_intake(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v3_tokko_intake(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB,TIMESTAMPTZ)
  TO service_role;

-- Nobody writes Inmuebles24 notes any more; stop enqueueing them.
-- Rollback: ALTER TABLE public.lead_routing_opportunities ENABLE TRIGGER v3_enqueue_i24_note;
ALTER TABLE public.lead_routing_opportunities DISABLE TRIGGER v3_enqueue_i24_note;
