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
    min(a.claimed_at) AS claimed_at,
    -- Clock base for the claim is the delivery of the claimed attempt.
    min(COALESCE(a.delivered_at, a.provider_accepted_at, a.requested_at))
      FILTER (WHERE a.claimed_at IS NOT NULL) AS claim_delivered_at,
    count(*) FILTER (
      WHERE a.delivery_kind = 'offer'
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
  SELECT
    l.opportunity_id,
    bool_or(fx.ok) FILTER (WHERE fx.effect_kind = 'note') AS note_ok,
    max(fx.finished_at) FILTER (WHERE fx.effect_kind = 'note' AND fx.ok) AS note_at,
    bool_or(fx.ok) FILTER (WHERE fx.effect_kind = 'attended') AS attended_ok,
    max(fx.finished_at) FILTER (WHERE fx.effect_kind = 'attended' AND fx.ok) AS attended_at,
    bool_or(NOT fx.ok) AS any_failed
  FROM public.easybroker_i24_request_links l
  JOIN public.easybroker_effect_attempts fx ON fx.eb_request_id = l.eb_request_id
  GROUP BY l.opportunity_id
)
SELECT
  o.opportunity_id,
  o.created_at,
  COALESCE(NULLIF(c.lead_name, ''), cap.offer_context->>'lead_name') AS lead_name,
  COALESCE(NULLIF(c.lead_phone, ''), cap.offer_context->>'lead_phone', o.e164_phone) AS lead_phone,
  o.property_id,
  COALESCE(cap.offer_context->>'property_title', c.current_property) AS property_title,
  cap.offer_context->>'easybroker_url' AS easybroker_url,
  o.state,
  o.routing_tier,
  o.assigned_agent_id,
  ag.name AS assigned_name,
  ag.role AS assigned_role,
  o.assigned_at,
  CASE
    WHEN att.claimed_at IS NOT NULL THEN 'claim'
    WHEN ev.manager_assigned THEN 'sandy_fallback'
    ELSE NULL
  END AS assignment_method,
  CASE
    WHEN att.claimed_at IS NOT NULL AND att.claim_delivered_at IS NOT NULL
      THEN round(EXTRACT(EPOCH FROM (att.claimed_at - att.claim_delivered_at)) / 60.0)::int
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
WHERE o.v3_enabled;

COMMENT ON VIEW public.v3_leads_dashboard IS
  'Read-only flattened V3 lead view for the dashboard (/leads-v3). Derived from lead_routing_* , i24_capture_events and easybroker_effect_attempts; never written to.';

REVOKE ALL ON TABLE public.v3_leads_dashboard FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.v3_leads_dashboard TO authenticated;
GRANT SELECT ON TABLE public.v3_leads_dashboard TO service_role;
