-- stuck_offers must ignore attempts already closed as failed (they showed as
-- 'Oferta pedida hace mas de 3 min sin enviar' forever) and the EasyBroker
-- columns must reflect the ledger's final state, not any historical failure.
-- 20260902120000_v3_leads_dashboard_view.sql
-- READ-ONLY. One row per V3 opportunity, flattened for the Next.js dashboard
-- (/leads-v3). No new routing logic, no writes, no side effects: every value is
-- derived from what the V3 engine already persisted (opportunities, delivery
-- attempts, events, i24 capture events, EasyBroker effect attempts).
-- Same join logic as the WF24 monitor email (whatsapp-agent/workflows/build_wf24_monitor.py).
-- Rollback: DROP VIEW public.v3_leads_dashboard;

CREATE OR REPLACE VIEW public.v3_leads_dashboard
WITH (security_invoker = true) AS
WITH att AS (
  -- WhatsApp delivery per tier + the attempt that was actually claimed.
  SELECT
    a.opportunity_id,
    max(a.delivered_at) FILTER (
      WHERE a.delivery_kind = 'offer' AND a.routing_tier = 'owner'
    ) AS owner_offer_delivered_at,
    max(a.delivered_at) FILTER (
      WHERE a.delivery_kind = 'offer' AND a.routing_tier IN ('primary_guard', 'backup_guard')
    ) AS guard_offer_delivered_at,
    max(a.delivered_at) FILTER (
      WHERE a.delivery_kind = 'assigned_notice'
    ) AS sandy_notice_delivered_at,
    -- NOTE: a.claimed_at is the sender's lease (WF13/WF23), NOT the human click.
    -- The human click lives in lead_routing_opportunities.accepted_at (see ca below).
    count(*) FILTER (
      WHERE a.delivery_kind = 'offer'
        AND a.status = 'requested'
        AND a.provider_accepted_at IS NULL
        AND a.requested_at < now() - interval '3 minutes'
    ) AS stuck_offers
  FROM public.lead_routing_delivery_attempts a
  GROUP BY a.opportunity_id
),
ev AS (
  SELECT
    e.opportunity_id,
    bool_or(e.event_type = 'manager_assigned') AS manager_assigned
  FROM public.lead_routing_events e
  GROUP BY e.opportunity_id
),
eb AS (
  -- EasyBroker side effects (nota RESPONSABLE + marcar Atendida).
  -- Final state comes from the ledger; attempts only give the timestamps, so a
  -- retried or manually reconciled effect no longer reads as failed.
  SELECT
    l.opportunity_id,
    bool_or(lg.note_state = 'succeeded') AS note_ok,
    max(fx.finished_at) FILTER (WHERE fx.effect_kind = 'note' AND fx.ok) AS note_at,
    bool_or(lg.attended_state = 'succeeded') AS attended_ok,
    max(fx.finished_at) FILTER (WHERE fx.effect_kind = 'attended' AND fx.ok) AS attended_at,
    bool_or(lg.close_state IN ('manual_review', 'exhausted')) AS any_failed
  FROM public.easybroker_i24_request_links l
  JOIN public.easybroker_effect_ledger lg ON lg.eb_request_id = l.eb_request_id
  LEFT JOIN public.easybroker_effect_attempts fx ON fx.eb_request_id = l.eb_request_id
  GROUP BY l.opportunity_id
)
SELECT
  o.opportunity_id,
  o.created_at,
  COALESCE(NULLIF(c.lead_name, ''), NULLIF(cap.offer_context->>'name', ''), cap.offer_context->>'lead_name') AS lead_name,
  COALESCE(NULLIF(c.lead_phone, ''), o.e164_phone, cap.offer_context->>'phone', cap.offer_context->>'lead_phone') AS lead_phone,
  o.property_id,
  COALESCE(cap.offer_context->>'property_title',
           NULLIF(concat_ws(' · ', cap.offer_context->>'property', cap.offer_context->>'address'), ''),
           c.current_property) AS property_title,
  cap.offer_context->>'easybroker_url' AS easybroker_url,
  o.state,
  o.routing_tier,
  o.assigned_agent_id,
  ag.name AS assigned_name,
  ag.role AS assigned_role,
  o.assigned_at,
  CASE
    WHEN o.accepted_at IS NOT NULL THEN 'claim'
    WHEN ev.manager_assigned OR o.external_evidence->>'v3_final_route' = 'sandy' THEN 'sandy_fallback'
    WHEN o.assigned_agent_id IS NOT NULL THEN 'direct'
    ELSE NULL
  END AS assignment_method,
  CASE
    WHEN o.accepted_at IS NOT NULL AND ca.delivered_base IS NOT NULL
      THEN round(EXTRACT(EPOCH FROM (o.accepted_at - ca.delivered_base)) / 60.0)::int
    ELSE NULL
  END AS minutes_to_claim,
  att.owner_offer_delivered_at,
  att.guard_offer_delivered_at,
  att.sandy_notice_delivered_at,
  eb.note_ok AS eb_note_ok,
  eb.note_at AS eb_note_at,
  eb.attended_ok AS eb_attended_ok,
  eb.attended_at AS eb_attended_at,
  o.v3_night_queued_at AS night_queued_at,
  o.v3_night_released_at AS night_released_at,
  cap.route_dispatch_status AS dispatch_status,
  -- One human-readable reason, highest severity first. NULL = nothing wrong.
  (CASE
    WHEN cap.route_dispatch_status = 'manual_review'
      THEN 'En revision manual (sin ID EasyBroker): nadie la va a recibir'
    WHEN COALESCE(att.stuck_offers, 0) > 0
      THEN 'Oferta pedida hace mas de 3 min sin enviar'
    WHEN o.assigned_agent_id IS NULL
         AND o.expires_at IS NOT NULL
         AND o.expires_at < now() - interval '2 minutes'
      THEN 'Oferta vencida sin escalar'
    WHEN eb.any_failed
      THEN 'Efecto EasyBroker fallido (nota o Atendida)'
    ELSE NULL
  END) AS problem_reason,
  (cap.route_dispatch_status = 'manual_review'
    OR COALESCE(att.stuck_offers, 0) > 0
    OR (o.assigned_agent_id IS NULL
        AND o.expires_at IS NOT NULL
        AND o.expires_at < now() - interval '2 minutes')
    OR COALESCE(eb.any_failed, false)) AS has_problem
FROM public.lead_routing_opportunities o
LEFT JOIN public.agents ag ON ag.agent_id = o.assigned_agent_id
LEFT JOIN public.conversations c ON c.conversation_id = o.conversation_id
LEFT JOIN att ON att.opportunity_id = o.opportunity_id
LEFT JOIN ev ON ev.opportunity_id = o.opportunity_id
LEFT JOIN eb ON eb.opportunity_id = o.opportunity_id
LEFT JOIN LATERAL (
  SELECT e.offer_context, e.route_dispatch_status
  FROM public.i24_capture_events e
  WHERE e.opportunity_id = o.opportunity_id
  ORDER BY e.capture_event_id DESC
  LIMIT 1
) cap ON true
LEFT JOIN LATERAL (
  -- The offer addressed to the agent who ended up assigned: its delivery is the claim clock base.
  SELECT COALESCE(a.delivered_at, a.provider_accepted_at, a.requested_at) AS delivered_base
  FROM public.lead_routing_delivery_attempts a
  WHERE a.opportunity_id = o.opportunity_id
    AND a.delivery_kind = 'offer'
    AND a.target_agent_id = o.assigned_agent_id
  ORDER BY a.requested_at DESC
  LIMIT 1
) ca ON true
WHERE o.v3_enabled;

COMMENT ON VIEW public.v3_leads_dashboard IS
  'Read-only flattened V3 lead view for the dashboard (/leads-v3). Derived from lead_routing_* , i24_capture_events and easybroker_effect_attempts; never written to.';

REVOKE ALL ON TABLE public.v3_leads_dashboard FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.v3_leads_dashboard TO authenticated;
GRANT SELECT ON TABLE public.v3_leads_dashboard TO service_role;
