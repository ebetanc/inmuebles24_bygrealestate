-- 0020_weekly_report_claim_rate.sql
-- Adds a per-agent auction claim-rate section to weekly_lead_report() so
-- management (Marusa/Sandy) can see WHO isn't claiming, not just the
-- aggregate rate. Additive only: same signature/return type, existing keys
-- unchanged, new key appended. Both consumers (n8n WF17 "Build HTML" code
-- node and src/reporte_semanal/__init__.py render_html) read named keys off
-- the jsonb object and ignore unknown ones, so an added key is safe without
-- touching either consumer.
--
-- Base: pg_get_functiondef(weekly_lead_report) as it actually runs in prod
-- (this had already drifted from migration 0016's file: 'asesores_en_turno'
-- moved from agents.on_shift to agent_schedule — kept as-is here).
--
-- Data source: auctions.notified_agents (text[], populated by WF3a for every
-- tier notified: owner/guard/manager) gives a real, queryable per-agent
-- notification count — confirmed non-empty in prod (e.g. agent_gina: 33
-- notified / 10 claimed last 14 days). Used directly; the owner-column
-- fallback described in the task isn't needed.
CREATE OR REPLACE FUNCTION weekly_lead_report(days_back int DEFAULT 7)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
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
                     WHERE a.status='expired' AND a.created_at >= p.d)
) FROM p;
$$;
