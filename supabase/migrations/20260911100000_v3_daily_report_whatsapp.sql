-- 20260911100000_v3_daily_report_whatsapp.sql
-- The WF24 daily V3 report also goes out over WhatsApp: who receives it
-- (v3_report_recipients), the full text kept so the "Ver detalle" button can
-- fetch it later (v3_daily_reports, one row per day, upserted) and one row per
-- provider attempt (v3_report_sends). No routing logic, no side effects.
-- Rollback: DROP TABLE public.v3_report_sends, public.v3_daily_reports,
--           public.v3_report_recipients;

CREATE TABLE IF NOT EXISTS public.v3_report_recipients (
  -- E.164 digits without '+', same shape as agents.whatsapp_number.
  phone text PRIMARY KEY CHECK (phone ~ '^[1-9][0-9]{7,14}$'),
  name text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.v3_report_recipients ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.v3_daily_reports (
  report_date date PRIMARY KEY,
  text_chunks text[] NOT NULL,
  summary jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.v3_daily_reports ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.v3_report_sends (
  id bigserial PRIMARY KEY,
  report_date date NOT NULL REFERENCES public.v3_daily_reports(report_date),
  phone text NOT NULL,
  wamid text,
  status text NOT NULL CHECK (status IN ('accepted','failed')),
  error text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.v3_report_sends ENABLE ROW LEVEL SECURITY;

GRANT SELECT,INSERT,UPDATE ON public.v3_report_recipients, public.v3_daily_reports, public.v3_report_sends TO service_role;
GRANT USAGE,SELECT ON SEQUENCE public.v3_report_sends_id_seq TO service_role;

-- Esteban first; client numbers are added later with a plain INSERT.
INSERT INTO public.v3_report_recipients(phone,name) VALUES ('33628457768','Esteban') ON CONFLICT DO NOTHING;
