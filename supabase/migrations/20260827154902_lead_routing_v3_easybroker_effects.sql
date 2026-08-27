-- V3-07 LOCAL DRAFT ONLY: PROPOSED / NO APLICADO. No legacy-table mutation.
-- Effects are request-level. An exact link creates a durable
-- awaiting_responsible ledger; the worker promotes it only after final assignment.
CREATE TABLE IF NOT EXISTS public.easybroker_effect_ledger (
  eb_request_id BIGINT PRIMARY KEY
    REFERENCES public.easybroker_contact_request_inbox(eb_request_id),
  opportunity_id BIGINT NOT NULL
    REFERENCES public.lead_routing_opportunities(opportunity_id),
  responsible_agent_id TEXT REFERENCES public.agents(agent_id),
  responsible_first_name TEXT,
  close_state TEXT NOT NULL DEFAULT 'awaiting_responsible'
    CHECK (close_state IN ('awaiting_responsible','pending','retrying','exhausted','completed')),
  note_state TEXT NOT NULL DEFAULT 'pending'
    CHECK (note_state IN ('pending','succeeded','failed')),
  attended_state TEXT NOT NULL DEFAULT 'pending'
    CHECK (attended_state IN ('pending','succeeded','failed')),
  note_evidence JSONB NOT NULL DEFAULT '{}'::JSONB,
  attended_evidence JSONB NOT NULL DEFAULT '{}'::JSONB,
  note_first_failed_at TIMESTAMPTZ,
  note_next_retry_at TIMESTAMPTZ,
  note_retry_count INTEGER NOT NULL DEFAULT 0
    CHECK (note_retry_count BETWEEN 0 AND 5),
  attended_first_failed_at TIMESTAMPTZ,
  attended_next_retry_at TIMESTAMPTZ,
  attended_retry_count INTEGER NOT NULL DEFAULT 0
    CHECK (attended_retry_count BETWEEN 0 AND 5),
  next_retry_at TIMESTAMPTZ,
  lease_token UUID,
  lease_expires_at TIMESTAMPTZ,
  sandy_alerted_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (close_state = 'awaiting_responsible'
         OR (responsible_agent_id IS NOT NULL
             AND NULLIF(BTRIM(responsible_first_name), '') IS NOT NULL)),
  CHECK (close_state <> 'completed'
         OR (note_state = 'succeeded' AND attended_state = 'succeeded')),
  CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL))
);

CREATE INDEX IF NOT EXISTS easybroker_effect_due_idx
  ON public.easybroker_effect_ledger(next_retry_at, eb_request_id)
  WHERE close_state IN ('pending','retrying','exhausted');
CREATE INDEX IF NOT EXISTS easybroker_effect_note_due_idx
  ON public.easybroker_effect_ledger(note_next_retry_at, eb_request_id)
  WHERE note_state IN ('pending','failed') AND note_next_retry_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS easybroker_effect_attended_due_idx
  ON public.easybroker_effect_ledger(attended_next_retry_at, eb_request_id)
  WHERE attended_state IN ('pending','failed') AND attended_next_retry_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.easybroker_effect_attempts (
  -- History is retained; only an unfinished lease reservation may be rebound.
  attempt_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  eb_request_id BIGINT NOT NULL
    REFERENCES public.easybroker_effect_ledger(eb_request_id),
  effect_kind TEXT NOT NULL CHECK (effect_kind IN ('note','attended')),
  attempt_no INTEGER NOT NULL CHECK (attempt_no BETWEEN 0 AND 5),
  effect_idempotency_key TEXT NOT NULL UNIQUE,
  lease_token UUID NOT NULL,
  started_at TIMESTAMPTZ NOT NULL,
  finished_at TIMESTAMPTZ,
  ok BOOLEAN,
  evidence JSONB NOT NULL DEFAULT '{}'::JSONB,
  UNIQUE (eb_request_id, effect_kind, attempt_no)
);
CREATE INDEX IF NOT EXISTS easybroker_effect_attempt_request_idx
  ON public.easybroker_effect_attempts(eb_request_id, effect_kind, attempt_no);

CREATE TABLE IF NOT EXISTS public.easybroker_effect_alerts (
  alert_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  eb_request_id BIGINT NOT NULL
    REFERENCES public.easybroker_effect_ledger(eb_request_id),
  opportunity_id BIGINT NOT NULL
    REFERENCES public.lead_routing_opportunities(opportunity_id),
  incident_key TEXT NOT NULL UNIQUE,
  alert_type TEXT NOT NULL DEFAULT 'easybroker_effects_exhausted'
    CHECK (alert_type = 'easybroker_effects_exhausted'),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','leased','sent','failed','exhausted')),
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  lease_token UUID,
  lease_expires_at TIMESTAMPTZ,
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
  last_error TEXT,
  provider_message_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sent_at TIMESTAMPTZ,
  CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL)),
  CHECK (metadata ? 'retry_count' AND metadata->>'retry_count' IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS easybroker_effect_alert_due_idx
  ON public.easybroker_effect_alerts(status, created_at, alert_id)
  WHERE status IN ('pending','failed');

ALTER TABLE public.easybroker_effect_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.easybroker_effect_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.easybroker_effect_alerts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.easybroker_effect_ledger,
  public.easybroker_effect_attempts, public.easybroker_effect_alerts
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.easybroker_effect_ledger,
  public.easybroker_effect_attempts, public.easybroker_effect_alerts TO service_role;
REVOKE ALL ON SEQUENCE public.easybroker_effect_attempts_attempt_id_seq,
  public.easybroker_effect_alerts_alert_id_seq
  FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE, SELECT ON SEQUENCE public.easybroker_effect_attempts_attempt_id_seq,
  public.easybroker_effect_alerts_alert_id_seq TO service_role;

CREATE OR REPLACE FUNCTION public.enqueue_v3_easybroker_effect(
  p_eb_request_id BIGINT,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE
  v_link public.easybroker_i24_request_links;
  v_opp public.lead_routing_opportunities;
  v_agent public.agents;
  v_existing public.easybroker_effect_ledger;
  v_first_name TEXT;
BEGIN
  IF p_eb_request_id IS NULL OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid EasyBroker effect enqueue input';
  END IF;

  SELECT l.* INTO v_link
  FROM public.easybroker_i24_request_links l
  JOIN public.easybroker_contact_request_inbox i
    ON i.eb_request_id = l.eb_request_id
  WHERE l.eb_request_id = p_eb_request_id
    AND i.correlation_state IN ('linked','already_linked')
  FOR UPDATE;
  IF NOT FOUND OR v_link.opportunity_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'state', 'not_exactly_linked',
      'eb_request_id', p_eb_request_id);
  END IF;

  SELECT o.* INTO v_opp
  FROM public.lead_routing_opportunities o
  WHERE o.opportunity_id = v_link.opportunity_id
    AND o.state IN ('assigned', 'closed_won')
    AND o.assigned_agent_id IS NOT NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.easybroker_effect_ledger(
      eb_request_id, opportunity_id, close_state, updated_at
    ) VALUES (
      p_eb_request_id, v_link.opportunity_id, 'awaiting_responsible', p_now
    ) ON CONFLICT (eb_request_id) DO NOTHING;
    SELECT * INTO v_existing
    FROM public.easybroker_effect_ledger e
    WHERE e.eb_request_id = p_eb_request_id
    FOR UPDATE;
    IF v_existing.opportunity_id IS DISTINCT FROM v_link.opportunity_id THEN
      RAISE EXCEPTION 'EasyBroker effect ledger collision';
    END IF;
    RETURN jsonb_build_object('ok', false, 'state', 'awaiting_responsible',
      'eb_request_id', p_eb_request_id, 'opportunity_id', v_link.opportunity_id);
  END IF;

  SELECT a.* INTO v_agent
  FROM public.agents a
  WHERE a.agent_id = v_opp.assigned_agent_id
  FOR SHARE;
  IF NOT FOUND OR NULLIF(BTRIM(v_agent.name), '') IS NULL THEN
    RAISE EXCEPTION 'final responsible agent is not canonical';
  END IF;
  v_first_name := split_part(regexp_replace(BTRIM(v_agent.name), '\s+', ' ', 'g'), ' ', 1);

  SELECT * INTO v_existing
  FROM public.easybroker_effect_ledger e
  WHERE e.eb_request_id = p_eb_request_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.opportunity_id IS DISTINCT FROM v_opp.opportunity_id THEN
      RAISE EXCEPTION 'EasyBroker effect ledger collision';
    END IF;
    IF v_existing.responsible_agent_id IS NULL
       AND v_existing.close_state = 'awaiting_responsible' THEN
      UPDATE public.easybroker_effect_ledger e
      SET responsible_agent_id = v_agent.agent_id,
          responsible_first_name = v_first_name,
          close_state = 'pending', note_next_retry_at = p_now,
          attended_next_retry_at = p_now, next_retry_at = p_now,
          updated_at = p_now
      WHERE e.eb_request_id = p_eb_request_id;
      RETURN jsonb_build_object('ok', true, 'state', 'pending',
        'eb_request_id', p_eb_request_id, 'opportunity_id', v_opp.opportunity_id,
        'responsible_first_name', v_first_name);
    END IF;
    IF v_existing.responsible_agent_id IS DISTINCT FROM v_agent.agent_id
       OR v_existing.responsible_first_name IS DISTINCT FROM v_first_name THEN
      RAISE EXCEPTION 'EasyBroker effect responsible collision';
    END IF;
    RETURN jsonb_build_object('ok', true, 'state', v_existing.close_state,
      'eb_request_id', p_eb_request_id, 'opportunity_id', v_opp.opportunity_id);
  END IF;

  INSERT INTO public.easybroker_effect_ledger(
    eb_request_id, opportunity_id, responsible_agent_id, responsible_first_name,
    close_state, note_next_retry_at, attended_next_retry_at, next_retry_at, updated_at
  ) VALUES (
    p_eb_request_id, v_opp.opportunity_id, v_agent.agent_id, v_first_name,
    'pending', p_now, p_now, p_now, p_now
  );
  RETURN jsonb_build_object('ok', true, 'state', 'pending',
    'eb_request_id', p_eb_request_id, 'opportunity_id', v_opp.opportunity_id,
    'responsible_first_name', v_first_name);
END; $$;

REVOKE ALL ON FUNCTION public.enqueue_v3_easybroker_effect(BIGINT,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.enqueue_v3_easybroker_effect(BIGINT,TIMESTAMPTZ)
  TO service_role;

CREATE OR REPLACE FUNCTION public.claim_v3_easybroker_effects(
  p_limit INTEGER,
  p_now TIMESTAMPTZ,
  p_lease_duration INTERVAL
) RETURNS TABLE(
  eb_request_id BIGINT,
  opportunity_id BIGINT,
  responsible_first_name TEXT,
  note_state TEXT,
  attended_state TEXT,
  lease_token UUID,
  lease_expires_at TIMESTAMPTZ,
  note_due BOOLEAN,
  attended_due BOOLEAN,
  note_idempotency_key TEXT,
  attended_idempotency_key TEXT
)
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE
  r public.easybroker_effect_ledger;
  v_note_due BOOLEAN;
  v_attended_due BOOLEAN;
  v_token UUID;
  v_expires TIMESTAMPTZ;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500
     OR p_now IS NULL OR p_lease_duration IS NULL
     OR p_lease_duration <= INTERVAL '0'
     OR p_lease_duration > INTERVAL '15 minutes' THEN
    RAISE EXCEPTION 'invalid effect lease input';
  END IF;

  -- Assignment and EasyBroker correlation can complete in either order.  On
  -- every worker pass, atomically promote exact linked ledgers whose final
  -- responsible is now known; no second correlation or external retry is
  -- required to make the request actionable.
  UPDATE public.easybroker_effect_ledger e
  SET responsible_agent_id = a.agent_id,
      responsible_first_name = split_part(
        regexp_replace(BTRIM(a.name), '\s+', ' ', 'g'), ' ', 1
      ),
      close_state = 'pending',
      note_next_retry_at = p_now,
      attended_next_retry_at = p_now,
      next_retry_at = p_now,
      updated_at = p_now
  FROM public.lead_routing_opportunities o
  JOIN public.agents a ON a.agent_id = o.assigned_agent_id
  WHERE e.opportunity_id = o.opportunity_id
    AND e.close_state = 'awaiting_responsible'
    AND o.state IN ('assigned','closed_won')
    AND o.assigned_agent_id IS NOT NULL
    AND NULLIF(BTRIM(a.name), '') IS NOT NULL;

  FOR r IN
    SELECT e.*
    FROM public.easybroker_effect_ledger e
    WHERE e.close_state IN ('pending','retrying','exhausted')
      AND (e.lease_expires_at IS NULL OR e.lease_expires_at <= p_now)
      AND (
        (e.note_state IN ('pending','failed')
         AND e.note_next_retry_at IS NOT NULL AND e.note_next_retry_at <= p_now)
        OR
        (e.attended_state IN ('pending','failed')
         AND e.note_state = 'succeeded'
         AND e.attended_next_retry_at IS NOT NULL AND e.attended_next_retry_at <= p_now)
      )
    ORDER BY e.next_retry_at, e.eb_request_id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_note_due := r.note_state IN ('pending','failed')
      AND r.note_next_retry_at IS NOT NULL AND r.note_next_retry_at <= p_now;
    v_attended_due := r.attended_state IN ('pending','failed')
      AND r.note_state = 'succeeded'
      AND r.attended_next_retry_at IS NOT NULL AND r.attended_next_retry_at <= p_now;
    v_token := gen_random_uuid();
    v_expires := p_now + p_lease_duration;

    UPDATE public.easybroker_effect_ledger e
    SET lease_token = v_token, lease_expires_at = v_expires, updated_at = p_now
    WHERE e.eb_request_id = r.eb_request_id;

    IF v_note_due THEN
      INSERT INTO public.easybroker_effect_attempts(
        eb_request_id, effect_kind, attempt_no, effect_idempotency_key,
        lease_token, started_at
      ) VALUES (
        r.eb_request_id, 'note', r.note_retry_count,
        'easybroker:' || r.eb_request_id || ':note:' || r.note_retry_count,
        v_token, p_now
      ) ON CONFLICT (effect_idempotency_key) DO UPDATE
        SET lease_token = EXCLUDED.lease_token,
            started_at = EXCLUDED.started_at
        WHERE public.easybroker_effect_attempts.finished_at IS NULL;
    END IF;
    IF v_attended_due THEN
      INSERT INTO public.easybroker_effect_attempts(
        eb_request_id, effect_kind, attempt_no, effect_idempotency_key,
        lease_token, started_at
      ) VALUES (
        r.eb_request_id, 'attended', r.attended_retry_count,
        'easybroker:' || r.eb_request_id || ':attended:' || r.attended_retry_count,
        v_token, p_now
      ) ON CONFLICT (effect_idempotency_key) DO UPDATE
        SET lease_token = EXCLUDED.lease_token,
            started_at = EXCLUDED.started_at
        WHERE public.easybroker_effect_attempts.finished_at IS NULL;
    END IF;

    eb_request_id := r.eb_request_id;
    opportunity_id := r.opportunity_id;
    responsible_first_name := r.responsible_first_name;
    note_state := r.note_state;
    attended_state := r.attended_state;
    lease_token := v_token;
    lease_expires_at := v_expires;
    note_due := v_note_due;
    attended_due := v_attended_due;
    note_idempotency_key := CASE WHEN v_note_due
      THEN 'easybroker:' || r.eb_request_id || ':note:' || r.note_retry_count END;
    attended_idempotency_key := CASE WHEN v_attended_due
      THEN 'easybroker:' || r.eb_request_id || ':attended:' || r.attended_retry_count END;
    RETURN NEXT;
  END LOOP;
END; $$;

REVOKE ALL ON FUNCTION public.claim_v3_easybroker_effects(INTEGER,TIMESTAMPTZ,INTERVAL)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_v3_easybroker_effects(INTEGER,TIMESTAMPTZ,INTERVAL)
  TO service_role;

CREATE OR REPLACE FUNCTION public.finish_v3_easybroker_effect(
  p_eb_request_id BIGINT,
  p_lease_token UUID,
  p_step TEXT,
  p_ok BOOLEAN,
  p_evidence JSONB,
  p_now TIMESTAMPTZ
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE
  l public.easybroker_effect_ledger;
  v_attempt_no INTEGER;
  v_next_count INTEGER;
  v_next_deadline TIMESTAMPTZ;
  v_effect_key TEXT;
  v_alert_id BIGINT;
  v_note_next TIMESTAMPTZ;
  v_attended_next TIMESTAMPTZ;
  v_note_count INTEGER;
  v_attended_count INTEGER;
  v_retry_count INTEGER;
  v_close_state TEXT;
BEGIN
  IF p_eb_request_id IS NULL OR p_lease_token IS NULL
     OR p_step IS NULL OR p_step NOT IN ('note','attended')
     OR p_ok IS NULL OR p_now IS NULL
     OR p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' THEN
    RAISE EXCEPTION 'invalid effect result';
  END IF;

  SELECT * INTO l
  FROM public.easybroker_effect_ledger e
  WHERE e.eb_request_id = p_eb_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'state', 'missing_ledger',
      'eb_request_id', p_eb_request_id);
  END IF;

  IF p_step = 'note' AND l.note_state = 'succeeded' THEN
    RETURN jsonb_build_object('ok', true, 'state', 'already_succeeded',
      'eb_request_id', p_eb_request_id, 'step', p_step);
  END IF;
  IF p_step = 'attended' AND l.attended_state = 'succeeded' THEN
    RETURN jsonb_build_object('ok', true, 'state', 'already_succeeded',
      'eb_request_id', p_eb_request_id, 'step', p_step);
  END IF;
  IF l.responsible_agent_id IS NULL
     OR NULLIF(BTRIM(l.responsible_first_name), '') IS NULL THEN
    RAISE EXCEPTION 'final responsible required before EasyBroker effects';
  END IF;
  IF l.lease_token IS DISTINCT FROM p_lease_token
     OR l.lease_expires_at IS NULL OR l.lease_expires_at <= p_now THEN
    RETURN jsonb_build_object('ok', false, 'state', 'lease_conflict',
      'eb_request_id', p_eb_request_id, 'step', p_step);
  END IF;
  IF p_step = 'attended' AND l.note_state <> 'succeeded' THEN
    RETURN jsonb_build_object('ok', false, 'state', 'note_required',
      'eb_request_id', p_eb_request_id, 'step', p_step);
  END IF;
  IF p_evidence->>'eb_request_id' IS DISTINCT FROM p_eb_request_id::TEXT THEN
    RAISE EXCEPTION 'exact EasyBroker request evidence required';
  END IF;
  IF p_ok AND p_step = 'note'
     AND p_evidence->>'note' IS DISTINCT FROM
         'RESPONSABLE: ' || BTRIM(l.responsible_first_name) THEN
    RAISE EXCEPTION 'canonical responsible note required';
  END IF;
  IF p_ok AND p_step = 'note'
     AND COALESCE(p_evidence->>'reconciled_existing', 'false') <> 'true'
     AND COALESCE(p_evidence->>'note_written', 'false') <> 'true' THEN
    RAISE EXCEPTION 'note write or existing-note reconciliation evidence required';
  END IF;
  IF p_ok AND p_step = 'attended'
     AND p_evidence->>'status' IS DISTINCT FROM 'Atendida' THEN
    RAISE EXCEPTION 'Atendida status evidence required';
  END IF;

  v_attempt_no := CASE WHEN p_step = 'note'
    THEN l.note_retry_count ELSE l.attended_retry_count END;
  v_effect_key := 'easybroker:' || p_eb_request_id || ':' || p_step || ':' || v_attempt_no;
  IF NOT EXISTS (
    SELECT 1
    FROM public.easybroker_effect_attempts a
    WHERE a.eb_request_id = p_eb_request_id
      AND a.effect_idempotency_key = v_effect_key
      AND a.lease_token = p_lease_token
      AND a.finished_at IS NULL
  ) THEN
    RETURN jsonb_build_object('ok', false, 'state', 'attempt_conflict',
      'eb_request_id', p_eb_request_id, 'step', p_step,
      'effect_idempotency_key', v_effect_key);
  END IF;

  IF p_ok THEN
    IF p_step = 'note' THEN
      UPDATE public.easybroker_effect_ledger e
      SET note_state = 'succeeded', note_evidence = p_evidence,
          note_next_retry_at = NULL, updated_at = p_now
      WHERE e.eb_request_id = p_eb_request_id;
    ELSE
      UPDATE public.easybroker_effect_ledger e
      SET attended_state = 'succeeded', attended_evidence = p_evidence,
          attended_next_retry_at = NULL, updated_at = p_now
      WHERE e.eb_request_id = p_eb_request_id;
    END IF;
  ELSE
    v_next_count := v_attempt_no + 1;
    v_next_deadline := COALESCE(
      CASE WHEN p_step = 'note' THEN l.note_first_failed_at
           ELSE l.attended_first_failed_at END, p_now
    ) + CASE v_next_count
      WHEN 1 THEN INTERVAL '1 minute'
      WHEN 2 THEN INTERVAL '5 minutes'
      WHEN 3 THEN INTERVAL '15 minutes'
      WHEN 4 THEN INTERVAL '30 minutes'
      ELSE INTERVAL '0'
    END;
    IF p_step = 'note' THEN
      UPDATE public.easybroker_effect_ledger e
      SET note_state = 'failed', note_evidence = p_evidence,
          note_retry_count = LEAST(v_next_count, 5),
          note_first_failed_at = COALESCE(e.note_first_failed_at, p_now),
          note_next_retry_at = CASE WHEN v_next_count >= 5 THEN NULL ELSE v_next_deadline END,
          updated_at = p_now
      WHERE e.eb_request_id = p_eb_request_id;
    ELSE
      UPDATE public.easybroker_effect_ledger e
      SET attended_state = 'failed', attended_evidence = p_evidence,
          attended_retry_count = LEAST(v_next_count, 5),
          attended_first_failed_at = COALESCE(e.attended_first_failed_at, p_now),
          attended_next_retry_at = CASE WHEN v_next_count >= 5 THEN NULL ELSE v_next_deadline END,
          updated_at = p_now
      WHERE e.eb_request_id = p_eb_request_id;
    END IF;
  END IF;

  SELECT e.note_next_retry_at, e.attended_next_retry_at,
         e.note_retry_count, e.attended_retry_count,
         CASE WHEN e.note_state = 'succeeded' AND e.attended_state = 'succeeded'
              THEN 'completed'
              WHEN e.note_retry_count >= 5 OR e.attended_retry_count >= 5
              THEN 'exhausted' ELSE 'retrying' END
    INTO v_note_next, v_attended_next, v_note_count, v_attended_count,
         v_close_state
  FROM public.easybroker_effect_ledger e
  WHERE e.eb_request_id = p_eb_request_id;
  v_retry_count := GREATEST(v_note_count, v_attended_count, 0);
  UPDATE public.easybroker_effect_ledger e
  SET close_state = v_close_state,
      next_retry_at = CASE WHEN v_note_next IS NULL THEN v_attended_next
                           WHEN v_attended_next IS NULL THEN v_note_next
                           ELSE LEAST(v_note_next, v_attended_next) END,
      lease_token = NULL,
      lease_expires_at = NULL,
      updated_at = p_now
  WHERE e.eb_request_id = p_eb_request_id;

  UPDATE public.easybroker_effect_attempts a
  SET finished_at = p_now, ok = p_ok, evidence = p_evidence
  WHERE a.effect_idempotency_key = v_effect_key
    AND a.eb_request_id = p_eb_request_id
    AND a.finished_at IS NULL;

  IF v_close_state = 'exhausted' THEN
    INSERT INTO public.easybroker_effect_alerts(
      eb_request_id, opportunity_id, incident_key, metadata
    ) VALUES (
      p_eb_request_id, l.opportunity_id,
      'easybroker_effect_exhausted:' || p_eb_request_id,
      jsonb_build_object('target', 'sandy', 'step', p_step,
        'retry_count', v_retry_count, 'eb_request_id', p_eb_request_id)
    ) ON CONFLICT (incident_key) DO NOTHING
    RETURNING alert_id INTO v_alert_id;
    UPDATE public.easybroker_effect_ledger e
    SET sandy_alerted_at = COALESCE(e.sandy_alerted_at, p_now), updated_at = p_now
    WHERE e.eb_request_id = p_eb_request_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', p_ok, 'state', v_close_state, 'eb_request_id', p_eb_request_id,
    'step', p_step, 'effect_idempotency_key', v_effect_key,
    'alert_created', v_alert_id IS NOT NULL, 'changed_at', p_now
  );
END; $$;

REVOKE ALL ON FUNCTION public.finish_v3_easybroker_effect(
  BIGINT,UUID,TEXT,BOOLEAN,JSONB,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finish_v3_easybroker_effect(
  BIGINT,UUID,TEXT,BOOLEAN,JSONB,TIMESTAMPTZ)
  TO service_role;

CREATE OR REPLACE FUNCTION public.claim_v3_easybroker_effect_alerts(
  p_limit INTEGER,
  p_now TIMESTAMPTZ,
  p_lease_duration INTERVAL
) RETURNS TABLE(
  alert_id BIGINT,
  eb_request_id BIGINT,
  opportunity_id BIGINT,
  metadata JSONB,
  lease_token UUID,
  lease_expires_at TIMESTAMPTZ
)
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE
  a public.easybroker_effect_alerts;
  v_token UUID;
  v_expires TIMESTAMPTZ;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500
     OR p_now IS NULL OR p_lease_duration IS NULL
     OR p_lease_duration <= INTERVAL '0'
     OR p_lease_duration > INTERVAL '15 minutes' THEN
    RAISE EXCEPTION 'invalid EasyBroker alert lease input';
  END IF;

  FOR a IN
    SELECT x.*
    FROM public.easybroker_effect_alerts x
    WHERE x.status IN ('pending','failed')
      AND x.attempts < 5
      AND (x.lease_expires_at IS NULL OR x.lease_expires_at <= p_now)
    ORDER BY x.created_at, x.alert_id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_token := gen_random_uuid();
    v_expires := p_now + p_lease_duration;
    UPDATE public.easybroker_effect_alerts x
    SET status = 'leased', lease_token = v_token,
        lease_expires_at = v_expires, attempts = x.attempts + 1,
        updated_at = p_now
    WHERE x.alert_id = a.alert_id;
    alert_id := a.alert_id;
    eb_request_id := a.eb_request_id;
    opportunity_id := a.opportunity_id;
    metadata := a.metadata;
    lease_token := v_token;
    lease_expires_at := v_expires;
    RETURN NEXT;
  END LOOP;
END; $$;

REVOKE ALL ON FUNCTION public.claim_v3_easybroker_effect_alerts(
  INTEGER,TIMESTAMPTZ,INTERVAL)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_v3_easybroker_effect_alerts(
  INTEGER,TIMESTAMPTZ,INTERVAL)
  TO service_role;

CREATE OR REPLACE FUNCTION public.finish_v3_easybroker_effect_alert(
  p_alert_id BIGINT,
  p_lease_token UUID,
  p_ok BOOLEAN,
  p_provider_message_id TEXT,
  p_error TEXT,
  p_now TIMESTAMPTZ
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE
  v_row public.easybroker_effect_alerts;
BEGIN
  IF p_alert_id IS NULL OR p_lease_token IS NULL OR p_ok IS NULL
     OR p_now IS NULL OR length(COALESCE(p_error, '')) > 120
     OR (p_ok AND NULLIF(BTRIM(p_provider_message_id), '') IS NULL) THEN
    RAISE EXCEPTION 'invalid EasyBroker alert result';
  END IF;
  SELECT * INTO v_row
  FROM public.easybroker_effect_alerts a
  WHERE a.alert_id = p_alert_id
  FOR UPDATE;
  IF NOT FOUND OR v_row.lease_token IS DISTINCT FROM p_lease_token
     OR v_row.lease_expires_at IS NULL OR v_row.lease_expires_at <= p_now THEN
    RETURN jsonb_build_object('ok', false, 'state', 'lease_conflict',
      'alert_id', p_alert_id);
  END IF;
  UPDATE public.easybroker_effect_alerts a
  SET status = CASE WHEN p_ok THEN 'sent'
                    WHEN a.attempts >= 5 THEN 'exhausted'
                    ELSE 'failed' END,
      provider_message_id = CASE WHEN p_ok THEN p_provider_message_id
                                 ELSE a.provider_message_id END,
      last_error = CASE WHEN p_ok THEN NULL ELSE NULLIF(BTRIM(p_error), '') END,
      sent_at = CASE WHEN p_ok THEN p_now ELSE a.sent_at END,
      lease_token = NULL, lease_expires_at = NULL, updated_at = p_now
  WHERE a.alert_id = p_alert_id AND a.lease_token = p_lease_token;
  RETURN jsonb_build_object('ok', p_ok, 'state',
    CASE WHEN p_ok THEN 'sent'
         WHEN v_row.attempts >= 5 THEN 'exhausted'
         ELSE 'failed' END, 'alert_id', p_alert_id,
    'changed_at', p_now);
END; $$;

REVOKE ALL ON FUNCTION public.finish_v3_easybroker_effect_alert(
  BIGINT,UUID,BOOLEAN,TEXT,TEXT,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finish_v3_easybroker_effect_alert(
  BIGINT,UUID,BOOLEAN,TEXT,TEXT,TIMESTAMPTZ)
  TO service_role;
