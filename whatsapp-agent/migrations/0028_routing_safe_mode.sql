-- 0028_routing_safe_mode.sql
-- LRV2-013: durable circuit breaker for lead routing (S-13, S-14).
-- Additive; reuses lead_routing_events append-only trigger function from 0021.
-- Emergency rollback (approved runbook only):
-- DROP FUNCTION public.exit_routing_safe_mode(text,boolean,text,timestamptz);
-- DROP FUNCTION public.get_routing_safe_mode();
-- DROP FUNCTION public.report_routing_failure(text,text,timestamptz);
-- DROP TRIGGER routing_safe_mode_events_append_only ON public.routing_safe_mode_events;
-- DROP TABLE public.routing_safe_mode_events;
-- DROP TABLE public.routing_safe_mode_state;

CREATE TABLE IF NOT EXISTS public.routing_safe_mode_state (
  id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  status TEXT NOT NULL DEFAULT 'normal' CHECK (status IN ('normal', 'safe_mode')),
  reason TEXT,
  entered_at TIMESTAMPTZ,
  operational_owner TEXT,
  acknowledged BOOLEAN NOT NULL DEFAULT false,
  acknowledged_at TIMESTAMPTZ,
  acknowledged_by TEXT,
  exited_at TIMESTAMPTZ,
  exited_by TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.routing_safe_mode_state IS
  'Singleton circuit-breaker status for lead routing v2. History lives in routing_safe_mode_events; this row is the current snapshot.';

INSERT INTO public.routing_safe_mode_state (id, status)
VALUES (1, 'normal')
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.routing_safe_mode_events (
  event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_type TEXT NOT NULL CHECK (event_type IN (
    'failure_recorded', 'safe_mode_entered', 'safe_mode_exited'
  )),
  actor_id TEXT,
  reason TEXT,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  idempotency_key TEXT NOT NULL UNIQUE,
  metadata JSONB
);

COMMENT ON TABLE public.routing_safe_mode_events IS
  'Append-only audit of routing safe-mode transitions. idempotency_key deduplicates watchdog and exit retries.';

CREATE INDEX IF NOT EXISTS routing_safe_mode_events_type_occurred_idx
  ON public.routing_safe_mode_events (event_type, occurred_at DESC);

ALTER TABLE public.routing_safe_mode_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.routing_safe_mode_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.routing_safe_mode_state, public.routing_safe_mode_events
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.routing_safe_mode_state, public.routing_safe_mode_events
  FROM service_role;
GRANT SELECT, UPDATE ON TABLE public.routing_safe_mode_state TO service_role;
GRANT SELECT, INSERT ON TABLE public.routing_safe_mode_events TO service_role;

REVOKE ALL ON SEQUENCE public.routing_safe_mode_events_event_id_seq FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.routing_safe_mode_events_event_id_seq FROM service_role;
GRANT USAGE, SELECT ON SEQUENCE public.routing_safe_mode_events_event_id_seq TO service_role;

-- Reuse the generic append-only guard already defined in 0021_lead_routing_v2.sql.
CREATE OR REPLACE TRIGGER routing_safe_mode_events_append_only
  BEFORE UPDATE OR DELETE ON public.routing_safe_mode_events
  FOR EACH ROW EXECUTE FUNCTION public.reject_lead_routing_event_mutation();

-- Watchdog calls this once per detected routing failure. Idempotent: a repeated
-- idempotency_key never re-evaluates the trip, so two failures inside 5 minutes
-- trip safe_mode exactly once, and later failures while already tripped only
-- append history without re-entering.
CREATE OR REPLACE FUNCTION public.report_routing_failure(
  p_reason TEXT,
  p_idempotency_key TEXT,
  p_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS TABLE (
  status TEXT,
  reason TEXT,
  entered_at TIMESTAMPTZ,
  operational_owner TEXT,
  acknowledged BOOLEAN,
  just_entered BOOLEAN
) AS $$
DECLARE
  v_event_id BIGINT;
  v_existing_event_type TEXT;
  v_failure_count INTEGER;
  v_state public.routing_safe_mode_state;
  v_just_entered BOOLEAN := false;
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = ''
     OR p_idempotency_key IS NULL OR btrim(p_idempotency_key) = ''
     OR p_occurred_at IS NULL THEN
    RAISE EXCEPTION 'invalid routing failure report input';
  END IF;

  INSERT INTO public.routing_safe_mode_events (event_type, reason, idempotency_key, occurred_at)
  VALUES ('failure_recorded', p_reason, p_idempotency_key, p_occurred_at)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING event_id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT e.event_type INTO v_existing_event_type
    FROM public.routing_safe_mode_events e
    WHERE e.idempotency_key = p_idempotency_key;
    IF v_existing_event_type IS DISTINCT FROM 'failure_recorded' THEN
      RAISE EXCEPTION 'idempotency_key already belongs to another routing safe mode event';
    END IF;
    SELECT * INTO v_state FROM public.routing_safe_mode_state WHERE id = 1;
    RETURN QUERY SELECT v_state.status, v_state.reason, v_state.entered_at,
      v_state.operational_owner, v_state.acknowledged, false;
    RETURN;
  END IF;

  SELECT * INTO v_state FROM public.routing_safe_mode_state WHERE id = 1 FOR UPDATE;

  IF v_state.status = 'normal' THEN
    SELECT count(*) INTO v_failure_count
    FROM public.routing_safe_mode_events e
    WHERE e.event_type = 'failure_recorded'
      AND e.occurred_at > p_occurred_at - INTERVAL '5 minutes'
      AND e.occurred_at <= p_occurred_at;

    IF v_failure_count >= 2 THEN
      INSERT INTO public.routing_safe_mode_events (event_type, reason, idempotency_key, occurred_at)
      VALUES ('safe_mode_entered', p_reason, p_idempotency_key || ':entered', p_occurred_at)
      ON CONFLICT (idempotency_key) DO NOTHING;

      UPDATE public.routing_safe_mode_state
         SET status = 'safe_mode',
             reason = p_reason,
             entered_at = p_occurred_at,
             operational_owner = 'manager',
             acknowledged = false,
             acknowledged_at = NULL,
             acknowledged_by = NULL,
             exited_at = NULL,
             exited_by = NULL,
             updated_at = NOW()
       WHERE id = 1
      RETURNING * INTO v_state;
      v_just_entered := true;
    END IF;
  END IF;

  RETURN QUERY SELECT v_state.status, v_state.reason, v_state.entered_at,
    v_state.operational_owner, v_state.acknowledged, v_just_entered;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.report_routing_failure(TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.report_routing_failure(TEXT, TEXT, TIMESTAMPTZ) TO service_role;

-- Read-only check used by the watchdog and by intake to decide direct-to-guard routing.
CREATE OR REPLACE FUNCTION public.get_routing_safe_mode()
RETURNS public.routing_safe_mode_state AS $$
DECLARE
  v_state public.routing_safe_mode_state;
BEGIN
  SELECT * INTO v_state FROM public.routing_safe_mode_state WHERE id = 1;
  RETURN v_state;
END;
$$ LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.get_routing_safe_mode() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_routing_safe_mode() TO service_role;

-- Manual-only exit. Requires an explicit actor and an asserted green health
-- check; never deletes history. Re-entry is possible afterward via
-- report_routing_failure because status returns to 'normal'.
CREATE OR REPLACE FUNCTION public.exit_routing_safe_mode(
  p_actor_id TEXT,
  p_health_check_ok BOOLEAN,
  p_idempotency_key TEXT,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS public.routing_safe_mode_state AS $$
DECLARE
  v_state public.routing_safe_mode_state;
  v_event_id BIGINT;
  v_existing_event_type TEXT;
BEGIN
  IF p_actor_id IS NULL OR btrim(p_actor_id) = '' THEN
    RAISE EXCEPTION 'routing safe mode exit requires an explicit actor';
  END IF;
  IF p_health_check_ok IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'routing safe mode exit requires a green health check';
  END IF;
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid routing safe mode exit input';
  END IF;

  SELECT * INTO v_state FROM public.routing_safe_mode_state WHERE id = 1 FOR UPDATE;

  IF v_state.status <> 'safe_mode' THEN
    RETURN v_state;
  END IF;

  INSERT INTO public.routing_safe_mode_events (
    event_type, actor_id, reason, idempotency_key, occurred_at, metadata
  ) VALUES (
    'safe_mode_exited', p_actor_id, v_state.reason, p_idempotency_key, p_now,
    jsonb_build_object('health_check_ok', p_health_check_ok)
  ) ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING event_id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT e.event_type INTO v_existing_event_type
    FROM public.routing_safe_mode_events e
    WHERE e.idempotency_key = p_idempotency_key;
    IF v_existing_event_type IS DISTINCT FROM 'safe_mode_exited' THEN
      RAISE EXCEPTION 'idempotency_key already belongs to another routing safe mode event';
    END IF;
    RETURN v_state;
  END IF;

  UPDATE public.routing_safe_mode_state
     SET status = 'normal',
         exited_at = p_now,
         exited_by = p_actor_id,
         updated_at = NOW()
   WHERE id = 1
  RETURNING * INTO v_state;

  RETURN v_state;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.exit_routing_safe_mode(TEXT, BOOLEAN, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exit_routing_safe_mode(TEXT, BOOLEAN, TEXT, TIMESTAMPTZ) TO service_role;

-- LRV2-013 (P1-A): route_missing_owner_data was defined in 0025 with a reason
-- whitelist of exactly 'missing_owner_data'. WF10's safe-mode direct-to-guard
-- branch needs to record its own distinct audit reason ('routing_safe_mode')
-- rather than being mislabeled as a missing-owner-data event. Overridden here
-- (0028 supersedes 0025) with the same signature/body, widening only the
-- reason whitelist check.
CREATE OR REPLACE FUNCTION public.route_missing_owner_data(
  p_opportunity_id bigint,
  p_reason text,
  p_idempotency_key text
) RETURNS TABLE (
  opportunity_id bigint,
  state text,
  routing_tier text,
  primary_agent_id text,
  primary_number text
) AS $$
DECLARE
  v_opp public.lead_routing_opportunities;
  v_coverage record;
  v_target_state text;
  v_target_tier text;
  v_metadata jsonb;
  v_event_id bigint;
  v_existing_event public.lead_routing_events;
BEGIN
  IF p_reason IN ('missing_owner_data', 'routing_safe_mode') THEN NULL;
  ELSE RAISE EXCEPTION 'invalid owner fallback reason'; END IF;
  IF NULLIF(btrim(p_idempotency_key), '') IS NULL THEN RAISE EXCEPTION 'idempotency key required'; END IF;

  SELECT * INTO v_opp FROM public.lead_routing_opportunities o
  WHERE o.opportunity_id = p_opportunity_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'opportunity unavailable for owner fallback'; END IF;

  -- Replay is bound to originally persisted evidence, never today's coverage.
  SELECT * INTO v_existing_event FROM public.lead_routing_events e
  WHERE e.idempotency_key = btrim(p_idempotency_key);
  IF FOUND THEN
    IF v_existing_event.opportunity_id <> p_opportunity_id
       OR v_existing_event.event_type <> 'missing_owner_data'
       OR v_existing_event.metadata->>'reason' <> p_reason
    THEN RAISE EXCEPTION 'owner fallback idempotency collision'; END IF;
    RETURN QUERY SELECT v_opp.opportunity_id,
      v_existing_event.metadata->>'state', v_existing_event.routing_tier,
      v_existing_event.metadata->>'agent_id', v_existing_event.metadata->>'agent_number';
    RETURN;
  END IF;

  SELECT c.coverage_role, c.agent_id, c.whatsapp_number INTO v_coverage
  FROM public.get_guard_coverage_slots() c
  ORDER BY CASE c.coverage_role WHEN 'primary' THEN 1 WHEN 'backup' THEN 2 END
  LIMIT 1;
  v_target_tier := CASE v_coverage.coverage_role WHEN 'primary' THEN 'primary_guard' WHEN 'backup' THEN 'backup_guard' END;
  v_target_state := CASE v_coverage.coverage_role WHEN 'primary' THEN 'primary_guard_open' WHEN 'backup' THEN 'backup_guard_open' ELSE 'unassigned_alerted' END;
  v_metadata := jsonb_strip_nulls(jsonb_build_object(
    'reason', p_reason, 'state', v_target_state,
    'coverage_role', v_coverage.coverage_role, 'agent_id', v_coverage.agent_id,
    'agent_number', v_coverage.whatsapp_number
  ));

  IF v_opp.state NOT IN ('captured', 'resolved') THEN
    RAISE EXCEPTION 'owner fallback cannot regress state: %', v_opp.state;
  END IF;

  INSERT INTO public.lead_routing_events (
    opportunity_id, event_type, routing_tier, idempotency_key, metadata
  ) VALUES (
    p_opportunity_id, 'missing_owner_data', v_target_tier, btrim(p_idempotency_key), v_metadata
  ) ON CONFLICT (idempotency_key) DO NOTHING RETURNING event_id INTO v_event_id;
  IF v_event_id IS NULL THEN
    SELECT * INTO v_existing_event FROM public.lead_routing_events e
    WHERE e.idempotency_key = btrim(p_idempotency_key);
    IF v_existing_event.opportunity_id <> p_opportunity_id
       OR v_existing_event.event_type <> 'missing_owner_data'
       OR v_existing_event.routing_tier IS DISTINCT FROM v_target_tier
       OR v_existing_event.metadata IS DISTINCT FROM v_metadata
    THEN RAISE EXCEPTION 'owner fallback idempotency collision'; END IF;
    RETURN QUERY SELECT v_opp.opportunity_id,
      v_existing_event.metadata->>'state', v_existing_event.routing_tier,
      v_existing_event.metadata->>'agent_id', v_existing_event.metadata->>'agent_number';
    RETURN;
  END IF;

  UPDATE public.lead_routing_opportunities o
  SET state = v_target_state, routing_tier = v_target_tier, updated_at = now()
  WHERE o.opportunity_id = p_opportunity_id RETURNING * INTO v_opp;

  RETURN QUERY SELECT v_opp.opportunity_id, v_opp.state, v_opp.routing_tier,
    v_coverage.agent_id::text, v_coverage.whatsapp_number::text;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.route_missing_owner_data(bigint,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.route_missing_owner_data(bigint,text,text) TO service_role;
