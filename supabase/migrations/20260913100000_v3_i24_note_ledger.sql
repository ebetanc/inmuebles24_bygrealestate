-- V3: the internal note the team writes by hand in the Inmuebles24 conversation
-- ("Nota interna: Gina") becomes a durable, leased job.
--
-- Every V3 opportunity that reaches a final outcome enqueues exactly one note:
--   state='assigned'   -> the responsible's first name (from agents.name)
--   state='unassigned' -> the literal 'SIN ASIGNACIÓN'
-- The Inmuebles24 conversation is i24_capture_events.external_event_id; without
-- one there is nothing to write on, so nothing is enqueued.
--
-- Lease/finish mirror claim_v3_easybroker_effects / finish_v3_easybroker_effect
-- (20260912100000_v3_unassigned.sql) with a single step and no alerting.

CREATE TABLE IF NOT EXISTS public.i24_note_ledger (
  opportunity_id bigint PRIMARY KEY REFERENCES public.lead_routing_opportunities(opportunity_id),
  capture_event_id bigint,
  i24_lead_id text NOT NULL,
  note_text text NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','leased','succeeded','failed','manual_review')),
  attempts integer NOT NULL DEFAULT 0,
  lease_token uuid,
  lease_until timestamptz,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.i24_note_ledger IS
  'One pending internal Inmuebles24 note per V3 opportunity that reached a final outcome. Written by the Pi worker under a lease.';

ALTER TABLE public.i24_note_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.i24_note_ledger FROM anon, authenticated;
GRANT SELECT,INSERT,UPDATE ON public.i24_note_ledger TO service_role;

-- Enqueue on the state transition itself: the routing functions never have to
-- remember to call anything, and a replayed UPDATE cannot duplicate the note.
CREATE FUNCTION public.v3_enqueue_i24_note() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_note text; v_capture bigint; v_lead text;
BEGIN
  IF NOT NEW.v3_enabled OR NEW.state IS NOT DISTINCT FROM OLD.state THEN
    RETURN NULL;
  END IF;
  IF NEW.state = 'assigned' AND NEW.assigned_agent_id IS NOT NULL THEN
    SELECT split_part(regexp_replace(BTRIM(a.name), '\s+', ' ', 'g'), ' ', 1)
      INTO v_note
    FROM public.agents a
    WHERE a.agent_id = NEW.assigned_agent_id
      AND NULLIF(BTRIM(a.name), '') IS NOT NULL;
    IF v_note IS NULL THEN RETURN NULL; END IF;
  ELSIF NEW.state = 'unassigned' THEN
    v_note := 'SIN ASIGNACIÓN';
  ELSE
    RETURN NULL;
  END IF;

  SELECT e.capture_event_id, e.external_event_id INTO v_capture, v_lead
  FROM public.i24_capture_events e
  WHERE e.opportunity_id = NEW.opportunity_id
    AND e.external_event_id IS NOT NULL
  ORDER BY e.capture_event_id DESC
  LIMIT 1;
  IF v_capture IS NULL THEN RETURN NULL; END IF;

  INSERT INTO public.i24_note_ledger(
    opportunity_id, capture_event_id, i24_lead_id, note_text
  ) VALUES (NEW.opportunity_id, v_capture, v_lead, v_note)
  ON CONFLICT (opportunity_id) DO NOTHING;
  RETURN NULL;
END $$;

CREATE TRIGGER v3_enqueue_i24_note AFTER UPDATE OF state ON public.lead_routing_opportunities
FOR EACH ROW EXECUTE FUNCTION public.v3_enqueue_i24_note();

-- Lease the oldest actionable notes. A dead worker's lease expires; five
-- attempts is the ceiling before finish_v3_i24_note parks the row.
CREATE FUNCTION public.claim_v3_i24_notes(p_limit integer, p_now timestamptz)
RETURNS TABLE(opportunity_id bigint, i24_lead_id text, note_text text,
              lease_token uuid, attempt integer)
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT l.opportunity_id AS oid
    FROM public.i24_note_ledger l
    WHERE l.attempts < 5
      AND (l.state = 'pending'
           OR (l.state IN ('leased','failed')
               AND (l.lease_until IS NULL OR l.lease_until < p_now)))
    ORDER BY l.created_at
    LIMIT GREATEST(p_limit, 1)
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.i24_note_ledger l
  SET state = 'leased',
      lease_token = gen_random_uuid(),
      lease_until = p_now + interval '3 minutes',
      attempts = l.attempts + 1,
      updated_at = p_now
  FROM candidates c
  WHERE l.opportunity_id = c.oid
  RETURNING l.opportunity_id, l.i24_lead_id, l.note_text, l.lease_token, l.attempts;
END $$;

-- Close a leased note. A wrong or expired lease changes nothing and returns
-- false; the fifth failure parks the row for a human.
CREATE FUNCTION public.finish_v3_i24_note(p_opportunity_id bigint, p_token uuid,
                                          p_ok boolean, p_evidence jsonb)
RETURNS boolean
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_rows integer;
BEGIN
  UPDATE public.i24_note_ledger l
  SET state = CASE WHEN p_ok THEN 'succeeded'
                   WHEN l.attempts >= 5 THEN 'manual_review'
                   ELSE 'failed' END,
      lease_token = NULL,
      lease_until = NULL,
      updated_at = now(),
      evidence = l.evidence || jsonb_build_object(
        to_char(now(), 'YYYYMMDDHH24MISS'), COALESCE(p_evidence, '{}'::jsonb))
  WHERE l.opportunity_id = p_opportunity_id
    AND l.lease_token = p_token
    AND l.state = 'leased';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows = 1;
END $$;

REVOKE ALL ON FUNCTION public.claim_v3_i24_notes(INTEGER,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_v3_i24_notes(INTEGER,TIMESTAMPTZ)
  TO service_role;
REVOKE ALL ON FUNCTION public.finish_v3_i24_note(BIGINT,UUID,BOOLEAN,JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finish_v3_i24_note(BIGINT,UUID,BOOLEAN,JSONB)
  TO service_role;
