-- Allow an exact first-property-tag alias to resolve its configured owner even
-- when that agent also has the manager role. This is not a manager fallback:
-- availability and a valid WhatsApp number remain mandatory.
-- Rollback: reapply the resolve_first_property_tag body from migration 0025.

CREATE OR REPLACE FUNCTION public.resolve_first_property_tag(
  p_property_public_id text,
  p_tags text[]
) RETURNS TABLE (
  resolved boolean,
  reason text,
  failure_detail text,
  observed_tag text,
  owner_agent_id text,
  owner_name text,
  owner_number text
) AS $$
DECLARE
  v_code text := NULLIF(upper(btrim(p_property_public_id)), '');
  v_tag text := NULLIF(lower(btrim(p_tags[1])), '');
  v_agent public.agents;
BEGIN
  resolved := false;
  reason := 'missing_owner_data';
  observed_tag := NULLIF(btrim(p_tags[1]), '');

  IF v_code IS NULL OR v_code !~ '^EB-[A-Z0-9]{4,}$' THEN failure_detail := 'missing_code'; RETURN NEXT; RETURN; END IF;
  IF v_tag IS NULL THEN failure_detail := 'missing_tag'; RETURN NEXT; RETURN; END IF;

  SELECT a.* INTO v_agent
  FROM public.property_agent_alias alias
  JOIN public.agents a ON a.agent_id = alias.agent_id
  WHERE alias.tag_normalized = v_tag;

  IF NOT FOUND THEN failure_detail := 'missing_alias'; RETURN NEXT; RETURN; END IF;
  IF NOT v_agent.is_available THEN failure_detail := 'inactive_agent'; RETURN NEXT; RETURN; END IF;
  IF NULLIF(btrim(v_agent.whatsapp_number), '') IS NULL
     OR btrim(v_agent.whatsapp_number) !~ '^\+?[1-9][0-9 ()-]{6,13}[0-9]$'
     OR regexp_replace(btrim(v_agent.whatsapp_number), '[ +()-]', '', 'g') !~ '^[1-9][0-9]{7,14}$'
  THEN failure_detail := 'missing_phone'; RETURN NEXT; RETURN; END IF;

  resolved := true;
  reason := 'resolved';
  failure_detail := NULL;
  owner_agent_id := v_agent.agent_id;
  owner_name := v_agent.name;
  owner_number := regexp_replace(btrim(v_agent.whatsapp_number), '[ +()-]', '', 'g');
  RETURN NEXT;
END;
$$ LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.resolve_first_property_tag(text,text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_first_property_tag(text,text[]) TO service_role;
