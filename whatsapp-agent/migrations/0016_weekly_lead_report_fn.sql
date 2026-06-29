-- 0016_weekly_lead_report_fn.sql
-- Weekly management report data source. One JSON blob (summary + unclaimed-lead
-- list + per-agent claims) consumed by the `reporte_semanal` mailer (Pi, Monday
-- 8am). Encapsulates the aggregation so the mailer can fetch it via PostgREST
-- (/rest/v1/rpc/weekly_lead_report) with the service key — no direct DB password.
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
  'asesores_en_turno', (SELECT count(*) FROM agents WHERE role='asesor' AND on_shift),
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
