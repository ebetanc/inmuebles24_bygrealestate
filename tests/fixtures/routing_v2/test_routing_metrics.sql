-- LRV2-014: ops view, KPI function, unassigned-alert dedupe/ack, weekly report additivity.
\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE FUNCTION public.current_shift()
RETURNS TEXT LANGUAGE SQL STABLE SECURITY INVOKER SET search_path=pg_catalog
AS 'SELECT ''morning''::text';

INSERT INTO public.agents(agent_id,name,whatsapp_number,is_available) VALUES
  ('metrics_owner_test','Metrics Owner','525500000051',true),
  ('metrics_guard_test','Metrics Guard','525500000052',true)
ON CONFLICT(agent_id) DO UPDATE SET is_available=true,whatsapp_number=EXCLUDED.whatsapp_number;

-- 1. Ops view: an assigned opportunity has no SLA-remaining/unassigned flag;
--    a still-open delivered opportunity does; a closed opportunity is absent.
DO $$
DECLARE
  v_opp_assigned BIGINT;
  v_opp_open BIGINT;
  v_opp_closed BIGINT;
  v_row RECORD;
BEGIN
  INSERT INTO public.lead_routing_opportunities(
    property_id,identity_key,identity_reason,state,routing_tier,
    assigned_agent_id,delivery_status,delivered_at,expires_at,accepted_at,assigned_at
  ) VALUES(
    'EB-METRICS-ASSIGNED','email:metrics-assigned@example.test','normalized_email','assigned','owner',
    'metrics_owner_test','delivered',NOW()-INTERVAL '10 minutes',NOW()-INTERVAL '5 minutes',
    NOW()-INTERVAL '8 minutes',NOW()-INTERVAL '8 minutes'
  ) RETURNING opportunity_id INTO v_opp_assigned;
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key)
  VALUES(v_opp_assigned,'claim_accepted','owner','metrics:claim:'||v_opp_assigned::text);

  INSERT INTO public.lead_routing_opportunities(
    property_id,identity_key,identity_reason,state,routing_tier,delivery_status,delivered_at,expires_at
  ) VALUES(
    'EB-METRICS-OPEN','email:metrics-open@example.test','normalized_email','owner_open','owner',
    'delivered',NOW()-INTERVAL '1 minute',NOW()+INTERVAL '4 minutes'
  ) RETURNING opportunity_id INTO v_opp_open;

  INSERT INTO public.lead_routing_opportunities(
    property_id,identity_key,identity_reason,state,routing_tier,
    assigned_agent_id,delivery_status,delivered_at,expires_at,accepted_at,assigned_at,closed_at
  ) VALUES(
    'EB-METRICS-CLOSED','email:metrics-closed@example.test','normalized_email','closed_won','owner',
    'metrics_owner_test','delivered',NOW()-INTERVAL '2 days',NOW()-INTERVAL '2 days'+INTERVAL '5 minutes',
    NOW()-INTERVAL '2 days'+INTERVAL '3 minutes',NOW()-INTERVAL '2 days'+INTERVAL '3 minutes',NOW()-INTERVAL '2 days'
  ) RETURNING opportunity_id INTO v_opp_closed;

  SELECT * INTO v_row FROM public.routing_v2_ops_view WHERE opportunity_id=v_opp_assigned;
  IF NOT FOUND OR v_row.sla_remaining_seconds IS NOT NULL OR v_row.is_unassigned THEN
    RAISE EXCEPTION 'assigned opportunity must not report SLA-remaining or unassigned flag';
  END IF;

  SELECT * INTO v_row FROM public.routing_v2_ops_view WHERE opportunity_id=v_opp_open;
  IF NOT FOUND OR v_row.sla_remaining_seconds IS NULL OR v_row.sla_remaining_seconds > 300 THEN
    RAISE EXCEPTION 'open delivered opportunity must report bounded SLA-remaining seconds';
  END IF;

  PERFORM 1 FROM public.routing_v2_ops_view WHERE opportunity_id=v_opp_closed;
  IF FOUND THEN RAISE EXCEPTION 'closed opportunity must not appear in the operative view'; END IF;
END $$;

-- 2. KPI function: acceptance rate by tier and unassigned counts reflect the
--    seeded rows; delivered_at (not detected_at) drives the SLA-adjacent spans.
DO $$
DECLARE
  v_kpi JSONB;
  v_opp_unassigned BIGINT;
BEGIN
  INSERT INTO public.lead_routing_opportunities(
    property_id,identity_key,identity_reason,state,assigned_agent_id
  ) VALUES(
    'EB-METRICS-UNASSIGNED','email:metrics-unassigned@example.test','normalized_email','unassigned_alerted',NULL
  ) RETURNING opportunity_id INTO v_opp_unassigned;
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,idempotency_key)
  VALUES(v_opp_unassigned,'unassigned_alerted','metrics:unassigned:'||v_opp_unassigned::text);
  INSERT INTO public.lead_routing_events(opportunity_id,event_type,routing_tier,idempotency_key)
  VALUES(v_opp_unassigned,'late_claim_rejected','backup_guard','metrics:late:'||v_opp_unassigned::text);

  v_kpi := public.get_routing_v2_kpis(30);

  IF (v_kpi->>'unassigned_cases_open')::int < 1 THEN
    RAISE EXCEPTION 'unassigned_cases_open must count the seeded open unassigned case';
  END IF;
  IF (v_kpi->>'unassigned_cases_in_window')::int < 1 THEN
    RAISE EXCEPTION 'unassigned_cases_in_window must count the unassigned_alerted event';
  END IF;
  IF (v_kpi->'acceptance_rate_by_tier'->>'owner')::numeric IS DISTINCT FROM 100.0 THEN
    RAISE EXCEPTION 'owner tier acceptance rate must be 100 given one claim_accepted and no rejections';
  END IF;
  IF (v_kpi->'acceptance_rate_by_tier'->>'backup_guard')::numeric IS DISTINCT FROM 0.0 THEN
    RAISE EXCEPTION 'backup_guard tier acceptance rate must be 0 given only a late-claim rejection';
  END IF;
  IF (v_kpi->>'avg_detection_to_delivery_seconds') IS NULL THEN
    RAISE EXCEPTION 'avg_detection_to_delivery_seconds must be computable from seeded delivered rows';
  END IF;
END $$;

-- 3. Unassigned alert dedupe: second call for the same opportunity is not new;
--    acknowledge flips exactly once and is idempotent to call again.
DO $$
DECLARE
  v_opp BIGINT;
  v_first RECORD;
  v_second RECORD;
  v_ack public.routing_v2_unassigned_alerts;
  v_count INTEGER;
BEGIN
  INSERT INTO public.lead_routing_opportunities(
    property_id,identity_key,identity_reason,state,assigned_agent_id
  ) VALUES(
    'EB-METRICS-DEDUPE','email:metrics-dedupe@example.test','normalized_email','unassigned_alerted',NULL
  ) RETURNING opportunity_id INTO v_opp;

  SELECT * INTO v_first FROM public.record_unassigned_alert(v_opp,'wf20-unassigned:'||v_opp::text||':run1');
  IF NOT v_first.is_new OR v_first.acknowledged THEN
    RAISE EXCEPTION 'first unassigned alert call must be new and unacknowledged';
  END IF;

  SELECT * INTO v_second FROM public.record_unassigned_alert(v_opp,'wf20-unassigned:'||v_opp::text||':run2');
  IF v_second.is_new OR v_second.alert_id IS DISTINCT FROM v_first.alert_id THEN
    RAISE EXCEPTION 'repeated alert for the same opportunity must not create a new incident';
  END IF;

  SELECT count(*) INTO v_count FROM public.routing_v2_unassigned_alerts WHERE opportunity_id=v_opp;
  IF v_count<>1 THEN RAISE EXCEPTION 'dedupe must leave exactly one alert row per opportunity'; END IF;

  SELECT * INTO v_ack FROM public.acknowledge_unassigned_alert(v_opp,'sandy_test');
  IF NOT v_ack.acknowledged OR v_ack.acknowledged_by IS DISTINCT FROM 'sandy_test' THEN
    RAISE EXCEPTION 'acknowledge must mark the alert acknowledged with the actor';
  END IF;

  -- Acknowledging again must not raise and must not change acknowledged_at.
  PERFORM public.acknowledge_unassigned_alert(v_opp,'sandy_test');
  SELECT count(*) INTO v_count FROM public.routing_v2_unassigned_alerts
   WHERE opportunity_id=v_opp AND acknowledged AND acknowledged_by='sandy_test';
  IF v_count<>1 THEN RAISE EXCEPTION 'repeated acknowledge must stay idempotent'; END IF;
END $$;

-- 4. weekly_lead_report(): existing keys survive, new routing_v2 key appears.
DO $$
DECLARE v_report JSONB;
BEGIN
  v_report := public.weekly_lead_report(30);
  IF NOT (v_report ? 'recibidos') OR NOT (v_report ? 'no_atendidos_lista')
     OR NOT (v_report ? 'tasa_reclamo_por_asesor') THEN
    RAISE EXCEPTION 'weekly_lead_report lost a pre-existing key';
  END IF;
  IF NOT (v_report ? 'routing_v2') OR NOT (v_report->'routing_v2' ? 'unassigned_cases_open') THEN
    RAISE EXCEPTION 'weekly_lead_report did not add the routing_v2 key additively';
  END IF;
END $$;

ROLLBACK;
