-- 2026-10-16 (opp 1277): Meta answered 131000 to the guard offer at minute 5 and
-- this V2 fallback closed the whole lead as 'unassigned_alerted': the owner's
-- delivered offer stopped being claimable and the minute-65 Sandy/BYG fallback
-- never ran. For V3 a failed send now only drops that one offer:
--   * another offer of the same capture was delivered -> it stays claimable
--     until the shared deadline (minute 65), then WF23 assigns Sandy/BYG;
--   * no offer was delivered at all -> straight to Sandy/BYG.
-- Non-V3 opportunities keep the previous behaviour verbatim.
CREATE OR REPLACE FUNCTION public.fallback_failed_owner_delivery(p_attempt_id bigint, p_reason text)
 RETURNS lead_routing_opportunities
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_attempt public.lead_routing_delivery_attempts; v_coverage RECORD; v_opp public.lead_routing_opportunities; v_tier TEXT; v_state TEXT; v_event public.lead_routing_events; v_key TEXT; v_meta JSONB;
  v_open public.lead_routing_delivery_attempts;
BEGIN
  SELECT * INTO v_attempt FROM public.lead_routing_delivery_attempts WHERE attempt_id=p_attempt_id FOR UPDATE;
  SELECT * INTO v_opp FROM public.lead_routing_opportunities WHERE opportunity_id=v_attempt.opportunity_id FOR UPDATE;
  IF v_opp.current_delivery_attempt_id IS DISTINCT FROM p_attempt_id OR v_opp.delivered_at IS NOT NULL THEN RETURN v_opp; END IF;

  IF v_opp.v3_enabled AND v_attempt.capture_event_id IS NOT NULL THEN
    UPDATE public.lead_routing_delivery_attempts SET status='failed',failed_at=COALESCE(failed_at,NOW())
    WHERE attempt_id=p_attempt_id AND status<>'delivered';
    SELECT * INTO v_open FROM public.lead_routing_delivery_attempts a
    WHERE a.capture_event_id=v_attempt.capture_event_id AND a.opportunity_id=v_attempt.opportunity_id
      AND a.attempt_id<>p_attempt_id AND a.delivery_kind='offer' AND a.status='delivered'
      AND a.delivered_at IS NOT NULL AND a.routing_tier IN ('owner','primary_guard')
    ORDER BY a.delivered_at DESC LIMIT 1;
    IF FOUND THEN
      UPDATE public.lead_routing_opportunities
      SET state=CASE v_open.routing_tier WHEN 'owner' THEN 'owner_open' ELSE 'primary_guard_open' END,
          routing_tier=v_open.routing_tier,current_delivery_attempt_id=v_open.attempt_id,
          delivery_status='delivered',delivered_at=v_open.delivered_at,
          expires_at=public.v3_shared_deadline(v_attempt.capture_event_id),updated_at=NOW()
      WHERE opportunity_id=v_attempt.opportunity_id RETURNING * INTO v_opp;
      RETURN v_opp;
    END IF;
    RETURN public.v3_assign_manager(v_attempt.opportunity_id, public.v3_fallback_agent(NOW()),
      'offer_send_failed', v_attempt.capture_event_id, NOW());
  END IF;

  v_tier:=CASE v_attempt.routing_tier WHEN 'owner' THEN 'primary_guard' WHEN 'primary_guard' THEN 'backup_guard' ELSE NULL END;
  SELECT * INTO v_coverage FROM public.get_guard_coverage_slots() c WHERE c.coverage_role=CASE v_tier WHEN 'primary_guard' THEN 'primary' WHEN 'backup_guard' THEN 'backup' END LIMIT 1;
  IF v_coverage.agent_id IS NULL AND v_attempt.routing_tier='owner' THEN
    v_tier:='backup_guard';
    SELECT * INTO v_coverage FROM public.get_guard_coverage_slots() c WHERE c.coverage_role='backup' LIMIT 1;
  END IF;
  IF v_coverage.agent_id IS NULL THEN v_tier:=NULL; END IF;
  v_state:=CASE WHEN v_tier IS NULL THEN 'unassigned_alerted' ELSE 'guard_delivery_pending' END;
  v_key:='delivery-fallback:'||p_attempt_id::text; v_meta:=jsonb_strip_nulls(jsonb_build_object('reason',left(COALESCE(p_reason,'delivery_failed'),120),'agent_id',v_coverage.agent_id));
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key,metadata) VALUES(v_attempt.opportunity_id,CASE WHEN v_tier IS NULL THEN 'unassigned_alerted' ELSE 'escalated' END,v_tier,v_key,v_meta) ON CONFLICT(idempotency_key) DO NOTHING;
  SELECT * INTO v_event FROM public.lead_routing_events WHERE idempotency_key=v_key;
  IF v_event.opportunity_id IS DISTINCT FROM v_attempt.opportunity_id OR v_event.event_type IS DISTINCT FROM (CASE WHEN v_tier IS NULL THEN 'unassigned_alerted' ELSE 'escalated' END) OR v_event.routing_tier IS DISTINCT FROM v_tier OR v_event.metadata IS DISTINCT FROM v_meta THEN RAISE EXCEPTION 'delivery fallback event collision'; END IF;
  UPDATE public.lead_routing_delivery_attempts SET status='failed',failed_at=COALESCE(failed_at,NOW()) WHERE attempt_id=p_attempt_id AND status<>'delivered';
  UPDATE public.lead_routing_opportunities SET state=v_state,routing_tier=v_tier,current_delivery_attempt_id=NULL,delivery_status='failed',delivered_at=NULL,expires_at=NULL,updated_at=NOW() WHERE opportunity_id=v_attempt.opportunity_id RETURNING * INTO v_opp;
  RETURN v_opp;
END; $function$;
