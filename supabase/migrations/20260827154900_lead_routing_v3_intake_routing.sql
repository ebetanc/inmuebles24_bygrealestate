-- PROPOSED / NO APLICADO — V3-03/V3-04 local draft
-- Canonical V3 intake/routing on existing lead_routing_* tables.
-- Contactado is ledgered per capture_event_id in i24_capture_events; the
-- legacy opportunity-level effect table cannot represent repeated captures.
-- No external portal, WhatsApp, EasyBroker, or n8n mutation is performed here.
-- Apply only after schema/advisor review and the documented production gates.

-- V3-02 capture table is canonical when already present. The IF NOT EXISTS path
-- keeps this draft independently testable against the recorded production schema.
CREATE TABLE IF NOT EXISTS public.i24_capture_events (
  capture_event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_key TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source = 'inmuebles24'),
  external_event_id TEXT,
  idempotency_key TEXT NOT NULL,
  portal_person_id TEXT,
  property_public_id TEXT,
  normalized_email TEXT,
  e164_phone TEXT,
  identity_key TEXT,
  opportunity_id BIGINT REFERENCES public.lead_routing_opportunities(opportunity_id),
  disposition TEXT NOT NULL CHECK (disposition IN ('created_new','active_duplicate','returning_assigned','non_routable')),
  reason TEXT,
  offer_context JSONB NOT NULL DEFAULT '{}'::JSONB,
  contactado_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (contactado_status IN ('pending','leased','verified','failed','manual_review')),
  contactado_attempts INTEGER NOT NULL DEFAULT 0 CHECK (contactado_attempts >= 0),
  contactado_first_failed_at TIMESTAMPTZ,
  contactado_next_attempt_at TIMESTAMPTZ,
  contactado_verified_at TIMESTAMPTZ,
  route_dispatch_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (route_dispatch_status IN ('pending','leased','dispatched','failed','manual_review')),
  route_dispatch_attempts INTEGER NOT NULL DEFAULT 0 CHECK (route_dispatch_attempts >= 0),
  route_dispatch_next_attempt_at TIMESTAMPTZ,
  route_dispatched_at TIMESTAMPTZ,
  happened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  correlation_window_start_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  correlation_horizon_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '24 hours'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (account_key, idempotency_key)
);

ALTER TABLE public.i24_capture_events ALTER COLUMN external_event_id DROP NOT NULL;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS idempotency_key TEXT;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS portal_person_id TEXT;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS identity_key TEXT;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS opportunity_id BIGINT REFERENCES public.lead_routing_opportunities(opportunity_id);
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS disposition TEXT;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS reason TEXT;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS offer_context JSONB NOT NULL DEFAULT '{}'::JSONB;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS contactado_status TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS contactado_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS contactado_first_failed_at TIMESTAMPTZ;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS contactado_next_attempt_at TIMESTAMPTZ;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS contactado_verified_at TIMESTAMPTZ;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS contactado_lease_token UUID;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS contactado_lease_expires_at TIMESTAMPTZ;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS contactado_last_error_code TEXT;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS route_dispatch_status TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS route_dispatch_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS route_dispatch_lease_token UUID;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS route_dispatch_lease_expires_at TIMESTAMPTZ;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS route_dispatch_next_attempt_at TIMESTAMPTZ;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS route_dispatch_last_error_code TEXT;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS route_dispatched_at TIMESTAMPTZ;
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS correlation_window_start_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE public.i24_capture_events ADD COLUMN IF NOT EXISTS correlation_horizon_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '24 hours');
ALTER TABLE public.i24_capture_events ALTER COLUMN correlation_window_start_at SET DEFAULT NOW();
ALTER TABLE public.i24_capture_events ALTER COLUMN correlation_horizon_at SET DEFAULT (NOW() + INTERVAL '24 hours');
UPDATE public.i24_capture_events SET idempotency_key='v3-legacy:' || capture_event_id::TEXT WHERE NULLIF(BTRIM(idempotency_key),'') IS NULL;
UPDATE public.i24_capture_events SET disposition='non_routable' WHERE disposition IS NULL;
UPDATE public.i24_capture_events SET contactado_status='manual_review' WHERE contactado_status IS NULL;
ALTER TABLE public.i24_capture_events ALTER COLUMN disposition SET DEFAULT 'non_routable';
ALTER TABLE public.i24_capture_events ALTER COLUMN contactado_status SET DEFAULT 'pending';
ALTER TABLE public.i24_capture_events ALTER COLUMN idempotency_key SET NOT NULL;
ALTER TABLE public.i24_capture_events ALTER COLUMN disposition SET NOT NULL;
ALTER TABLE public.i24_capture_events ALTER COLUMN contactado_status SET NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='i24_capture_events_idempotency_required' AND conrelid='public.i24_capture_events'::regclass) THEN
    ALTER TABLE public.i24_capture_events ADD CONSTRAINT i24_capture_events_idempotency_required CHECK (NULLIF(BTRIM(idempotency_key), '') IS NOT NULL);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='i24_capture_events_disposition_check' AND conrelid='public.i24_capture_events'::regclass) THEN
    ALTER TABLE public.i24_capture_events ADD CONSTRAINT i24_capture_events_disposition_check CHECK (disposition IN ('created_new','active_duplicate','returning_assigned','non_routable'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='i24_capture_events_contactado_status_check' AND conrelid='public.i24_capture_events'::regclass) THEN
    ALTER TABLE public.i24_capture_events ADD CONSTRAINT i24_capture_events_contactado_status_check CHECK (contactado_status IN ('pending','leased','verified','failed','manual_review'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='i24_capture_events_route_dispatch_status_check' AND conrelid='public.i24_capture_events'::regclass) THEN
    ALTER TABLE public.i24_capture_events ADD CONSTRAINT i24_capture_events_route_dispatch_status_check CHECK (route_dispatch_status IN ('pending','leased','dispatched','failed','manual_review'));
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS i24_capture_events_external_uniq
  ON public.i24_capture_events(account_key, source, external_event_id)
  WHERE external_event_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS i24_capture_events_idempotency_uniq
  ON public.i24_capture_events(account_key, idempotency_key);
ALTER TABLE public.i24_capture_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.i24_capture_events FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.i24_capture_events TO service_role;

-- Add only V3 state to the canonical opportunity row; no parallel queue/state table.
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_account_key TEXT;
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_source TEXT;
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_external_id TEXT;
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_offer_context JSONB NOT NULL DEFAULT '{}'::JSONB;
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_contactado_status TEXT NOT NULL DEFAULT 'not_required';
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_contactado_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_contactado_first_failed_at TIMESTAMPTZ;
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_contactado_next_attempt_at TIMESTAMPTZ;
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_contactado_verified_at TIMESTAMPTZ;
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_contactado_last_error TEXT;
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_night_queued_at TIMESTAMPTZ;
ALTER TABLE public.lead_routing_opportunities ADD COLUMN IF NOT EXISTS v3_night_released_at TIMESTAMPTZ;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='lead_routing_opportunities_v3_contactado_status_check' AND conrelid='public.lead_routing_opportunities'::regclass) THEN
    ALTER TABLE public.lead_routing_opportunities ADD CONSTRAINT lead_routing_opportunities_v3_contactado_status_check
      CHECK (v3_contactado_status IN ('not_required','pending','leased','verified','failed','manual_review'));
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS lead_routing_opportunities_v3_external_uniq
  ON public.lead_routing_opportunities(v3_account_key, v3_source, v3_external_id)
  WHERE v3_enabled AND v3_external_id IS NOT NULL;

ALTER TABLE public.lead_routing_delivery_attempts ADD COLUMN IF NOT EXISTS provider_accepted_at TIMESTAMPTZ;
ALTER TABLE public.lead_routing_delivery_attempts ADD COLUMN IF NOT EXISTS capture_event_id BIGINT REFERENCES public.i24_capture_events(capture_event_id);
ALTER TABLE public.lead_routing_delivery_attempts ADD COLUMN IF NOT EXISTS delivery_kind TEXT NOT NULL DEFAULT 'offer';
ALTER TABLE public.lead_routing_delivery_attempts ALTER COLUMN routing_tier DROP NOT NULL;
ALTER TABLE public.lead_routing_delivery_attempts DROP CONSTRAINT IF EXISTS lead_routing_delivery_attempts_routing_tier_check;
ALTER TABLE public.lead_routing_delivery_attempts ADD CONSTRAINT lead_routing_delivery_attempts_routing_tier_check
  CHECK (routing_tier IS NULL OR routing_tier IN ('owner','primary_guard','backup_guard'));
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='lead_routing_delivery_attempts_delivery_kind_check' AND conrelid='public.lead_routing_delivery_attempts'::regclass) THEN
    ALTER TABLE public.lead_routing_delivery_attempts ADD CONSTRAINT lead_routing_delivery_attempts_delivery_kind_check
      CHECK (delivery_kind IN ('offer','assigned_notice'));
  END IF;
END $$;

-- One-guard cutover from the preflight snapshot. Primary rows are preserved;
-- former backup rows become unranked historical rows in the same canonical
-- table, so rollback never needs to destroy or recreate schedule data.
UPDATE public.agent_schedule SET coverage_role=NULL WHERE coverage_role='backup';
ALTER TABLE public.agent_schedule DROP CONSTRAINT IF EXISTS agent_schedule_coverage_role_check;
ALTER TABLE public.agent_schedule ADD CONSTRAINT agent_schedule_coverage_role_check
  CHECK (coverage_role IS NULL OR coverage_role='primary');
CREATE UNIQUE INDEX IF NOT EXISTS agent_schedule_one_guard_uniq
  ON public.agent_schedule(schedule_date,shift) WHERE coverage_role='primary';

CREATE OR REPLACE FUNCTION public.save_month_schedule(
  p_first_date DATE, p_last_date DATE, p_rows JSONB
) RETURNS INTEGER
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE v_inserted INTEGER;
BEGIN
  IF p_first_date IS NULL OR p_last_date IS NULL OR p_first_date>p_last_date
     OR p_last_date-p_first_date>30 THEN RAISE EXCEPTION 'invalid schedule range'; END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_rows)>62 THEN RAISE EXCEPTION 'one-guard schedule requires a bounded array'; END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_rows) x(row_data)
    WHERE jsonb_typeof(x.row_data) IS DISTINCT FROM 'object'
      OR CASE WHEN x.row_data->>'schedule_date' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
           THEN (x.row_data->>'schedule_date')::DATE NOT BETWEEN p_first_date AND p_last_date
           ELSE TRUE END
      OR x.row_data->>'shift' NOT IN ('morning','afternoon')
      OR NULLIF(BTRIM(x.row_data->>'agent_id'),'') IS NULL
      OR NOT EXISTS (SELECT 1 FROM public.agents a WHERE a.agent_id=x.row_data->>'agent_id' AND a.is_available
        AND NULLIF(BTRIM(a.whatsapp_number),'') IS NOT NULL)
  ) THEN RAISE EXCEPTION 'invalid one-guard schedule row'; END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_rows) x(row_data)
    GROUP BY x.row_data->>'schedule_date',x.row_data->>'shift' HAVING COUNT(*)>1
  ) THEN RAISE EXCEPTION 'one guard per date and shift'; END IF;
  DELETE FROM public.agent_schedule WHERE schedule_date BETWEEN p_first_date AND p_last_date;
  INSERT INTO public.agent_schedule(schedule_date,shift,agent_id,coverage_role)
  SELECT (x.row_data->>'schedule_date')::DATE,x.row_data->>'shift',x.row_data->>'agent_id','primary'
  FROM jsonb_array_elements(p_rows) x(row_data);
  GET DIAGNOSTICS v_inserted=ROW_COUNT;
  RETURN v_inserted;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_guard_coverage_slots(
  p_schedule_date DATE DEFAULT (NOW() AT TIME ZONE 'America/Mexico_City')::DATE,
  p_shift TEXT DEFAULT CASE
    WHEN (NOW() AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '08:00:00'
     AND (NOW() AT TIME ZONE 'America/Mexico_City')::TIME < TIME '14:00:00' THEN 'morning'
    WHEN (NOW() AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '14:00:00'
     AND (NOW() AT TIME ZONE 'America/Mexico_City')::TIME < TIME '20:00:00' THEN 'afternoon'
    ELSE 'night'
  END
) RETURNS TABLE(coverage_role TEXT,agent_id TEXT,agent_name TEXT,whatsapp_number TEXT)
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
  SELECT s.coverage_role,a.agent_id,a.name,a.whatsapp_number
  FROM public.agent_schedule s JOIN public.agents a ON a.agent_id=s.agent_id
  WHERE s.schedule_date=p_schedule_date AND s.shift=p_shift
    AND s.coverage_role='primary' AND a.is_available
    AND NULLIF(BTRIM(a.whatsapp_number),'') IS NOT NULL
  LIMIT 1;
$$;

-- Delivery attempts remain canonical. This trigger blocks only new V3 attempts
-- before verified Contactado; existing V2 rows retain their prior behavior.
CREATE OR REPLACE FUNCTION public.v3_require_contactado_before_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_capture_status TEXT;
  v_capture_id BIGINT;
BEGIN
  SELECT * INTO v_opp
  FROM public.lead_routing_opportunities
  WHERE opportunity_id = NEW.opportunity_id
  FOR SHARE;
  IF v_opp.v3_enabled THEN
    IF current_setting('app.v3_capture_event_id', true) ~ '^[0-9]+$' THEN
      v_capture_id := current_setting('app.v3_capture_event_id', true)::BIGINT;
    END IF;
    SELECT e.contactado_status INTO v_capture_status
    FROM public.i24_capture_events e
    WHERE e.capture_event_id=v_capture_id AND e.opportunity_id=NEW.opportunity_id;
    IF v_capture_id IS NULL OR NOT FOUND THEN
      RAISE EXCEPTION 'V3 delivery requires explicit capture_event_id: %', NEW.opportunity_id;
    END IF;
  END IF;
  IF v_opp.v3_enabled AND v_capture_status IS DISTINCT FROM 'verified' THEN
    RAISE EXCEPTION 'V3 delivery requires verified Contactado: %', NEW.opportunity_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER lead_routing_v3_contactado_gate
  BEFORE INSERT ON public.lead_routing_delivery_attempts
  FOR EACH ROW EXECUTE FUNCTION public.v3_require_contactado_before_delivery();

CREATE OR REPLACE FUNCTION public.v3_intake(
  p_account_key TEXT,
  p_idempotency_key TEXT,
  p_source TEXT DEFAULT 'inmuebles24',
  p_external_id TEXT DEFAULT NULL,
  p_portal_person_id TEXT DEFAULT NULL,
  p_property_public_id TEXT DEFAULT NULL,
  p_email TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL,
  p_offer_context JSONB DEFAULT '{}'::JSONB,
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
DECLARE
  v_existing public.i24_capture_events;
  v_opp public.lead_routing_opportunities;
  v_capture public.i24_capture_events;
  v_account TEXT := NULLIF(BTRIM(p_account_key), '');
  v_source TEXT := LOWER(NULLIF(BTRIM(p_source), ''));
  v_idempotency TEXT := NULLIF(BTRIM(p_idempotency_key), '');
  v_external TEXT := NULLIF(BTRIM(p_external_id), '');
  v_portal TEXT := NULLIF(BTRIM(p_portal_person_id), '');
  v_email TEXT := NULLIF(LOWER(BTRIM(p_email)), '');
  v_phone TEXT;
  v_property TEXT := NULLIF(BTRIM(p_property_public_id), '');
  v_identity TEXT;
  v_identity_reason TEXT;
  v_is_night BOOLEAN;
  v_disposition TEXT;
  v_reason TEXT;
BEGIN
  IF v_account IS NULL OR v_idempotency IS NULL OR p_now IS NULL OR v_source <> 'inmuebles24' THEN
    RAISE EXCEPTION 'invalid V3 intake identity';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_account || ':' || v_source || ':' || v_idempotency, 0));

  SELECT * INTO v_existing
  FROM public.i24_capture_events
  WHERE account_key = v_account AND idempotency_key = v_idempotency
  FOR UPDATE;
  IF FOUND THEN
    RETURN QUERY SELECT v_existing.disposition, v_existing.opportunity_id,
      v_existing.capture_event_id, v_existing.contactado_status, v_existing.reason;
    RETURN;
  END IF;

  IF v_external IS NOT NULL THEN
    SELECT * INTO v_existing
    FROM public.i24_capture_events
    WHERE account_key=v_account AND source=v_source AND external_event_id=v_external
    ORDER BY capture_event_id
    LIMIT 1
    FOR UPDATE;
    IF FOUND THEN
      RETURN QUERY SELECT v_existing.disposition, v_existing.opportunity_id,
        v_existing.capture_event_id, v_existing.contactado_status, v_existing.reason;
      RETURN;
    END IF;
  END IF;

  v_phone := CASE
    WHEN BTRIM(COALESCE(p_phone, '')) ~ '^[+][0-9][0-9 ()-]*[0-9]$'
     AND REGEXP_REPLACE(BTRIM(p_phone), '[ ()-]', '', 'g') ~ '^[+][0-9]{8,15}$'
    THEN REGEXP_REPLACE(BTRIM(p_phone), '[ ()-]', '', 'g')
  END;
  IF v_portal IS NOT NULL THEN
    v_identity := 'portal:' || v_source || ':' || v_portal;
    v_identity_reason := 'portal_person_id';
  ELSIF v_email IS NOT NULL THEN
    v_identity := 'email:' || v_email;
    v_identity_reason := 'normalized_email';
  ELSIF v_phone IS NOT NULL THEN
    v_identity := 'phone:' || v_phone;
    v_identity_reason := 'e164_phone';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_account || ':' || v_source || ':' || COALESCE(v_identity,'missing') || ':' || COALESCE(v_property,'missing'), 0));

  IF v_external IS NULL THEN
    v_disposition := 'non_routable';
    v_reason := 'missing_external_id';
  ELSIF v_identity IS NULL THEN
    v_disposition := 'non_routable';
    v_reason := 'missing_prospect_identity';
  END IF;

  IF v_disposition = 'non_routable' THEN
    INSERT INTO public.i24_capture_events(
      account_key, source, external_event_id, idempotency_key, portal_person_id,
      property_public_id, normalized_email, e164_phone, identity_key, disposition,
      reason, offer_context, contactado_status, route_dispatch_status, happened_at
    ) VALUES (
      v_account, v_source, v_external, v_idempotency, v_portal, v_property,
      v_email, v_phone, v_identity, v_disposition, v_reason,
      COALESCE(p_offer_context, '{}'::JSONB), 'manual_review', 'manual_review', p_now
    ) RETURNING * INTO v_capture;
    RETURN QUERY SELECT v_disposition, NULL::BIGINT, v_capture.capture_event_id,
      'manual_review'::TEXT, v_reason;
    RETURN;
  END IF;

  v_is_night := ((p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '20:00:00'
    OR (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '08:00:00');

  SELECT * INTO v_opp
  FROM public.lead_routing_opportunities
  WHERE v3_enabled
    AND v3_account_key = v_account
    AND identity_key = v_identity
    AND property_id IS NOT DISTINCT FROM v_property
    AND state NOT IN ('closed_won','closed_lost')
  ORDER BY opportunity_id
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    v_disposition := CASE WHEN v_opp.assigned_agent_id IS NULL
      THEN 'active_duplicate' ELSE 'returning_assigned' END;
  ELSE
    INSERT INTO public.lead_routing_opportunities(
      property_id, portal_person_id, normalized_email, e164_phone, identity_key,
      identity_reason, state, v3_enabled, v3_account_key, v3_source, v3_external_id,
      v3_offer_context, v3_contactado_status, v3_night_queued_at
    ) VALUES (
      v_property, v_portal, v_email, v_phone, v_identity, v_identity_reason,
      CASE WHEN v_is_night THEN 'queued_night' ELSE 'captured' END,
      TRUE, v_account, v_source, v_external, COALESCE(p_offer_context, '{}'::JSONB),
      'pending', CASE WHEN v_is_night THEN p_now END
    ) RETURNING * INTO v_opp;
    v_disposition := 'created_new';
  END IF;

  INSERT INTO public.i24_capture_events(
    account_key, source, external_event_id, idempotency_key, portal_person_id,
    property_public_id, normalized_email, e164_phone, identity_key, opportunity_id,
    disposition, reason, offer_context, contactado_status, happened_at
  ) VALUES (
    v_account, v_source, v_external, v_idempotency, v_portal, v_property,
    v_email, v_phone, v_identity, v_opp.opportunity_id, v_disposition,
    CASE WHEN v_property IS NULL THEN 'missing_property_pending_backfill' END,
    COALESCE(p_offer_context, '{}'::JSONB), 'pending', p_now
  ) RETURNING * INTO v_capture;

  IF v_disposition = 'created_new' THEN
    -- Reuse the canonical overnight queue when the required queue phone is
    -- available. Email-only captures remain durable in the opportunity and
    -- are released by v3_release_night_queue without inventing a recipient.
    IF v_is_night AND v_phone IS NOT NULL THEN
      INSERT INTO public.night_queue(
        source, lead_phone, property_id, lead_email, queued_at, opportunity_id
      ) VALUES (
        v_source, v_phone, v_property, v_email, p_now, v_opp.opportunity_id
      ) ON CONFLICT (opportunity_id) WHERE opportunity_id IS NOT NULL DO NOTHING;
    END IF;
  END IF;

  INSERT INTO public.lead_routing_events(
    opportunity_id, event_type, idempotency_key, metadata
  ) VALUES (
    v_opp.opportunity_id, CASE WHEN v_disposition = 'created_new' THEN 'detected' ELSE 'deduplicated' END,
    'v3-intake:' || v_account || ':' || v_idempotency,
    jsonb_build_object('disposition', v_disposition, 'source', v_source,
      'external_id', v_external, 'capture_event_id', v_capture.capture_event_id)
  ) ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN QUERY SELECT v_disposition, v_opp.opportunity_id, v_capture.capture_event_id,
    v_capture.contactado_status, CASE WHEN v_property IS NULL
      THEN 'missing_property_pending_backfill' ELSE NULL END::TEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_v3_i24_contact_effects(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS TABLE(capture_event_id BIGINT, opportunity_id BIGINT, i24_lead_id TEXT, lease_token UUID, attempt INTEGER)
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid V3 Contactado claim input';
  END IF;
  RETURN QUERY
  WITH candidates AS (
    SELECT e.capture_event_id
    FROM public.i24_capture_events e
    JOIN public.lead_routing_opportunities o ON o.opportunity_id = e.opportunity_id
    WHERE o.v3_enabled
      AND e.opportunity_id IS NOT NULL
      AND e.contactado_status IN ('pending','failed','leased')
      AND (e.contactado_status IN ('pending','failed')
        OR (e.contactado_status = 'leased' AND e.contactado_lease_expires_at <= p_now))
      AND COALESCE(e.contactado_next_attempt_at, p_now) <= p_now
    ORDER BY e.contactado_next_attempt_at NULLS FIRST, e.capture_event_id
    FOR UPDATE OF e SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    UPDATE public.i24_capture_events e
    SET contactado_status = 'leased', contactado_lease_token = gen_random_uuid(),
        contactado_lease_expires_at = p_now + INTERVAL '2 minutes',
        contactado_attempts = e.contactado_attempts + 1
    FROM candidates c
    WHERE e.capture_event_id = c.capture_event_id
    RETURNING e.capture_event_id, e.opportunity_id, e.external_event_id,
      e.contactado_lease_token, e.contactado_attempts
  )
  SELECT c.capture_event_id, c.opportunity_id, c.external_event_id,
    c.contactado_lease_token, c.contactado_attempts
  FROM claimed c;
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_v3_i24_contact_effect(
  p_capture_event_id BIGINT,
  p_lease_token UUID,
  p_success BOOLEAN,
  p_error_code TEXT DEFAULT NULL,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_capture public.i24_capture_events;
  v_opp public.lead_routing_opportunities;
  v_attempt INTEGER;
  v_first_failed TIMESTAMPTZ;
  v_next TIMESTAMPTZ;
  v_key TEXT;
BEGIN
  IF p_capture_event_id IS NULL OR p_lease_token IS NULL OR p_success IS NULL OR p_now IS NULL
     OR LENGTH(COALESCE(p_error_code, '')) > 120 THEN
    RAISE EXCEPTION 'invalid V3 Contactado completion input';
  END IF;
  SELECT * INTO v_capture
  FROM public.i24_capture_events
  WHERE capture_event_id = p_capture_event_id
  FOR UPDATE;
  IF NOT FOUND OR v_capture.contactado_status <> 'leased'
     OR v_capture.contactado_lease_token IS DISTINCT FROM p_lease_token
     OR v_capture.contactado_lease_expires_at <= p_now THEN
    RETURN FALSE;
  END IF;
  v_attempt := v_capture.contactado_attempts;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=v_capture.opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT v_opp.v3_enabled THEN RETURN FALSE; END IF;
  IF p_success THEN
    v_key := 'v3-i24-contacted:' || p_capture_event_id::TEXT;
    INSERT INTO public.lead_routing_events(opportunity_id,event_type,actor_id,idempotency_key,external_evidence)
    VALUES (v_capture.opportunity_id,'i24_contacted',NULL,v_key,
      jsonb_build_object('portal','inmuebles24','i24_lead_id',v_capture.external_event_id,
        'capture_event_id',p_capture_event_id,'attempt',v_attempt))
    ON CONFLICT (idempotency_key) DO NOTHING;
    UPDATE public.i24_capture_events
    SET contactado_status='verified', contactado_lease_token=NULL,
        contactado_lease_expires_at=NULL, contactado_next_attempt_at=NULL,
        contactado_verified_at=p_now, contactado_last_error_code=NULL
    WHERE capture_event_id=p_capture_event_id AND contactado_lease_token=p_lease_token;
    UPDATE public.lead_routing_opportunities
    SET v3_contactado_status='verified', v3_contactado_verified_at=p_now,
        v3_contactado_next_attempt_at=NULL, v3_contactado_last_error=NULL, updated_at=p_now
    WHERE opportunity_id=v_capture.opportunity_id;
    RETURN TRUE;
  END IF;

  v_first_failed := COALESCE(v_capture.contactado_first_failed_at, p_now);
  v_next := CASE v_attempt
    WHEN 1 THEN v_first_failed + INTERVAL '15 minutes'
    WHEN 2 THEN v_first_failed + INTERVAL '30 minutes'
    WHEN 3 THEN v_first_failed + INTERVAL '60 minutes'
    ELSE NULL
  END;
  UPDATE public.i24_capture_events
  SET contactado_status=CASE WHEN v_next IS NULL THEN 'manual_review' ELSE 'failed' END,
      contactado_lease_token=NULL, contactado_lease_expires_at=NULL,
      contactado_first_failed_at=v_first_failed, contactado_next_attempt_at=v_next,
      contactado_last_error_code=NULLIF(BTRIM(p_error_code),'')
  WHERE capture_event_id=p_capture_event_id AND contactado_lease_token=p_lease_token;
  UPDATE public.lead_routing_opportunities
  SET v3_contactado_status=CASE WHEN v_next IS NULL THEN 'manual_review' ELSE 'failed' END,
      v3_contactado_first_failed_at=v_first_failed, v3_contactado_next_attempt_at=v_next,
      v3_contactado_last_error=NULLIF(BTRIM(p_error_code),''), updated_at=p_now
  WHERE opportunity_id=v_capture.opportunity_id;
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,idempotency_key,metadata)
  VALUES (v_capture.opportunity_id, CASE WHEN v_next IS NULL THEN 'i24_contact_manual_review' ELSE 'i24_contact_attempt' END,
    'v3-i24-contact-attempt:' || p_capture_event_id::TEXT || ':' || v_attempt::TEXT,
    jsonb_strip_nulls(jsonb_build_object('attempt',v_attempt,'capture_event_id',p_capture_event_id,
      'error_code',NULLIF(BTRIM(p_error_code),''),'next_attempt_at',v_next)))
  ON CONFLICT (idempotency_key) DO NOTHING;
  RETURN TRUE;
END;
$$;

-- Durable handoff to n8n. Contactado can remove the lead from the next portal
-- scrape, so webhook delivery must not depend on seeing that lead again.
CREATE OR REPLACE FUNCTION public.claim_v3_route_dispatches(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS TABLE(
  capture_event_id BIGINT,
  opportunity_id BIGINT,
  disposition TEXT,
  i24_lead_id TEXT,
  property_public_id TEXT,
  offer_context JSONB,
  lease_token UUID,
  attempt INTEGER
)
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid V3 route dispatch claim input';
  END IF;
  RETURN QUERY
  WITH candidates AS (
    SELECT e.capture_event_id
    FROM public.i24_capture_events e
    JOIN public.lead_routing_opportunities o ON o.opportunity_id=e.opportunity_id
    WHERE o.v3_enabled
      AND e.contactado_status='verified'
      AND e.disposition <> 'non_routable'
      AND e.route_dispatch_status IN ('pending','failed','leased')
      AND (e.route_dispatch_status IN ('pending','failed')
        OR e.route_dispatch_lease_expires_at <= p_now)
      AND COALESCE(e.route_dispatch_next_attempt_at,p_now) <= p_now
    ORDER BY e.route_dispatch_next_attempt_at NULLS FIRST,e.capture_event_id
    FOR UPDATE OF e SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    UPDATE public.i24_capture_events e
    SET route_dispatch_status='leased',
        route_dispatch_lease_token=gen_random_uuid(),
        route_dispatch_lease_expires_at=p_now+INTERVAL '2 minutes',
        route_dispatch_attempts=e.route_dispatch_attempts+1
    FROM candidates c
    WHERE e.capture_event_id=c.capture_event_id
    RETURNING e.*
  )
  SELECT c.capture_event_id,c.opportunity_id,c.disposition,c.external_event_id,
    c.property_public_id,c.offer_context,c.route_dispatch_lease_token,
    c.route_dispatch_attempts
  FROM claimed c;
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_v3_route_dispatch(
  p_capture_event_id BIGINT,
  p_lease_token UUID,
  p_success BOOLEAN,
  p_error_code TEXT DEFAULT NULL,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  e public.i24_capture_events;
  v_first_failed TIMESTAMPTZ;
  v_next TIMESTAMPTZ;
BEGIN
  IF p_capture_event_id IS NULL OR p_lease_token IS NULL OR p_success IS NULL
     OR p_now IS NULL OR LENGTH(COALESCE(p_error_code,'')) > 120 THEN
    RAISE EXCEPTION 'invalid V3 route dispatch finish input';
  END IF;
  SELECT * INTO e FROM public.i24_capture_events
  WHERE capture_event_id=p_capture_event_id FOR UPDATE;
  IF NOT FOUND OR e.route_dispatch_status <> 'leased'
     OR e.route_dispatch_lease_token IS DISTINCT FROM p_lease_token
     OR e.route_dispatch_lease_expires_at <= p_now THEN
    RETURN FALSE;
  END IF;
  IF p_success THEN
    UPDATE public.i24_capture_events
    SET route_dispatch_status='dispatched',route_dispatch_lease_token=NULL,
        route_dispatch_lease_expires_at=NULL,route_dispatch_next_attempt_at=NULL,
        route_dispatch_last_error_code=NULL,route_dispatched_at=p_now
    WHERE capture_event_id=p_capture_event_id;
    INSERT INTO public.lead_routing_events(
      opportunity_id,event_type,idempotency_key,external_evidence
    ) VALUES (
      e.opportunity_id,'route_dispatched','v3-route-dispatched:'||p_capture_event_id::TEXT,
      jsonb_build_object('capture_event_id',p_capture_event_id,'i24_lead_id',e.external_event_id)
    ) ON CONFLICT (idempotency_key) DO NOTHING;
    RETURN TRUE;
  END IF;
  v_first_failed := COALESCE(
    (SELECT occurred_at FROM public.lead_routing_events
     WHERE idempotency_key='v3-route-dispatch-failed:'||p_capture_event_id::TEXT||':1'),
    p_now
  );
  v_next := CASE e.route_dispatch_attempts
    WHEN 1 THEN v_first_failed+INTERVAL '1 minute'
    WHEN 2 THEN v_first_failed+INTERVAL '5 minutes'
    WHEN 3 THEN v_first_failed+INTERVAL '15 minutes'
    WHEN 4 THEN v_first_failed+INTERVAL '30 minutes'
    ELSE NULL END;
  UPDATE public.i24_capture_events
  SET route_dispatch_status=CASE WHEN v_next IS NULL THEN 'manual_review' ELSE 'failed' END,
      route_dispatch_lease_token=NULL,route_dispatch_lease_expires_at=NULL,
      route_dispatch_next_attempt_at=v_next,
      route_dispatch_last_error_code=NULLIF(BTRIM(p_error_code),'')
  WHERE capture_event_id=p_capture_event_id;
  INSERT INTO public.lead_routing_events(
    opportunity_id,event_type,idempotency_key,metadata
  ) VALUES (
    e.opportunity_id,
    CASE WHEN v_next IS NULL THEN 'route_dispatch_manual_review' ELSE 'route_dispatch_failed' END,
    'v3-route-dispatch-failed:'||p_capture_event_id::TEXT||':'||e.route_dispatch_attempts::TEXT,
    jsonb_strip_nulls(jsonb_build_object('capture_event_id',p_capture_event_id,
      'attempt',e.route_dispatch_attempts,'error_code',NULLIF(BTRIM(p_error_code),''),
      'next_attempt_at',v_next))
  ) ON CONFLICT (idempotency_key) DO NOTHING;
  RETURN TRUE;
END;
$$;

-- V3 offer wrapper: binds the explicit capture before the canonical insert.
CREATE OR REPLACE FUNCTION public.v3_request_offer(
  p_capture_event_id BIGINT,
  p_tier TEXT,
  p_client_request_id TEXT,
  p_target_agent_id TEXT,
  p_target_number TEXT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_capture public.i24_capture_events;
  v_attempt_id BIGINT;
BEGIN
  SELECT * INTO v_capture FROM public.i24_capture_events
  WHERE capture_event_id=p_capture_event_id FOR SHARE;
  IF NOT FOUND OR v_capture.contactado_status IS DISTINCT FROM 'verified'
     OR v_capture.disposition IS DISTINCT FROM 'created_new' THEN
    RAISE EXCEPTION 'V3 offer requires verified created capture: %', p_capture_event_id;
  END IF;
  PERFORM set_config('app.v3_capture_event_id',p_capture_event_id::TEXT,true);
  SELECT a.attempt_id INTO v_attempt_id
  FROM public.create_delivery_attempt(
    v_capture.opportunity_id,p_tier,p_client_request_id,p_target_agent_id,p_target_number
  ) a;
  UPDATE public.lead_routing_delivery_attempts
  SET capture_event_id=p_capture_event_id, delivery_kind='offer'
  WHERE attempt_id=v_attempt_id
    AND (capture_event_id IS NULL OR capture_event_id=p_capture_event_id);
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery capture binding collision: %',v_attempt_id; END IF;
  PERFORM set_config('app.v3_capture_event_id','',true);
  RETURN v_attempt_id;
END;
$$;

-- Direct notice wrapper: durable, buttonless, and never changes the auction.
CREATE OR REPLACE FUNCTION public.v3_enqueue_assigned_notice(
  p_capture_event_id BIGINT,
  p_agent_id TEXT,
  p_target_number TEXT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_capture public.i24_capture_events;
  v_opp public.lead_routing_opportunities;
  v_attempt_id BIGINT;
  v_request TEXT;
BEGIN
  SELECT * INTO v_capture FROM public.i24_capture_events
  WHERE capture_event_id=p_capture_event_id FOR SHARE;
  IF NOT FOUND OR v_capture.contactado_status IS DISTINCT FROM 'verified' THEN
    RAISE EXCEPTION 'assigned notice requires verified capture: %',p_capture_event_id;
  END IF;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=v_capture.opportunity_id FOR SHARE;
  IF NOT FOUND OR v_opp.assigned_agent_id IS DISTINCT FROM p_agent_id THEN
    RAISE EXCEPTION 'assigned notice target is not responsible agent';
  END IF;
  v_request := 'v3:assigned-notice:'||p_capture_event_id::TEXT;
  PERFORM set_config('app.v3_capture_event_id',p_capture_event_id::TEXT,true);
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,actor_id,idempotency_key,metadata)
  VALUES(v_opp.opportunity_id,'assigned_notice_requested',p_agent_id,v_request,
    jsonb_build_object('capture_event_id',p_capture_event_id,'template','lead_asignado_v3','button',FALSE))
  ON CONFLICT (idempotency_key) DO NOTHING;
  INSERT INTO public.lead_routing_delivery_attempts(
    opportunity_id,capture_event_id,delivery_kind,routing_tier,client_request_id,
    target_agent_id,target_number,claimed_at,lease_expires_at,lease_token
  ) VALUES (
    v_opp.opportunity_id,p_capture_event_id,'assigned_notice',NULL,v_request,
    p_agent_id,p_target_number,NOW(),NOW()+INTERVAL '2 minutes',gen_random_uuid()::TEXT
  ) ON CONFLICT (client_request_id) DO NOTHING
  RETURNING attempt_id INTO v_attempt_id;
  IF v_attempt_id IS NULL THEN
    SELECT attempt_id INTO v_attempt_id FROM public.lead_routing_delivery_attempts
    WHERE client_request_id=v_request AND opportunity_id=v_opp.opportunity_id
      AND capture_event_id=p_capture_event_id AND delivery_kind='assigned_notice';
    IF NOT FOUND THEN RAISE EXCEPTION 'assigned notice idempotency collision'; END IF;
  END IF;
  PERFORM set_config('app.v3_capture_event_id','',true);
  RETURN v_attempt_id;
END;
$$;

-- Atomic Sandy fallback. Assignment does not depend on WhatsApp notification success.
CREATE OR REPLACE FUNCTION public.v3_assign_sandy(
  p_opportunity_id BIGINT,
  p_reason TEXT,
  p_capture_event_id BIGINT DEFAULT NULL,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS public.lead_routing_opportunities
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE v_opp public.lead_routing_opportunities; v_sandy public.agents;
BEGIN
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT v_opp.v3_enabled THEN RAISE EXCEPTION 'V3 opportunity unavailable'; END IF;
  SELECT * INTO v_sandy FROM public.agents
  WHERE agent_id='agent_manager' AND role='manager';
  IF NOT FOUND THEN RAISE EXCEPTION 'stable Sandy agent_id is unavailable'; END IF;
  IF v_opp.assigned_agent_id IS NULL THEN
    UPDATE public.lead_routing_opportunities
    SET state='assigned', routing_tier=NULL, assigned_agent_id=v_sandy.agent_id,
        assigned_at=COALESCE(assigned_at,p_now), updated_at=p_now,
        external_evidence=COALESCE(external_evidence,'{}'::JSONB)
          || jsonb_build_object('v3_final_route','sandy','reason',LEFT(COALESCE(p_reason,'fallback'),120))
    WHERE opportunity_id=p_opportunity_id AND assigned_agent_id IS NULL
    RETURNING * INTO v_opp;
    IF v_opp.conversation_id IS NOT NULL THEN
      UPDATE public.conversations SET assigned_agent_id=v_sandy.agent_id,
        assigned_at=COALESCE(assigned_at,p_now), assignment_method='manager_escalation',
        claimed_via='v3_manager_fallback', routing_tier='manager', mode='ai'
      WHERE conversation_id=v_opp.conversation_id AND assigned_agent_id IS NULL;
    END IF;
    INSERT INTO public.lead_routing_events(opportunity_id,event_type,actor_id,idempotency_key,metadata)
    VALUES(p_opportunity_id,'manager_assigned',v_sandy.agent_id,
      'v3-sandy-assigned:'||p_opportunity_id::TEXT,
      jsonb_build_object('reason',LEFT(COALESCE(p_reason,'fallback'),120)))
    ON CONFLICT (idempotency_key) DO NOTHING;
    IF p_capture_event_id IS NOT NULL THEN
      PERFORM public.v3_enqueue_assigned_notice(p_capture_event_id,v_sandy.agent_id,v_sandy.whatsapp_number);
    END IF;
  END IF;
  RETURN v_opp;
END;
$$;

-- Owner/one-guard routing. No backup tier exists in V3.
CREATE OR REPLACE FUNCTION public.v3_route_ready_opportunity(
  p_opportunity_id BIGINT,
  p_capture_event_id BIGINT,
  p_property_tags TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_owner RECORD;
  v_guard RECORD;
  v_attempt_id BIGINT;
  v_owner_resolved BOOLEAN := FALSE;
  v_owner_agent_id TEXT;
  v_owner_number TEXT;
  v_guard_found BOOLEAN := FALSE;
  v_capture_status TEXT;
  v_capture_disposition TEXT;
  v_is_night BOOLEAN;
BEGIN
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT v_opp.v3_enabled THEN RAISE EXCEPTION 'V3 opportunity unavailable'; END IF;
  SELECT e.contactado_status, e.disposition
    INTO v_capture_status, v_capture_disposition
  FROM public.i24_capture_events e
  WHERE e.capture_event_id=p_capture_event_id AND e.opportunity_id=p_opportunity_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'capture event does not belong to opportunity';
  END IF;
  IF v_capture_status IS DISTINCT FROM 'verified' THEN
    RETURN jsonb_build_object('state','blocked','reason','contactado_not_verified','opportunity_id',p_opportunity_id);
  END IF;
  IF v_capture_disposition <> 'created_new' THEN
    IF v_capture_disposition='active_duplicate' THEN
      RETURN jsonb_build_object('state','no_action','disposition','active_duplicate',
        'opportunity_id',p_opportunity_id,'capture_event_id',p_capture_event_id);
    END IF;
    IF v_capture_disposition='returning_assigned' THEN
      SELECT a.whatsapp_number INTO v_owner_number FROM public.agents a
      WHERE a.agent_id=v_opp.assigned_agent_id;
      v_attempt_id := public.v3_enqueue_assigned_notice(p_capture_event_id,
        v_opp.assigned_agent_id,v_owner_number);
      RETURN jsonb_build_object('state','direct_assigned','disposition','returning_assigned',
        'assigned_agent_id',v_opp.assigned_agent_id,'attempt_id',v_attempt_id,
        'capture_event_id',p_capture_event_id);
    END IF;
    RETURN jsonb_build_object('state','no_action','disposition',v_capture_disposition,
      'opportunity_id',p_opportunity_id);
  END IF;
  v_is_night := ((p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '20:00:00'
    OR (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '08:00:00');
  IF v_is_night OR v_opp.state='queued_night' THEN
    UPDATE public.lead_routing_opportunities SET state='queued_night', v3_night_queued_at=COALESCE(v3_night_queued_at,p_now), updated_at=p_now
    WHERE opportunity_id=p_opportunity_id AND assigned_agent_id IS NULL;
    RETURN jsonb_build_object('state','night_queued','opportunity_id',p_opportunity_id,'release_at','08:05 America/Mexico_City');
  END IF;
  IF v_opp.assigned_agent_id IS NOT NULL OR v_opp.state IN ('closed_won','closed_lost') THEN
    RETURN jsonb_build_object('state',v_opp.state,'disposition','returning_assigned','opportunity_id',p_opportunity_id);
  END IF;

  IF v_opp.property_id IS NOT NULL AND COALESCE(CARDINALITY(p_property_tags),0)=1 THEN
    SELECT * INTO v_owner FROM public.resolve_first_property_tag(v_opp.property_id,p_property_tags) LIMIT 1;
    IF FOUND THEN
      v_owner_resolved := COALESCE(v_owner.resolved,FALSE);
      IF v_owner_resolved THEN
        v_owner_agent_id := v_owner.owner_agent_id;
        v_owner_number := v_owner.owner_number;
      END IF;
    END IF;
    -- The legacy resolver excludes managers, but the V3 contract explicitly
    -- permits Sandy as the owner when the unique property tag maps to her
    -- stable agent_id. Keep this exception exact and phone-validated.
    IF NOT v_owner_resolved THEN
      SELECT a.agent_id,
             regexp_replace(btrim(a.whatsapp_number), '[ +()-]', '', 'g')
        INTO v_owner_agent_id, v_owner_number
      FROM public.property_agent_alias alias
      JOIN public.agents a ON a.agent_id=alias.agent_id
      WHERE alias.tag_normalized=LOWER(BTRIM(p_property_tags[1]))
        AND a.agent_id='agent_manager' AND a.role='manager' AND a.is_available
        AND btrim(a.whatsapp_number) ~ '^[+]?[1-9][0-9 ()-]{6,13}[0-9]$'
        AND regexp_replace(btrim(a.whatsapp_number), '[ +()-]', '', 'g') ~ '^[1-9][0-9]{7,14}$';
      IF FOUND THEN v_owner_resolved := TRUE; END IF;
    END IF;
  END IF;
  IF v_owner_resolved THEN
    UPDATE public.lead_routing_opportunities SET state='resolved', routing_tier=NULL, updated_at=p_now
    WHERE opportunity_id=p_opportunity_id AND state IN ('captured','queued_night','resolved');
    v_attempt_id := public.v3_request_offer(p_capture_event_id,'owner',
      'v3:owner:'||p_opportunity_id::TEXT||':'||p_capture_event_id::TEXT,
      v_owner_agent_id,v_owner_number);
    RETURN jsonb_build_object('state','owner_delivery_requested','tier','owner','attempt_id',v_attempt_id,'opportunity_id',p_opportunity_id,'capture_event_id',p_capture_event_id);
  END IF;

  SELECT * INTO v_guard FROM public.get_guard_coverage_slots(
    (p_now AT TIME ZONE 'America/Mexico_City')::DATE,
    CASE
      WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '08:00:00'
       AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '14:00:00' THEN 'morning'
      WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '14:00:00'
       AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '20:00:00' THEN 'afternoon'
      ELSE 'night'
    END
  ) WHERE coverage_role='primary' LIMIT 1;
  v_guard_found := FOUND;
  IF NOT v_guard_found THEN
    PERFORM public.v3_assign_sandy(p_opportunity_id,'guard_unavailable',p_capture_event_id,p_now);
    RETURN jsonb_build_object('state','assigned','tier','sandy','opportunity_id',p_opportunity_id);
  END IF;
  UPDATE public.lead_routing_opportunities SET state='guard_delivery_pending', routing_tier='primary_guard', updated_at=p_now
  WHERE opportunity_id=p_opportunity_id AND assigned_agent_id IS NULL;
  v_attempt_id := public.v3_request_offer(p_capture_event_id,'primary_guard',
    'v3:guard:'||p_opportunity_id::TEXT||':'||p_capture_event_id::TEXT,
    v_guard.agent_id,v_guard.whatsapp_number);
  RETURN jsonb_build_object('state','guard_delivery_requested','tier','primary_guard','attempt_id',v_attempt_id,'opportunity_id',p_opportunity_id,'capture_event_id',p_capture_event_id);
END;
$$;

-- Delivery worker claim is offer-only; assigned notices use their own kind.
CREATE OR REPLACE FUNCTION public.v3_claim_delivery_attempts(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS SETOF public.lead_routing_delivery_attempts
LANGUAGE sql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
  WITH candidates AS (
    SELECT a.attempt_id
    FROM public.lead_routing_delivery_attempts a
    WHERE a.delivery_kind='offer' AND a.status='requested'
      AND (a.lease_expires_at IS NULL OR a.lease_expires_at<=p_now)
    ORDER BY a.requested_at,a.attempt_id
    FOR UPDATE SKIP LOCKED LIMIT p_limit
  )
  UPDATE public.lead_routing_delivery_attempts a
  SET claimed_at=p_now, lease_expires_at=p_now+INTERVAL '2 minutes',
      lease_token=gen_random_uuid()::TEXT
  FROM candidates c WHERE a.attempt_id=c.attempt_id
  RETURNING a.*;
$$;

CREATE OR REPLACE FUNCTION public.v3_record_provider_accepted(
  p_attempt_id BIGINT,
  p_provider_message_id TEXT,
  p_lease_token TEXT,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE v_attempt public.lead_routing_delivery_attempts;
BEGIN
  IF p_attempt_id IS NULL OR NULLIF(BTRIM(p_provider_message_id),'') IS NULL
     OR NULLIF(BTRIM(p_lease_token),'') IS NULL OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid provider acceptance input';
  END IF;
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts
  WHERE attempt_id=p_attempt_id FOR UPDATE;
  IF NOT FOUND OR v_attempt.lease_token IS DISTINCT FROM p_lease_token
     OR v_attempt.lease_expires_at <= p_now THEN
    RETURN FALSE;
  END IF;
  UPDATE public.lead_routing_delivery_attempts
  SET provider_message_id=COALESCE(provider_message_id,p_provider_message_id),
      provider_accepted_at=COALESCE(provider_accepted_at,p_now),
      status=CASE WHEN status='requested' THEN 'sent' ELSE status END,
      bound_at=COALESCE(bound_at,p_now)
  WHERE attempt_id=p_attempt_id
    AND (provider_message_id IS NULL OR provider_message_id=p_provider_message_id);
  RETURN FOUND;
END;
$$;

-- A read callback can prove delivery when delivered was lost, but never extends
-- an already-established business deadline.
CREATE OR REPLACE FUNCTION public.v3_record_read_delivery(
  p_provider_message_id TEXT,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE v_attempt public.lead_routing_delivery_attempts; v_opp public.lead_routing_opportunities;
BEGIN
  IF NULLIF(BTRIM(p_provider_message_id),'') IS NULL OR p_now IS NULL THEN RAISE EXCEPTION 'invalid read callback'; END IF;
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts
  WHERE provider_message_id=BTRIM(p_provider_message_id) FOR UPDATE;
  IF NOT FOUND THEN RETURN FALSE; END IF;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities
  WHERE opportunity_id=v_attempt.opportunity_id FOR UPDATE;
  IF v_opp.v3_enabled AND v_opp.assigned_agent_id IS NULL THEN
    INSERT INTO public.lead_routing_events(opportunity_id,event_type,idempotency_key,external_evidence)
    VALUES(v_attempt.opportunity_id,'delivery_confirmed','v3-delivery-read:'||BTRIM(p_provider_message_id),
      jsonb_build_object('provider_message_id',BTRIM(p_provider_message_id),'status','read'))
    ON CONFLICT (idempotency_key) DO NOTHING;
    UPDATE public.lead_routing_delivery_attempts
    SET status='delivered', delivered_at=COALESCE(delivered_at,p_now)
    WHERE attempt_id=v_attempt.attempt_id;
    UPDATE public.lead_routing_opportunities
    SET state=CASE v_attempt.routing_tier WHEN 'owner' THEN 'owner_open' ELSE 'primary_guard_open' END,
        delivery_status='delivered', delivered_at=COALESCE(delivered_at,p_now),
        expires_at=COALESCE(expires_at, v_attempt.delivered_at + INTERVAL '5 minutes', p_now+INTERVAL '5 minutes'), updated_at=p_now
    WHERE opportunity_id=v_opp.opportunity_id AND assigned_agent_id IS NULL;
  END IF;
  RETURN TRUE;
END;
$$;

-- One transition after an owner/guard deadline. Owner==guard skips a second
-- offer; a missing guard falls directly to the stable Sandy agent_id.
CREATE OR REPLACE FUNCTION public.v3_advance_routing_tier(
  p_opportunity_id BIGINT,
  p_expected_tier TEXT,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_attempt public.lead_routing_delivery_attempts;
  v_guard RECORD;
  v_guard_found BOOLEAN := FALSE;
  v_attempt_id BIGINT;
BEGIN
  IF p_expected_tier NOT IN ('owner','primary_guard') OR p_now IS NULL THEN RAISE EXCEPTION 'invalid V3 routing transition'; END IF;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities WHERE opportunity_id=p_opportunity_id FOR UPDATE;
  IF NOT FOUND OR NOT v_opp.v3_enabled OR v_opp.assigned_agent_id IS NOT NULL THEN
    RETURN jsonb_build_object('state',COALESCE(v_opp.state,'missing'),'opportunity_id',p_opportunity_id);
  END IF;
  IF v_opp.current_delivery_attempt_id IS NOT NULL THEN
    SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts WHERE attempt_id=v_opp.current_delivery_attempt_id FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('state','missing_delivery_attempt','opportunity_id',p_opportunity_id);
    END IF;
  ELSE
    RETURN jsonb_build_object('state','missing_delivery_attempt','opportunity_id',p_opportunity_id);
  END IF;
  IF v_attempt.capture_event_id IS NULL THEN
    RETURN jsonb_build_object('state','missing_capture_context','opportunity_id',p_opportunity_id);
  END IF;
  IF v_attempt.delivered_at IS NOT NULL THEN
    -- Repair a partial callback atomically; a missing deadline must not leave
    -- the opportunity open forever after a restart.
    IF v_opp.expires_at IS NULL THEN
      UPDATE public.lead_routing_opportunities
      SET expires_at=v_attempt.delivered_at+INTERVAL '5 minutes', updated_at=p_now
      WHERE opportunity_id=p_opportunity_id AND expires_at IS NULL;
      v_opp.expires_at := v_attempt.delivered_at+INTERVAL '5 minutes';
    END IF;
    IF v_opp.expires_at>p_now THEN
      RETURN jsonb_build_object('state','open','opportunity_id',p_opportunity_id);
    END IF;
  END IF;
  IF v_attempt.delivered_at IS NULL AND COALESCE(v_attempt.provider_accepted_at,v_attempt.requested_at)+INTERVAL '2 minutes'>p_now THEN
    RETURN jsonb_build_object('state','awaiting_delivery_timeout','opportunity_id',p_opportunity_id);
  END IF;
  IF p_expected_tier='owner' THEN
    SELECT * INTO v_guard FROM public.get_guard_coverage_slots(
      (p_now AT TIME ZONE 'America/Mexico_City')::DATE,
      CASE
        WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '08:00:00'
         AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '14:00:00' THEN 'morning'
        WHEN (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '14:00:00'
         AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '20:00:00' THEN 'afternoon'
        ELSE 'night'
      END
    ) WHERE coverage_role='primary' LIMIT 1;
    v_guard_found := FOUND;
    IF NOT v_guard_found OR v_guard.agent_id IS NOT DISTINCT FROM v_attempt.target_agent_id THEN
      PERFORM public.v3_assign_sandy(p_opportunity_id,CASE WHEN NOT v_guard_found THEN 'guard_unavailable' ELSE 'owner_equals_guard' END,v_attempt.capture_event_id,p_now);
      RETURN jsonb_build_object('state','assigned','tier','sandy','opportunity_id',p_opportunity_id);
    END IF;
    UPDATE public.lead_routing_opportunities SET state='guard_delivery_pending',routing_tier='primary_guard',delivery_status=NULL,current_delivery_attempt_id=NULL,delivered_at=NULL,expires_at=NULL,updated_at=p_now WHERE opportunity_id=p_opportunity_id;
    v_attempt_id := public.v3_request_offer(v_attempt.capture_event_id,'primary_guard',
      'v3:guard:'||p_opportunity_id::TEXT||':'||v_attempt.capture_event_id::TEXT,
      v_guard.agent_id,v_guard.whatsapp_number);
    RETURN jsonb_build_object('state','guard_delivery_requested','tier','primary_guard','attempt_id',v_attempt_id,'opportunity_id',p_opportunity_id,'capture_event_id',v_attempt.capture_event_id);
  END IF;
  PERFORM public.v3_assign_sandy(p_opportunity_id,'guard_expired',v_attempt.capture_event_id,p_now);
  RETURN jsonb_build_object('state','assigned','tier','sandy','opportunity_id',p_opportunity_id);
END;
$$;

-- Release is the only V3 night activation path and is gated at 08:05 CDMX.
CREATE OR REPLACE FUNCTION public.v3_release_night_queue(
  p_limit INTEGER DEFAULT 100,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS SETOF BIGINT
LANGUAGE sql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
  WITH candidates AS (
    SELECT o.opportunity_id
    FROM public.lead_routing_opportunities o
    WHERE o.v3_enabled AND o.state='queued_night' AND o.assigned_agent_id IS NULL
      AND p_now IS NOT NULL
      AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME >= TIME '08:05:00'
      AND (p_now AT TIME ZONE 'America/Mexico_City')::TIME < TIME '20:00:00'
    ORDER BY o.v3_night_queued_at, o.opportunity_id
    FOR UPDATE SKIP LOCKED
    LIMIT p_limit
  ), released AS (
    UPDATE public.lead_routing_opportunities o
    SET state='captured', v3_night_released_at=p_now, updated_at=p_now
    FROM candidates c
    WHERE o.opportunity_id = c.opportunity_id
    RETURNING o.opportunity_id
  ) SELECT opportunity_id FROM released;
$$;

REVOKE ALL ON FUNCTION public.v3_intake(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB,TIMESTAMPTZ),
  public.claim_v3_i24_contact_effects(INTEGER,TIMESTAMPTZ),
  public.finish_v3_i24_contact_effect(BIGINT,UUID,BOOLEAN,TEXT,TIMESTAMPTZ),
  public.claim_v3_route_dispatches(INTEGER,TIMESTAMPTZ),
  public.finish_v3_route_dispatch(BIGINT,UUID,BOOLEAN,TEXT,TIMESTAMPTZ),
  public.v3_request_offer(BIGINT,TEXT,TEXT,TEXT,TEXT),
  public.v3_enqueue_assigned_notice(BIGINT,TEXT,TEXT),
  public.v3_claim_delivery_attempts(INTEGER,TIMESTAMPTZ),
  public.v3_assign_sandy(BIGINT,TEXT,BIGINT,TIMESTAMPTZ),
  public.v3_route_ready_opportunity(BIGINT,BIGINT,TEXT[],TIMESTAMPTZ),
  public.v3_record_provider_accepted(BIGINT,TEXT,TEXT,TIMESTAMPTZ),
  public.v3_record_read_delivery(TEXT,TIMESTAMPTZ),
  public.v3_advance_routing_tier(BIGINT,TEXT,TIMESTAMPTZ),
  public.v3_release_night_queue(INTEGER,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.v3_intake(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,JSONB,TIMESTAMPTZ),
  public.claim_v3_i24_contact_effects(INTEGER,TIMESTAMPTZ),
  public.finish_v3_i24_contact_effect(BIGINT,UUID,BOOLEAN,TEXT,TIMESTAMPTZ),
  public.claim_v3_route_dispatches(INTEGER,TIMESTAMPTZ),
  public.finish_v3_route_dispatch(BIGINT,UUID,BOOLEAN,TEXT,TIMESTAMPTZ),
  public.v3_request_offer(BIGINT,TEXT,TEXT,TEXT,TEXT),
  public.v3_enqueue_assigned_notice(BIGINT,TEXT,TEXT),
  public.v3_claim_delivery_attempts(INTEGER,TIMESTAMPTZ),
  public.v3_assign_sandy(BIGINT,TEXT,BIGINT,TIMESTAMPTZ),
  public.v3_route_ready_opportunity(BIGINT,BIGINT,TEXT[],TIMESTAMPTZ),
  public.v3_record_provider_accepted(BIGINT,TEXT,TEXT,TIMESTAMPTZ),
  public.v3_record_read_delivery(TEXT,TIMESTAMPTZ),
  public.v3_advance_routing_tier(BIGINT,TEXT,TIMESTAMPTZ),
  public.v3_release_night_queue(INTEGER,TIMESTAMPTZ)
  TO service_role;

-- Identity sequence created by the optional capture table needs service_role usage.
REVOKE ALL ON SEQUENCE public.i24_capture_events_capture_event_id_seq FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.i24_capture_events_capture_event_id_seq TO service_role;
