-- Tokko intake, shadow phase: WF25 reads the Tokko lead notices (notifier@tokkobroker.com,
-- forwarded from Marusa's Gmail to esteban.betanc@gmail.com) and records one row per email.
-- Nothing routes from here yet; the rows are compared against i24_capture_events to decide
-- whether Tokko can replace the Pi scraper.
-- Inmuebles24 sends two notices per lead (Consulta + Contacto por Whatsapp, distinct
-- webcontact ids), so one lead is phone + eb_ref, not one row.

CREATE TABLE IF NOT EXISTS public.tokko_shadow_leads (
  gmail_message_id text PRIMARY KEY,
  received_at timestamptz,
  subject text,
  webcontact_id text,
  portal text,
  kind text,
  tags text,
  lead_name text,
  phone text,
  email text,
  eb_ref text,
  i24_listing_id text,
  property_title text,
  message text,
  parse_ok boolean NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.tokko_shadow_leads IS
  'Shadow log of Tokko lead notices read by WF25. One row per email; no routing.';

ALTER TABLE public.tokko_shadow_leads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tokko_shadow_leads FROM anon, authenticated;
GRANT SELECT, INSERT ON public.tokko_shadow_leads TO service_role;
