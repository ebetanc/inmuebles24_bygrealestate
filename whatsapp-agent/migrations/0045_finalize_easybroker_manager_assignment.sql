-- Final responsibility + exact EasyBroker note target for Inmuebles24 leads.
--
-- 1. After every owner/guard tier expires and Sandy's WhatsApp alert is
--    provider-confirmed, Sandy becomes the operational owner.
-- 2. An assigned Inmuebles24 conversation is linked to an EasyBroker request
--    only when property + identity + time produce one unique match.
-- 3. The existing UI worker then writes one note and marks that exact request
--    Atendida.

ALTER TABLE public.conversations
  DROP CONSTRAINT IF EXISTS conversations_assignment_method_check;
ALTER TABLE public.conversations
  ADD CONSTRAINT conversations_assignment_method_check CHECK (
    assignment_method IS NULL OR assignment_method IN (
      'whatsapp_number', 'manual', 'easybroker_legacy', 'manager_escalation'
    )
  );

ALTER TABLE public.conversations
  ADD COLUMN IF NOT EXISTS eb_contact_linked_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS eb_contact_match_basis TEXT
    CHECK (eb_contact_match_basis IS NULL OR eb_contact_match_basis IN (
      'email', 'phone', 'email+phone'
    ));

CREATE UNIQUE INDEX IF NOT EXISTS conversations_eb_contact_id_uniq
  ON public.conversations (eb_contact_id)
  WHERE eb_contact_id IS NOT NULL;

COMMENT ON COLUMN public.conversations.eb_contact_linked_at IS
  'When an Inmuebles24 lead was uniquely correlated to an exact EasyBroker request.';
COMMENT ON COLUMN public.conversations.eb_contact_match_basis IS
  'Exact identity fields used with property and time to correlate the EasyBroker request.';

CREATE OR REPLACE FUNCTION public.reconcile_easybroker_contact_requests(
  p_requests JSONB,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS TABLE (
  conversation_id UUID,
  eb_contact_id BIGINT,
  match_basis TEXT
) AS $$
DECLARE
  v_request_id BIGINT;
BEGIN
  IF p_requests IS NULL OR jsonb_typeof(p_requests) <> 'array'
     OR jsonb_array_length(p_requests) > 500 OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid EasyBroker reconciliation input';
  END IF;

  -- Serialize each external request across workers. The matching query is a
  -- separate statement, so it sees any link committed while this call waited.
  FOR v_request_id IN
    SELECT DISTINCT safe_ids.request_id
    FROM (
      SELECT CASE
        WHEN COALESCE(value->>'id', value->>'contact_request_id', '') ~ '^[0-9]{1,18}$'
          THEN COALESCE(value->>'id', value->>'contact_request_id')::BIGINT
      END AS request_id
      FROM jsonb_array_elements(p_requests)
    ) AS safe_ids
    WHERE safe_ids.request_id IS NOT NULL
    ORDER BY safe_ids.request_id
  LOOP
    PERFORM pg_advisory_xact_lock(v_request_id);
  END LOOP;

  RETURN QUERY
  WITH raw_requests AS (
    SELECT value AS request
    FROM jsonb_array_elements(p_requests)
  ), normalized_requests AS (
    SELECT
      CASE
        WHEN COALESCE(request->>'id', request->>'contact_request_id', '') ~ '^[0-9]{1,18}$'
          THEN COALESCE(request->>'id', request->>'contact_request_id')::BIGINT
      END AS request_id,
      UPPER(NULLIF(btrim(request->>'property_id'), '')) AS property_id,
      LOWER(NULLIF(btrim(request->>'email'), '')) AS email,
      regexp_replace(COALESCE(request->>'phone', ''), '[^0-9]', '', 'g') AS phone_digits,
      CASE
        WHEN COALESCE(request->>'happened_at', '') ~
          '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'
          THEN (request->>'happened_at')::TIMESTAMPTZ
      END AS happened_at
    FROM raw_requests
  ), possible_matches AS (
    SELECT
      c.conversation_id,
      r.request_id,
      r.email IS NOT NULL
        AND o.normalized_email IS NOT NULL
        AND r.email = LOWER(o.normalized_email) AS email_matches,
      r.phone_digits <> ''
        AND regexp_replace(COALESCE(o.e164_phone, ''), '[^0-9]', '', 'g') <> ''
        AND (
          CASE
            WHEN length(r.phone_digits) = 10 THEN '52' || r.phone_digits
            ELSE r.phone_digits
          END
        ) = (
          CASE
            WHEN length(regexp_replace(COALESCE(o.e164_phone, ''), '[^0-9]', '', 'g')) = 10
              THEN '52' || regexp_replace(o.e164_phone, '[^0-9]', '', 'g')
            ELSE regexp_replace(COALESCE(o.e164_phone, ''), '[^0-9]', '', 'g')
          END
        ) AS phone_matches
    FROM normalized_requests r
    JOIN public.conversations c
      ON UPPER(NULLIF(btrim(c.property_public_id), '')) = r.property_id
    JOIN public.lead_routing_opportunities o
      ON o.conversation_id = c.conversation_id
    WHERE r.request_id IS NOT NULL
      AND r.property_id IS NOT NULL
      AND r.happened_at IS NOT NULL
      AND r.happened_at BETWEEN o.detected_at - INTERVAL '24 hours'
                            AND o.detected_at + INTERVAL '24 hours'
      AND r.happened_at <= p_now + INTERVAL '5 minutes'
      AND c.source = 'inmuebles24'
      AND c.eb_contact_id IS NULL
      AND c.assigned_agent_id IS NOT NULL
      AND o.state = 'assigned'
      AND o.assigned_agent_id = c.assigned_agent_id
  ), identity_matches AS (
    SELECT
      possible_matches.conversation_id,
      possible_matches.request_id,
      CASE
        WHEN email_matches AND phone_matches THEN 'email+phone'
        WHEN email_matches THEN 'email'
        ELSE 'phone'
      END AS match_basis
    FROM possible_matches
    WHERE possible_matches.email_matches OR possible_matches.phone_matches
  ), unique_matches AS (
    SELECT
      identity_matches.*,
      count(*) OVER (PARTITION BY identity_matches.conversation_id) AS conversation_matches,
      count(*) OVER (PARTITION BY identity_matches.request_id) AS request_matches
    FROM identity_matches
  ), linked AS (
    UPDATE public.conversations c
    SET eb_contact_id = m.request_id,
        eb_contact_linked_at = p_now,
        eb_contact_match_basis = m.match_basis
    FROM unique_matches m
    WHERE c.conversation_id = m.conversation_id
      AND c.eb_contact_id IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.conversations existing
        WHERE existing.eb_contact_id = m.request_id
      )
      AND m.conversation_matches = 1
      AND m.request_matches = 1
    RETURNING c.conversation_id, c.eb_contact_id, c.eb_contact_match_basis
  )
  SELECT l.conversation_id, l.eb_contact_id, l.eb_contact_match_basis
  FROM linked l;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.reconcile_easybroker_contact_requests(JSONB, TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconcile_easybroker_contact_requests(JSONB, TIMESTAMPTZ)
  TO service_role;

CREATE OR REPLACE FUNCTION public.complete_unassigned_alert_notification(
  p_opportunity_id BIGINT,
  p_lease_token UUID,
  p_channel TEXT,
  p_external_id TEXT
) RETURNS public.routing_v2_unassigned_alerts AS $$
DECLARE
  v_channel TEXT := lower(NULLIF(btrim(p_channel), ''));
  v_external_id TEXT := NULLIF(btrim(p_external_id), '');
  v_row public.routing_v2_unassigned_alerts;
  v_conversation_id UUID;
BEGIN
  IF p_opportunity_id IS NULL OR p_lease_token IS NULL
     OR v_channel NOT IN ('email', 'whatsapp') OR v_external_id IS NULL THEN
    RAISE EXCEPTION 'invalid unassigned alert notification evidence';
  END IF;

  UPDATE public.routing_v2_unassigned_alerts
  SET acknowledged = TRUE,
      acknowledged_at = NOW(),
      acknowledged_by = 'wf3c:' || v_channel || ':' || v_external_id,
      lease_token = NULL,
      lease_expires_at = NULL
  WHERE opportunity_id = p_opportunity_id
    AND NOT acknowledged
    AND lease_token = p_lease_token
    AND lease_expires_at > NOW()
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'stale or missing unassigned alert lease: %', p_opportunity_id;
  END IF;

  -- Owner/guard claims win the row lock. Only the still-unassigned final state
  -- becomes Sandy's operational responsibility.
  UPDATE public.lead_routing_opportunities o
  SET state = 'assigned',
      routing_tier = NULL,
      assigned_agent_id = 'agent_manager',
      assigned_at = COALESCE(o.assigned_at, NOW()),
      external_evidence = COALESCE(o.external_evidence, '{}'::JSONB)
        || jsonb_build_object(
          'manager_escalation', jsonb_build_object(
            'agent_id', 'agent_manager',
            'channel', v_channel,
            'external_id', v_external_id,
            'reason', 'no_response_after_backup'
          )
        ),
      updated_at = NOW()
  WHERE o.opportunity_id = p_opportunity_id
    AND o.state = 'unassigned_alerted'
    AND o.assigned_agent_id IS NULL
  RETURNING o.conversation_id INTO v_conversation_id;

  IF v_conversation_id IS NOT NULL THEN
    UPDATE public.conversations c
    SET assigned_agent_id = 'agent_manager',
        assigned_at = COALESCE(c.assigned_at, NOW()),
        assignment_method = 'manager_escalation',
        claimed_via = 'escalation',
        routing_tier = 'manager',
        mode = 'ai'
    WHERE c.conversation_id = v_conversation_id
      AND c.assigned_agent_id IS NULL;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'conversation assignment changed during manager fallback: %', v_conversation_id;
    END IF;

    INSERT INTO public.lead_routing_events (
      opportunity_id, event_type, actor_id, idempotency_key, metadata
    ) VALUES (
      p_opportunity_id,
      'manager_assigned',
      'agent_manager',
      'manager-assigned:' || p_opportunity_id::TEXT,
      jsonb_build_object(
        'reason', 'no_response_after_backup',
        'channel', v_channel,
        'external_id', v_external_id
      )
    );
  END IF;

  RETURN v_row;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.complete_unassigned_alert_notification(BIGINT, UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_unassigned_alert_notification(BIGINT, UUID, TEXT, TEXT)
  TO service_role;

-- Backward-compatible wrapper for older WF3c exports.
CREATE OR REPLACE FUNCTION public.complete_unassigned_alert_delivery(
  p_opportunity_id BIGINT,
  p_lease_token UUID,
  p_provider_message_id TEXT
) RETURNS public.routing_v2_unassigned_alerts AS $$
BEGIN
  RETURN public.complete_unassigned_alert_notification(
    p_opportunity_id,
    p_lease_token,
    'whatsapp',
    p_provider_message_id
  );
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.complete_unassigned_alert_delivery(BIGINT, UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_unassigned_alert_delivery(BIGINT, UUID, TEXT)
  TO service_role;

-- Replace the EasyBroker effect lease so an explicit final manager assignment
-- is eligible without pretending Sandy sent a first response.
CREATE OR REPLACE FUNCTION public.claim_easybroker_attend_effects(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE(
  conversation_id UUID,
  lead_phone TEXT,
  lead_name TEXT,
  assigned_agent_id TEXT,
  eb_contact_id BIGINT,
  eb_note_added BOOLEAN,
  eb_marked_attended BOOLEAN,
  lease_token UUID
) AS $$
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid EasyBroker effect claim input';
  END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT c.conversation_id
    FROM public.conversations c
    WHERE c.eb_contact_id IS NOT NULL
      AND c.assigned_agent_id IS NOT NULL
      AND (
        c.claimed_via IS NULL
        OR c.claimed_via <> 'escalation'
        OR c.first_response_at IS NOT NULL
        OR c.assignment_method = 'manager_escalation'
      )
      AND (c.eb_note_added = false OR c.eb_marked_attended = false)
      AND (
        c.eb_effect_lease_token IS NULL
        OR COALESCE(c.eb_effect_lease_expires_at, '-infinity'::TIMESTAMPTZ) <= p_now
      )
    ORDER BY c.created_at, c.conversation_id
    FOR UPDATE OF c SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    UPDATE public.conversations c
    SET eb_effect_lease_token = gen_random_uuid(),
        eb_effect_lease_expires_at = p_now + INTERVAL '15 minutes',
        eb_effect_attempts = c.eb_effect_attempts + 1,
        eb_effect_last_error = NULL
    FROM candidates q
    WHERE c.conversation_id = q.conversation_id
    RETURNING c.conversation_id, c.lead_phone, c.lead_name, c.assigned_agent_id,
      c.eb_contact_id, c.eb_note_added, c.eb_marked_attended, c.eb_effect_lease_token
  )
  SELECT c.conversation_id, c.lead_phone, c.lead_name, c.assigned_agent_id,
    c.eb_contact_id, c.eb_note_added, c.eb_marked_attended, c.eb_effect_lease_token
  FROM claimed c;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.claim_easybroker_attend_effects(INTEGER, TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_easybroker_attend_effects(INTEGER, TIMESTAMPTZ)
  TO service_role;
