-- 0023_routing_business_time.sql
-- Regla unica CDMX: captura silenciosa 20:00-08:00 y drenado desde 08:05.
-- Rollback de emergencia (runbook aprobado): restaurar funciones de 0005 y retirar
-- drain_night_queue(); las columnas aditivas pueden permanecer sin uso.

CREATE OR REPLACE FUNCTION public.is_daytime_at(p_at TIMESTAMPTZ)
RETURNS BOOLEAN AS $$
DECLARE
  cdmx_time TIME;
BEGIN
  cdmx_time := (p_at AT TIME ZONE 'America/Mexico_City')::TIME;
  RETURN cdmx_time >= TIME '08:00:00' AND cdmx_time < TIME '20:00:00';
END;
$$ LANGUAGE plpgsql IMMUTABLE SECURITY INVOKER SET search_path = pg_catalog;

CREATE OR REPLACE FUNCTION public.is_daytime()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN public.is_daytime_at(NOW());
END;
$$ LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog;

CREATE OR REPLACE FUNCTION public.current_shift()
RETURNS TEXT AS $$
DECLARE
  cdmx_time TIME;
BEGIN
  cdmx_time := (NOW() AT TIME ZONE 'America/Mexico_City')::TIME;
  IF cdmx_time >= TIME '08:00:00' AND cdmx_time < TIME '14:00:00' THEN
    RETURN 'morning';
  ELSIF cdmx_time >= TIME '14:00:00' AND cdmx_time < TIME '20:00:00' THEN
    RETURN 'afternoon';
  END IF;
  RETURN 'night';
END;
$$ LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog;

COMMENT ON FUNCTION public.is_daytime_at(TIMESTAMPTZ) IS
  'Canonical CDMX business window: [08:00, 20:00).';
COMMENT ON FUNCTION public.is_daytime() IS
  'TRUE from 08:00:00 through 19:59:59 CDMX; delegates to is_daytime_at().';
COMMENT ON FUNCTION public.current_shift() IS
  'Current CDMX shift; afternoon ends at 20:00, when silent capture begins.';

ALTER TABLE public.night_queue
  ADD COLUMN IF NOT EXISTS opportunity_id BIGINT
    REFERENCES public.lead_routing_opportunities(opportunity_id);
ALTER TABLE public.night_queue
  ADD COLUMN IF NOT EXISTS processing_status TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE public.night_queue
  ADD COLUMN IF NOT EXISTS lease_token UUID;
ALTER TABLE public.night_queue
  ADD COLUMN IF NOT EXISTS lease_expires_at TIMESTAMPTZ;
ALTER TABLE public.night_queue
  ADD COLUMN IF NOT EXISTS processing_attempts INTEGER NOT NULL DEFAULT 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'night_queue_processing_status_check'
      AND conrelid = 'public.night_queue'::regclass
  ) THEN
    ALTER TABLE public.night_queue
      ADD CONSTRAINT night_queue_processing_status_check
      CHECK (processing_status IN ('pending', 'processing', 'processed'));
  END IF;
END $$;

UPDATE public.night_queue
SET processing_status = 'processed'
WHERE processed = TRUE
  AND processing_status = 'pending'
  AND lease_token IS NULL;

-- Only deterministic historical links are backfilled. Unknown/ambiguous rows stay NULL.
WITH unambiguous AS (
  SELECT conversation_id, MIN(opportunity_id) AS opportunity_id
  FROM public.lead_routing_opportunities
  WHERE conversation_id IS NOT NULL
  GROUP BY conversation_id
  HAVING COUNT(*) = 1
), queue_candidates AS (
  SELECT nq.id, u.opportunity_id,
    ROW_NUMBER() OVER (
      PARTITION BY u.opportunity_id ORDER BY nq.processed, nq.queued_at, nq.id
    ) AS queue_rank
  FROM public.night_queue AS nq
  JOIN unambiguous AS u ON u.conversation_id = nq.conversation_id
  WHERE nq.opportunity_id IS NULL
)
UPDATE public.night_queue AS nq
SET opportunity_id = q.opportunity_id
FROM queue_candidates AS q
WHERE nq.id = q.id
  AND q.queue_rank = 1;

CREATE UNIQUE INDEX IF NOT EXISTS night_queue_opportunity_uniq
  ON public.night_queue (opportunity_id)
  WHERE opportunity_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS night_queue_claimable_idx
  ON public.night_queue (processing_status, lease_expires_at, queued_at, id)
  WHERE processed = FALSE;

CREATE OR REPLACE FUNCTION public.claim_night_queue(
  p_batch_size INTEGER DEFAULT 100,
  p_now TIMESTAMPTZ DEFAULT NOW(),
  p_lease_duration INTERVAL DEFAULT INTERVAL '10 minutes'
)
RETURNS TABLE (
  queue_id BIGINT,
  opportunity_id BIGINT,
  conversation_id UUID,
  source TEXT,
  lead_phone TEXT,
  lead_name TEXT,
  property_id TEXT,
  lead_email TEXT,
  temperature TEXT,
  bot_summary TEXT,
  queued_at TIMESTAMPTZ,
  property_title TEXT,
  property_public_id TEXT,
  property_price TEXT,
  lease_token UUID,
  routing_idempotency_key TEXT
) AS $$
DECLARE
  cdmx_time TIME;
BEGIN
  IF p_batch_size IS NULL OR p_batch_size < 1 OR p_batch_size > 500 THEN
    RAISE EXCEPTION 'batch size must be between 1 and 500';
  END IF;
  IF p_now IS NULL THEN
    RAISE EXCEPTION 'claim timestamp must not be null';
  END IF;
  IF p_lease_duration IS NULL
     OR p_lease_duration <= INTERVAL '0 seconds'
     OR p_lease_duration > INTERVAL '15 minutes' THEN
    RAISE EXCEPTION 'lease duration must be between 0 and 15 minutes';
  END IF;

  cdmx_time := (p_now AT TIME ZONE 'America/Mexico_City')::TIME;

  -- Report runs at 08:00; activation cannot begin before 08:05 CDMX.
  IF cdmx_time < TIME '08:05:00' OR cdmx_time >= TIME '20:00:00' THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH candidates AS MATERIALIZED (
    SELECT nq.id
    FROM public.night_queue AS nq
    WHERE nq.processed = FALSE
      AND nq.opportunity_id IS NOT NULL
      AND (
        nq.processing_status = 'pending'
        OR (nq.processing_status = 'processing' AND nq.lease_expires_at <= p_now)
      )
    ORDER BY nq.queued_at, nq.id
    FOR UPDATE SKIP LOCKED
    LIMIT p_batch_size
  ),
  leased AS (
    UPDATE public.night_queue AS nq
    SET processing_status = 'processing',
        lease_token = gen_random_uuid(),
        lease_expires_at = p_now + p_lease_duration,
        processing_attempts = processing_attempts + 1
    FROM candidates AS c
    WHERE nq.id = c.id
    RETURNING nq.*
  )
  SELECT
    l.id,
    l.opportunity_id,
    l.conversation_id,
    l.source,
    l.lead_phone,
    l.lead_name,
    l.property_id,
    l.lead_email,
    l.temperature,
    l.bot_summary,
    l.queued_at,
    COALESCE(pc.payload->>'title', conv.current_property, l.property_id),
    conv.property_public_id,
    COALESCE(pc.payload->>'price', 'Precio por confirmar'),
    l.lease_token,
    'night-queue:' || l.id::TEXT
  FROM leased AS l
  LEFT JOIN public.conversations AS conv ON conv.conversation_id = l.conversation_id
  LEFT JOIN public.properties_cache AS pc ON pc.property_id = l.property_id
  ORDER BY l.queued_at, l.id;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog;

CREATE OR REPLACE FUNCTION public.ack_night_queue_handoff(
  p_queue_id BIGINT,
  p_lease_token UUID,
  p_routing_idempotency_key TEXT
) RETURNS BOOLEAN AS $$
DECLARE
  v_opportunity_id BIGINT;
  v_conversation_id UUID;
  v_status TEXT;
  v_current_lease UUID;
  v_lease_expires_at TIMESTAMPTZ;
  v_event_id BIGINT;
  v_existing_opportunity_id BIGINT;
  v_existing_event_type TEXT;
BEGIN
  IF p_queue_id IS NULL OR p_lease_token IS NULL THEN
    RAISE EXCEPTION 'queue id and lease token are required';
  END IF;
  IF p_routing_idempotency_key IS NULL OR btrim(p_routing_idempotency_key) = '' THEN
    RAISE EXCEPTION 'routing idempotency key must not be blank';
  END IF;

  SELECT nq.opportunity_id, nq.conversation_id, nq.processing_status,
    nq.lease_token, nq.lease_expires_at
    INTO v_opportunity_id, v_conversation_id, v_status, v_current_lease,
      v_lease_expires_at
  FROM public.night_queue AS nq
  WHERE nq.id = p_queue_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'night queue item not found: %', p_queue_id;
  END IF;
  IF v_opportunity_id IS NULL THEN
    RAISE EXCEPTION 'night queue item lacks durable opportunity: %', p_queue_id;
  END IF;
  IF v_current_lease IS DISTINCT FROM p_lease_token THEN
    RAISE EXCEPTION 'stale night queue lease: %', p_queue_id;
  END IF;

  IF v_status = 'processed' THEN
    SELECT opportunity_id, event_type
      INTO v_existing_opportunity_id, v_existing_event_type
    FROM public.lead_routing_events
    WHERE idempotency_key = p_routing_idempotency_key;

    IF v_existing_opportunity_id IS DISTINCT FROM v_opportunity_id
       OR v_existing_event_type IS DISTINCT FROM 'night_queue_activated' THEN
      RAISE EXCEPTION 'processed handoff replay does not match durable event';
    END IF;
    RETURN TRUE;
  END IF;

  IF v_status IS DISTINCT FROM 'processing'
     OR v_lease_expires_at IS NULL
     OR v_lease_expires_at <= NOW() THEN
    RAISE EXCEPTION 'night queue lease is not active: %', p_queue_id;
  END IF;

  INSERT INTO public.lead_routing_events (
    opportunity_id, event_type, idempotency_key, external_evidence, metadata
  ) VALUES (
    v_opportunity_id,
    'night_queue_activated',
    p_routing_idempotency_key,
    jsonb_build_object('queue_id', p_queue_id),
    jsonb_build_object('handoff', 'router_accepted')
  )
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING event_id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT opportunity_id, event_type
      INTO v_existing_opportunity_id, v_existing_event_type
    FROM public.lead_routing_events
    WHERE idempotency_key = p_routing_idempotency_key;

    IF v_existing_opportunity_id IS DISTINCT FROM v_opportunity_id
       OR v_existing_event_type IS DISTINCT FROM 'night_queue_activated' THEN
      RAISE EXCEPTION 'routing idempotency key belongs to another event';
    END IF;
  END IF;

  IF v_conversation_id IS NOT NULL THEN
    UPDATE public.conversations
    SET mode = 'pending_assignment'
    WHERE conversation_id = v_conversation_id
      AND mode = 'night_queued';
  END IF;

  UPDATE public.night_queue
  SET processing_status = 'processed',
      processed = TRUE,
      processed_at = COALESCE(processed_at, NOW()),
      lease_expires_at = NULL
  WHERE id = p_queue_id
    AND lease_token = p_lease_token
    AND processing_status = 'processing'
    AND lease_expires_at > NOW();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'night queue handoff cannot be acknowledged: %', p_queue_id;
  END IF;

  RETURN TRUE;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog;

REVOKE ALL ON FUNCTION public.is_daytime_at(TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.claim_night_queue(INTEGER, TIMESTAMPTZ, INTERVAL)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.ack_night_queue_handoff(BIGINT, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_daytime_at(TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_night_queue(INTEGER, TIMESTAMPTZ, INTERVAL)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.ack_night_queue_handoff(BIGINT, UUID, TEXT)
  TO service_role;
