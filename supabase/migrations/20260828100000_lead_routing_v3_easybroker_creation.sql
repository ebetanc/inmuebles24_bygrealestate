-- V3-08: durable, one-shot I24 -> EasyBroker contact-request creation.
-- This migration is forward-only. The API client owns the external POST;
-- this ledger owns the authorization, lease and outcome so a timeout/5xx is
-- recovered by GET/reconciliation and is never blindly re-posted.

CREATE TABLE IF NOT EXISTS public.easybroker_contact_request_creation_ledger (
  capture_event_id BIGINT PRIMARY KEY
    REFERENCES public.i24_capture_events(capture_event_id),
  account_key TEXT NOT NULL,
  external_event_id TEXT NOT NULL,
  i24_lead_id TEXT NOT NULL,
  opportunity_id BIGINT NOT NULL
    REFERENCES public.lead_routing_opportunities(opportunity_id),
  property_public_id TEXT NOT NULL
    CHECK (property_public_id ~ '^EB-[A-Z0-9]{4,}$'),
  state TEXT NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending','recovery','created','manual_review')),
  post_attempt_count INTEGER NOT NULL DEFAULT 0
    CHECK (post_attempt_count BETWEEN 0 AND 1),
  post_attempted_at TIMESTAMPTZ,
  remote_request_id BIGINT UNIQUE,
  lease_token UUID,
  lease_expires_at TIMESTAMPTZ,
  response_evidence JSONB NOT NULL DEFAULT '{}'::JSONB,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL)),
  CHECK (NULLIF(BTRIM(external_event_id), '') IS NOT NULL),
  CHECK (external_event_id = i24_lead_id),
  CHECK (post_attempt_count = 0 OR post_attempted_at IS NOT NULL),
  CHECK (state <> 'created' OR remote_request_id IS NOT NULL),
  CHECK (state <> 'manual_review' OR last_error IS NOT NULL)
);

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='easybroker_creation_lead_uniq'
      AND conrelid='public.easybroker_contact_request_creation_ledger'::regclass
  ) THEN
    ALTER TABLE public.easybroker_contact_request_creation_ledger
      ADD CONSTRAINT easybroker_creation_lead_uniq UNIQUE (account_key, i24_lead_id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS easybroker_creation_due_idx
  ON public.easybroker_contact_request_creation_ledger(state, updated_at, capture_event_id)
  WHERE state IN ('pending','recovery');

ALTER TABLE public.easybroker_contact_request_creation_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.easybroker_contact_request_creation_ledger
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.easybroker_contact_request_creation_ledger
  TO service_role;

CREATE OR REPLACE FUNCTION public.claim_v3_easybroker_request_creations(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW(),
  p_lease_duration INTERVAL DEFAULT INTERVAL '2 minutes'
) RETURNS TABLE(
  capture_event_id BIGINT,
  opportunity_id BIGINT,
  i24_lead_id TEXT,
  property_public_id TEXT,
  offer_context JSONB,
  normalized_email TEXT,
  e164_phone TEXT,
  correlation_window_start_at TIMESTAMPTZ,
  correlation_horizon_at TIMESTAMPTZ,
  remote_request_id BIGINT,
  lease_token UUID,
  lease_expires_at TIMESTAMPTZ,
  post_allowed BOOLEAN
)
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200
     OR p_now IS NULL OR p_lease_duration IS NULL
     OR p_lease_duration <= INTERVAL '0'
     OR p_lease_duration > INTERVAL '15 minutes' THEN
    RAISE EXCEPTION 'invalid EasyBroker creation lease input';
  END IF;

  -- The INSERT is the durable outbox reservation. The explicit cut keeps the
  -- user-authorized repair bounded to 107/108 plus genuinely newer captures.
  INSERT INTO public.easybroker_contact_request_creation_ledger(
    capture_event_id, account_key, external_event_id, i24_lead_id,
    opportunity_id, property_public_id
  )
  SELECT e.capture_event_id, e.account_key, e.external_event_id,
         e.external_event_id, e.opportunity_id,
         UPPER(BTRIM(e.property_public_id))
  FROM public.i24_capture_events e
  JOIN public.lead_routing_opportunities o ON o.opportunity_id=e.opportunity_id
  JOIN public.agents a ON a.agent_id=o.assigned_agent_id
    WHERE (e.capture_event_id IN (107,108)
         OR e.happened_at >= TIMESTAMPTZ '2026-08-28T17:00:05.020Z')
    AND e.disposition='created_new'
    AND e.contactado_status='verified'
    AND e.route_dispatch_status='dispatched'
    AND o.v3_enabled
    AND o.state IN ('assigned','closed_won')
    AND o.assigned_agent_id IS NOT NULL
    AND NULLIF(BTRIM(a.name),'') IS NOT NULL
    AND NULLIF(BTRIM(e.property_public_id),'') IS NOT NULL
    AND UPPER(BTRIM(e.property_public_id)) ~ '^EB-[A-Z0-9]{4,}$'
    AND (e.normalized_email IS NOT NULL OR e.e164_phone IS NOT NULL)
    AND NULLIF(BTRIM(e.external_event_id),'') IS NOT NULL
    AND NULLIF(BTRIM(COALESCE(e.offer_context->>'name', e.offer_context->>'lead_name')),'') IS NOT NULL
  ON CONFLICT ON CONSTRAINT easybroker_creation_lead_uniq DO NOTHING;

  RETURN QUERY
  WITH candidates AS (
    SELECT l.capture_event_id
    FROM public.easybroker_contact_request_creation_ledger l
    JOIN public.i24_capture_events e ON e.capture_event_id=l.capture_event_id
    WHERE l.state IN ('pending','recovery')
      AND (l.lease_expires_at IS NULL OR l.lease_expires_at <= p_now)
    ORDER BY l.capture_event_id
    FOR UPDATE OF l SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    UPDATE public.easybroker_contact_request_creation_ledger l
    SET lease_token=gen_random_uuid(),
        lease_expires_at=p_now+p_lease_duration, updated_at=p_now
    FROM candidates c
    WHERE l.capture_event_id=c.capture_event_id
    RETURNING l.*
  )
  SELECT l.capture_event_id, l.opportunity_id, e.external_event_id,
         l.property_public_id, e.offer_context, e.normalized_email,
         e.e164_phone, e.correlation_window_start_at,
         e.correlation_horizon_at, l.remote_request_id, l.lease_token, l.lease_expires_at,
         l.post_attempt_count=0
  FROM claimed l
  JOIN public.i24_capture_events e ON e.capture_event_id=l.capture_event_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.reserve_v3_easybroker_request_creation(
  p_capture_event_id BIGINT,
  p_lease_token UUID,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE r public.easybroker_contact_request_creation_ledger;
BEGIN
  IF p_capture_event_id IS NULL OR p_lease_token IS NULL OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid EasyBroker creation reservation input';
  END IF;
  SELECT * INTO r
  FROM public.easybroker_contact_request_creation_ledger
  WHERE capture_event_id=p_capture_event_id FOR UPDATE;
  IF NOT FOUND OR r.state NOT IN ('pending','recovery') OR r.lease_token IS DISTINCT FROM p_lease_token
     OR r.lease_expires_at IS NULL OR r.lease_expires_at <= p_now THEN
    RETURN jsonb_build_object('ok',FALSE,'state','lease_conflict','post_allowed',FALSE);
  END IF;
  IF r.post_attempt_count=1 THEN
    RETURN jsonb_build_object('ok',TRUE,'state','recovery','post_allowed',FALSE);
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.easybroker_i24_request_links l
    WHERE l.i24_capture_event_id = p_capture_event_id
  ) THEN
    RETURN jsonb_build_object('ok',TRUE,'state','already_linked','post_allowed',FALSE);
  END IF;
  UPDATE public.easybroker_contact_request_creation_ledger
  SET post_attempt_count=1, post_attempted_at=p_now, updated_at=p_now
  WHERE capture_event_id=p_capture_event_id;
  RETURN jsonb_build_object('ok',TRUE,'state','reserved','post_allowed',TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_v3_easybroker_request_creation(
  p_capture_event_id BIGINT,
  p_lease_token UUID,
  p_state TEXT,
  p_remote_request_id BIGINT DEFAULT NULL,
  p_evidence JSONB DEFAULT '{}'::JSONB,
  p_error TEXT DEFAULT NULL,
  p_preexisting BOOLEAN DEFAULT FALSE,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE r public.easybroker_contact_request_creation_ledger;
BEGIN
  IF p_capture_event_id IS NULL OR p_lease_token IS NULL OR p_now IS NULL
     OR p_preexisting IS NULL
     OR p_state NOT IN ('created','recovery','manual_review')
     OR length(COALESCE(p_error,'')) > 120
     OR (p_state='created' AND (p_remote_request_id IS NULL OR NOT p_preexisting
         OR p_evidence->>'correlation_state' NOT IN ('linked','already_linked')))
     OR (p_state='manual_review' AND NULLIF(BTRIM(p_error),'') IS NULL) THEN
    RAISE EXCEPTION 'invalid EasyBroker creation result';
  END IF;
  SELECT * INTO r
  FROM public.easybroker_contact_request_creation_ledger
  WHERE capture_event_id=p_capture_event_id FOR UPDATE;
  IF NOT FOUND OR r.state NOT IN ('pending','recovery') OR r.lease_token IS DISTINCT FROM p_lease_token
     OR r.lease_expires_at IS NULL OR r.lease_expires_at <= p_now THEN
    RETURN jsonb_build_object('ok',FALSE,'state','lease_conflict',
      'capture_event_id',p_capture_event_id);
  END IF;
  UPDATE public.easybroker_contact_request_creation_ledger
  SET state=p_state, remote_request_id=COALESCE(p_remote_request_id,remote_request_id),
      response_evidence=COALESCE(p_evidence,'{}'::JSONB),
      last_error=NULLIF(BTRIM(p_error),''), lease_token=NULL,
      lease_expires_at=NULL, updated_at=p_now
  WHERE capture_event_id=p_capture_event_id;
  RETURN jsonb_build_object('ok',TRUE,'state',p_state,
    'capture_event_id',p_capture_event_id,
    'remote_request_id',p_remote_request_id,'changed_at',p_now);
END;
$$;

DROP FUNCTION IF EXISTS public.finish_v3_easybroker_request_creation(BIGINT,UUID,TEXT,BIGINT,JSONB,TEXT,TIMESTAMPTZ);

REVOKE ALL ON FUNCTION public.claim_v3_easybroker_request_creations(INTEGER,TIMESTAMPTZ,INTERVAL),
  public.reserve_v3_easybroker_request_creation(BIGINT,UUID,TIMESTAMPTZ),
  public.finish_v3_easybroker_request_creation(BIGINT,UUID,TEXT,BIGINT,JSONB,TEXT,BOOLEAN,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_v3_easybroker_request_creations(INTEGER,TIMESTAMPTZ,INTERVAL),
  public.reserve_v3_easybroker_request_creation(BIGINT,UUID,TIMESTAMPTZ),
  public.finish_v3_easybroker_request_creation(BIGINT,UUID,TEXT,BIGINT,JSONB,TEXT,BOOLEAN,TIMESTAMPTZ)
  TO service_role;
