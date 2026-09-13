-- A late Meta `read` callback (agent opens the WhatsApp minutes later) was
-- re-opening opportunities already closed as `unassigned` (and could flip an
-- opportunity in guard tier back to owner_open). Only the current delivery
-- attempt may touch the opportunity; older attempts just record the event.
-- Seen 2026-09-11..13: 14 leads stuck in *_open with unassigned_at set, so
-- WF23 reported "vencida sin escalar" forever.
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
  IF NOT v_opp.v3_enabled THEN RETURN TRUE; END IF;
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,idempotency_key,external_evidence)
  VALUES(v_attempt.opportunity_id,'delivery_confirmed','v3-delivery-read:'||BTRIM(p_provider_message_id),
    jsonb_build_object('provider_message_id',BTRIM(p_provider_message_id),'status','read'))
  ON CONFLICT (idempotency_key) DO NOTHING;
  UPDATE public.lead_routing_delivery_attempts
  SET status='delivered', delivered_at=COALESCE(delivered_at,p_now)
  WHERE attempt_id=v_attempt.attempt_id AND status IN ('requested','sent');
  -- v3_mark_unassigned / v3_advance_routing_tier clear or replace
  -- current_delivery_attempt_id, so a stale attempt can never reopen the row.
  IF v_opp.assigned_agent_id IS NULL
     AND v_opp.current_delivery_attempt_id = v_attempt.attempt_id THEN
    UPDATE public.lead_routing_opportunities
    SET state=CASE v_attempt.routing_tier WHEN 'owner' THEN 'owner_open' ELSE 'primary_guard_open' END,
        delivery_status='delivered', delivered_at=COALESCE(delivered_at,p_now),
        expires_at=COALESCE(expires_at, v_attempt.delivered_at + INTERVAL '5 minutes', p_now+INTERVAL '5 minutes'), updated_at=p_now
    WHERE opportunity_id=v_opp.opportunity_id;
  END IF;
  RETURN TRUE;
END;
$$;

-- Repair rows reopened by the bug: unassigned_at already set, state still open.
UPDATE public.lead_routing_opportunities
SET state='unassigned', expires_at=NULL, updated_at=NOW()
WHERE v3_enabled AND unassigned_at IS NOT NULL AND assigned_agent_id IS NULL
  AND state IN ('owner_open','primary_guard_open');
