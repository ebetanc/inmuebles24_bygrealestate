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
  WHERE a.agent_id = v_opp.assigned_agent_id;
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
