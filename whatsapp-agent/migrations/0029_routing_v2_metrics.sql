-- 0029_routing_v2_metrics.sql
-- LRV2-014: observability only. No new assignment logic; every value is derived
-- from lead_routing_opportunities/events, routing_safe_mode_state, delivery
-- attempts, and conversations already written by LRV2-003..013. SLA math uses
-- delivered_at exclusively (contract: "delivered_at es unica base de reloj SLA");
-- detected_at/accepted_at/assigned_at/closed_at are used only for non-SLA KPI
-- spans (detection->delivery, delivery->acceptance, total), never for SLA
-- remaining time.
-- Emergency rollback (approved runbook only):
-- DROP FUNCTION public.acknowledge_unassigned_alert(bigint,text);
-- DROP FUNCTION public.record_unassigned_alert(bigint,text);
-- DROP TABLE public.routing_v2_unassigned_alerts;
-- DROP FUNCTION public.get_routing_v2_kpis(int);
-- DROP VIEW public.routing_v2_ops_view;
-- (weekly_lead_report reverts to 0020's CREATE OR REPLACE if re-run after this file)

-- ---------------------------------------------------------------------------
-- 1. Operative view: current state of every non-closed opportunity.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.routing_v2_ops_view
WITH (security_invoker = true) AS
SELECT
  o.opportunity_id,
  o.state,
  o.routing_tier,
  o.assigned_agent_id,
  ag.name AS assigned_agent_name,
  o.conversation_id,
  c.source AS conversation_source,
  o.property_id,
  o.detected_at,
  o.delivered_at,
  o.expires_at,
  -- SLA remaining is only meaningful once a delivery is confirmed and while
  -- nobody has claimed the opportunity yet; delivered_at is the sole clock base.
  CASE
    WHEN o.delivered_at IS NOT NULL AND o.expires_at IS NOT NULL AND o.assigned_agent_id IS NULL
      THEN GREATEST(0, EXTRACT(EPOCH FROM (o.expires_at - now())))::int
    ELSE NULL
  END AS sla_remaining_seconds,
  (o.state = 'unassigned_alerted' AND o.assigned_agent_id IS NULL) AS is_unassigned,
  ev.event_type AS last_evidence_type,
  ev.occurred_at AS last_evidence_at,
  COALESCE(ev.external_evidence, ev.metadata) AS last_evidence
FROM public.lead_routing_opportunities o
LEFT JOIN public.conversations c ON c.conversation_id = o.conversation_id
LEFT JOIN public.agents ag ON ag.agent_id = o.assigned_agent_id
LEFT JOIN LATERAL (
  SELECT e.event_type, e.occurred_at, e.external_evidence, e.metadata
  FROM public.lead_routing_events e
  WHERE e.opportunity_id = o.opportunity_id
  ORDER BY e.occurred_at DESC, e.event_id DESC
  LIMIT 1
) ev ON true
WHERE o.state NOT IN ('closed_won', 'closed_lost');

COMMENT ON VIEW public.routing_v2_ops_view IS
  'LRV2-014 operative dashboard source: one row per active opportunity, state derived from DB only. security_invoker so grants below are the only access path.';

REVOKE ALL ON TABLE public.routing_v2_ops_view FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.routing_v2_ops_view TO service_role;

-- ---------------------------------------------------------------------------
-- 2. KPI function. STABLE, additive, no side effects.
-- ---------------------------------------------------------------------------
-- LANGUAGE plpgsql (not sql): 0029 is a reserved-slot migration number that
-- applies lexically before 0030-0033 (see 0027's comment on the same
-- constraint). A LANGUAGE sql function is validated against the catalog at
-- CREATE time and would fail on conversations.eb_effect_last_error (0033);
-- plpgsql defers that validation to first execution, by which point every
-- migration through 0033 has run.
CREATE OR REPLACE FUNCTION public.get_routing_v2_kpis(p_days_back INT DEFAULT 7)
RETURNS JSONB AS $$
DECLARE
  v_since TIMESTAMPTZ := now() - (p_days_back || ' days')::interval;
  v_avg_detect_deliver NUMERIC;
  v_avg_deliver_accept NUMERIC;
  v_avg_total NUMERIC;
  v_acceptance_by_tier JSONB;
  v_escalations BIGINT;
  v_late_claims BIGINT;
  v_fail_whatsapp BIGINT;
  v_fail_i24 BIGINT;
  v_fail_eb BIGINT;
  v_unassigned_open BIGINT;
  v_unassigned_window BIGINT;
BEGIN
  -- Detection -> delivery uses detected_at and delivered_at only.
  SELECT round(avg(extract(epoch FROM (delivered_at - detected_at))))
    INTO v_avg_detect_deliver
    FROM public.lead_routing_opportunities
   WHERE detected_at >= v_since AND delivered_at IS NOT NULL;

  -- Delivery -> acceptance uses delivered_at and accepted_at only.
  SELECT round(avg(extract(epoch FROM (accepted_at - delivered_at))))
    INTO v_avg_deliver_accept
    FROM public.lead_routing_opportunities
   WHERE detected_at >= v_since AND delivered_at IS NOT NULL AND accepted_at IS NOT NULL;

  SELECT round(avg(extract(epoch FROM (COALESCE(assigned_at, closed_at) - detected_at))))
    INTO v_avg_total
    FROM public.lead_routing_opportunities
   WHERE detected_at >= v_since AND COALESCE(assigned_at, closed_at) IS NOT NULL;

  SELECT COALESCE(jsonb_object_agg(t.routing_tier, t.pct), '{}'::jsonb)
    INTO v_acceptance_by_tier
    FROM (
      SELECT e.routing_tier,
             round(100.0 * count(*) FILTER (WHERE e.event_type = 'claim_accepted')
                   / NULLIF(count(*) FILTER (WHERE e.event_type IN ('claim_accepted', 'late_claim_rejected')), 0), 1) AS pct
        FROM public.lead_routing_events e
       WHERE e.occurred_at >= v_since AND e.routing_tier IS NOT NULL
         AND e.event_type IN ('claim_accepted', 'late_claim_rejected')
       GROUP BY e.routing_tier
    ) t;

  SELECT count(*) INTO v_escalations FROM public.lead_routing_events
   WHERE occurred_at >= v_since AND event_type = 'escalated';
  SELECT count(*) INTO v_late_claims FROM public.lead_routing_events
   WHERE occurred_at >= v_since AND event_type = 'late_claim_rejected';
  SELECT count(*) INTO v_fail_whatsapp FROM public.lead_routing_events
   WHERE occurred_at >= v_since AND event_type = 'delivery_failed';
  SELECT count(*) INTO v_fail_i24 FROM public.lead_routing_events
   WHERE occurred_at >= v_since AND event_type = 'i24_contact_attempt';
  -- ponytail: eb_effect_last_error has no timestamp column (0033), so this
  -- counts current failures rather than failures-in-window. Add a
  -- failed_at column if a windowed count becomes necessary.
  SELECT count(*) INTO v_fail_eb FROM public.conversations WHERE eb_effect_last_error IS NOT NULL;

  SELECT count(*) INTO v_unassigned_open FROM public.lead_routing_opportunities
   WHERE state = 'unassigned_alerted' AND assigned_agent_id IS NULL;
  SELECT count(*) INTO v_unassigned_window FROM public.lead_routing_events
   WHERE occurred_at >= v_since AND event_type = 'unassigned_alerted';

  RETURN jsonb_build_object(
    'generated_at', now(),
    'days', p_days_back,
    'avg_detection_to_delivery_seconds', v_avg_detect_deliver,
    'avg_delivery_to_acceptance_seconds', v_avg_deliver_accept,
    'avg_total_seconds', v_avg_total,
    'acceptance_rate_by_tier', v_acceptance_by_tier,
    'escalations', v_escalations,
    'late_claims', v_late_claims,
    'failures_by_integration', jsonb_build_object(
      'whatsapp', v_fail_whatsapp, 'inmuebles24', v_fail_i24, 'easybroker', v_fail_eb
    ),
    'unassigned_cases_open', v_unassigned_open,
    'unassigned_cases_in_window', v_unassigned_window
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog, public;

COMMENT ON FUNCTION public.get_routing_v2_kpis(INT) IS
  'LRV2-014 KPI snapshot. SLA-adjacent spans use detected_at/delivered_at/accepted_at/assigned_at/closed_at exactly as named; never created_at.';

REVOKE ALL ON FUNCTION public.get_routing_v2_kpis(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_routing_v2_kpis(INT) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Unassigned-case alert dedupe + acknowledge. One incident per opportunity:
--    the contract never auto-reassigns after backup guard fails, so an
--    opportunity can only enter 'unassigned_alerted' once.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.routing_v2_unassigned_alerts (
  alert_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  opportunity_id BIGINT NOT NULL REFERENCES public.lead_routing_opportunities(opportunity_id),
  incident_key TEXT NOT NULL UNIQUE,
  first_alerted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  acknowledged BOOLEAN NOT NULL DEFAULT false,
  acknowledged_at TIMESTAMPTZ,
  acknowledged_by TEXT,
  metadata JSONB
);

COMMENT ON TABLE public.routing_v2_unassigned_alerts IS
  'One row per unassigned-case incident. incident_key = unassigned:<opportunity_id> deduplicates repeated watchdog runs so the immediate email fires exactly once per case.';

CREATE INDEX IF NOT EXISTS routing_v2_unassigned_alerts_open_idx
  ON public.routing_v2_unassigned_alerts (opportunity_id)
  WHERE NOT acknowledged;

ALTER TABLE public.routing_v2_unassigned_alerts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.routing_v2_unassigned_alerts FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.routing_v2_unassigned_alerts FROM service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.routing_v2_unassigned_alerts TO service_role;

REVOKE ALL ON SEQUENCE public.routing_v2_unassigned_alerts_alert_id_seq FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.routing_v2_unassigned_alerts_alert_id_seq FROM service_role;
GRANT USAGE, SELECT ON SEQUENCE public.routing_v2_unassigned_alerts_alert_id_seq TO service_role;

CREATE OR REPLACE FUNCTION public.record_unassigned_alert(
  p_opportunity_id BIGINT,
  p_idempotency_key TEXT
) RETURNS TABLE (alert_id BIGINT, is_new BOOLEAN, acknowledged BOOLEAN) AS $$
DECLARE
  v_incident TEXT;
  v_row public.routing_v2_unassigned_alerts;
BEGIN
  IF p_opportunity_id IS NULL OR NULLIF(btrim(p_idempotency_key), '') IS NULL THEN
    RAISE EXCEPTION 'invalid unassigned alert request';
  END IF;

  PERFORM 1 FROM public.lead_routing_opportunities o
   WHERE o.opportunity_id = p_opportunity_id
     AND o.state = 'unassigned_alerted' AND o.assigned_agent_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'opportunity is not an open unassigned case: %', p_opportunity_id;
  END IF;

  v_incident := 'unassigned:' || p_opportunity_id::text;

  INSERT INTO public.routing_v2_unassigned_alerts (opportunity_id, incident_key)
  VALUES (p_opportunity_id, v_incident)
  ON CONFLICT (incident_key) DO NOTHING
  RETURNING * INTO v_row;

  IF v_row.alert_id IS NULL THEN
    SELECT * INTO v_row FROM public.routing_v2_unassigned_alerts WHERE incident_key = v_incident;
    RETURN QUERY SELECT v_row.alert_id, false, v_row.acknowledged;
    RETURN;
  END IF;

  RETURN QUERY SELECT v_row.alert_id, true, v_row.acknowledged;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.record_unassigned_alert(BIGINT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_unassigned_alert(BIGINT, TEXT) TO service_role;

CREATE OR REPLACE FUNCTION public.acknowledge_unassigned_alert(
  p_opportunity_id BIGINT,
  p_actor_id TEXT
) RETURNS public.routing_v2_unassigned_alerts AS $$
DECLARE
  v_incident TEXT;
  v_row public.routing_v2_unassigned_alerts;
BEGIN
  IF p_opportunity_id IS NULL OR NULLIF(btrim(p_actor_id), '') IS NULL THEN
    RAISE EXCEPTION 'invalid unassigned alert acknowledgement';
  END IF;

  v_incident := 'unassigned:' || p_opportunity_id::text;

  UPDATE public.routing_v2_unassigned_alerts
     SET acknowledged = true, acknowledged_at = NOW(), acknowledged_by = p_actor_id
   WHERE incident_key = v_incident AND NOT acknowledged
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    SELECT * INTO v_row FROM public.routing_v2_unassigned_alerts WHERE incident_key = v_incident;
  END IF;

  IF v_row.alert_id IS NULL THEN
    RAISE EXCEPTION 'no unassigned alert recorded for opportunity: %', p_opportunity_id;
  END IF;

  RETURN v_row;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.acknowledge_unassigned_alert(BIGINT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_unassigned_alert(BIGINT, TEXT) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. weekly_lead_report(): additive only. Same signature/shape as 0020; every
--    existing key is untouched, routing-v2 KPIs are appended under a new
--    'routing_v2' key so both existing consumers (WF17 Build HTML node and
--    src/reporte_semanal/__init__.py) keep working unmodified.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION weekly_lead_report(days_back int DEFAULT 7)
RETURNS jsonb AS $$
WITH p AS (SELECT now() - (days_back || ' days')::interval AS d)
SELECT jsonb_build_object(
  'generated_at', now(),
  'days', days_back,
  'recibidos',    (SELECT count(*) FROM conversations c, p WHERE c.created_at >= p.d),
  'reclamados',   (SELECT count(*) FROM auctions a, p WHERE a.status='claimed'  AND a.created_at >= p.d),
  'no_atendidos', (SELECT count(*) FROM auctions a, p WHERE a.status='expired'  AND a.created_at >= p.d),
  'en_curso',     (SELECT count(*) FROM auctions a, p WHERE a.status='open'     AND a.created_at >= p.d),
  'por_fuente',   (SELECT jsonb_object_agg(source, n) FROM
                     (SELECT c.source, count(*) n FROM conversations c, p WHERE c.created_at >= p.d GROUP BY 1) s),
  'reclamados_por_asesor', (SELECT jsonb_agg(jsonb_build_object('asesor', coalesce(ag.name,'?'), 'n', x.n) ORDER BY x.n DESC)
                     FROM (SELECT winner_agent_id, count(*) n FROM auctions a, p
                           WHERE a.status='claimed' AND a.created_at >= p.d GROUP BY 1) x
                     LEFT JOIN agents ag ON ag.agent_id = x.winner_agent_id),
  'asesores_en_turno', (SELECT count(DISTINCT s.agent_id) FROM agent_schedule s, p
                          WHERE s.schedule_date >= p.d::date),
  'tasa_reclamo_por_asesor', (SELECT jsonb_agg(jsonb_build_object(
                            'asesor', coalesce(ag.name, x.agent_id),
                            'ofertas', x.ofertas,
                            'reclamadas', x.reclamadas,
                            'pct', round(100.0 * x.reclamadas / x.ofertas, 1))
                          ORDER BY (x.reclamadas::numeric / x.ofertas) ASC, x.ofertas DESC)
                     FROM (SELECT ag_id AS agent_id,
                                  count(*) AS ofertas,
                                  count(*) FILTER (WHERE a.status='claimed' AND a.winner_agent_id = ag_id) AS reclamadas
                           FROM auctions a, p, unnest(a.notified_agents) AS ag_id
                           WHERE a.created_at >= p.d
                           GROUP BY ag_id) x
                     LEFT JOIN agents ag ON ag.agent_id = x.agent_id),
  'no_atendidos_lista', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                            'nombre', coalesce(c.lead_name,'(sin nombre)'),
                            'fuente', c.source,
                            'telefono', c.lead_phone,
                            'propiedad', c.current_property,
                            'fecha', to_char(a.created_at,'DD/MM')) ORDER BY a.created_at DESC), '[]'::jsonb)
                     FROM auctions a JOIN conversations c ON c.conversation_id=a.conversation_id, p
                     WHERE a.status='expired' AND a.created_at >= p.d),
  'routing_v2', public.get_routing_v2_kpis(days_back)
) FROM p;
$$ LANGUAGE sql STABLE SECURITY INVOKER SET search_path = pg_catalog, public;
