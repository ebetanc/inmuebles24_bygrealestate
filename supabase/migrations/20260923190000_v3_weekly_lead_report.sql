-- WF17 (Monday email to management) still read V1 tables (conversations,
-- auctions) that V3 no longer fills: it reported 0 leads for a week with 65.
-- Same JSON shape the WF17 "Build HTML" node reads, now from v3_leads_dashboard.
-- routing_v2 is empty: the V2 shadow pilot is retired.
-- The report carries lead names and phones: only postgres/service_role run it.
CREATE OR REPLACE FUNCTION public.weekly_lead_report(days_back integer DEFAULT 7)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
WITH p AS (SELECT now() - (days_back || ' days')::interval AS d),
l AS (SELECT v.*, COALESCE(o.v3_source,'inmuebles24') AS fuente
      FROM v3_leads_dashboard v
      JOIN lead_routing_opportunities o USING (opportunity_id), p
      WHERE v.created_at >= p.d)
SELECT jsonb_build_object(
  'generated_at', now(),
  'days', days_back,
  'recibidos',    (SELECT count(*) FROM l),
  'reclamados',   (SELECT count(*) FROM l WHERE assigned_agent_id IS NOT NULL),
  'no_atendidos', (SELECT count(*) FROM l WHERE state='unassigned'),
  'en_curso',     (SELECT count(*) FROM l WHERE assigned_agent_id IS NULL AND state<>'unassigned'),
  'por_fuente',   (SELECT jsonb_object_agg(fuente, n) FROM (SELECT fuente, count(*) n FROM l GROUP BY 1) s),
  'reclamados_por_asesor', (SELECT jsonb_agg(jsonb_build_object('asesor', coalesce(assigned_name,'?'), 'n', n) ORDER BY n DESC)
                     FROM (SELECT assigned_name, count(*) n FROM l WHERE assigned_agent_id IS NOT NULL GROUP BY 1) x),
  'asesores_en_turno', (SELECT count(DISTINCT s.agent_id) FROM agent_schedule s, p
                          WHERE s.schedule_date >= p.d::date),
  'tasa_reclamo_por_asesor', (SELECT jsonb_agg(jsonb_build_object(
                            'asesor', coalesce(ag.name, x.agent_id),
                            'ofertas', x.ofertas,
                            'reclamadas', x.reclamadas,
                            'pct', round(100.0 * x.reclamadas / x.ofertas, 1))
                          ORDER BY (x.reclamadas::numeric / x.ofertas) ASC, x.ofertas DESC)
                     FROM (SELECT a.target_agent_id AS agent_id,
                                  count(DISTINCT a.opportunity_id) AS ofertas,
                                  count(DISTINCT a.opportunity_id) FILTER (WHERE l.assigned_agent_id = a.target_agent_id) AS reclamadas
                           FROM lead_routing_delivery_attempts a JOIN l USING (opportunity_id)
                           WHERE a.delivery_kind='offer' AND a.delivered_at IS NOT NULL
                           GROUP BY 1) x
                     LEFT JOIN agents ag ON ag.agent_id = x.agent_id),
  'no_atendidos_lista', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                            'nombre', coalesce(lead_name,'(sin nombre)'),
                            'fuente', fuente,
                            'telefono', lead_phone,
                            'propiedad', property_id,
                            'fecha', to_char(created_at AT TIME ZONE 'America/Mexico_City','DD/MM')) ORDER BY created_at DESC), '[]'::jsonb)
                     FROM l WHERE state='unassigned'),
  'routing_v2', '{}'::jsonb
) FROM p;
$function$;
REVOKE ALL ON FUNCTION public.weekly_lead_report(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.weekly_lead_report(integer) TO service_role;
