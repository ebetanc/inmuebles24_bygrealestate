-- Route EasyBroker's exact owner tag "Benjamin" to the existing active owner.
-- Fail closed on configuration drift; never overwrite a conflicting alias.
DO $$
DECLARE
  v_existing_agent_id TEXT;
  v_agent public.agents;
  v_property_id TEXT;
  v_resolution RECORD;
BEGIN
  SELECT * INTO v_agent
  FROM public.agents
  WHERE agent_id = 'agent_benjamin'
  FOR SHARE;

  IF NOT FOUND
     OR v_agent.role IS DISTINCT FROM 'asesor'
     OR v_agent.is_available IS DISTINCT FROM TRUE
     OR NULLIF(BTRIM(v_agent.whatsapp_number), '') IS NULL
     OR BTRIM(v_agent.whatsapp_number) !~ '^\+?[1-9][0-9 ()-]{6,13}[0-9]$'
     OR REGEXP_REPLACE(BTRIM(v_agent.whatsapp_number), '[ +()-]', '', 'g')
          !~ '^[1-9][0-9]{7,14}$'
  THEN
    RAISE EXCEPTION 'agent_benjamin is not an available asesor with a valid WhatsApp number';
  END IF;

  SELECT agent_id INTO v_existing_agent_id
  FROM public.property_agent_alias
  WHERE tag_normalized = 'benjamin'
  FOR UPDATE;

  IF FOUND AND v_existing_agent_id IS DISTINCT FROM 'agent_benjamin' THEN
    RAISE EXCEPTION 'conflicting Benjamin property alias: %', v_existing_agent_id;
  END IF;

  INSERT INTO public.property_agent_alias(tag_normalized, agent_id)
  VALUES ('benjamin', 'agent_benjamin')
  ON CONFLICT (tag_normalized) DO NOTHING;

  FOR v_property_id IN
    SELECT UNNEST(ARRAY['EB-WD0077','EB-JN4740','EB-WB8887']::TEXT[])
  LOOP
    SELECT * INTO v_resolution
    FROM public.resolve_first_property_tag(v_property_id, ARRAY['Benjamin']::TEXT[])
    LIMIT 1;

    IF v_resolution.resolved IS DISTINCT FROM TRUE
       OR v_resolution.owner_agent_id IS DISTINCT FROM 'agent_benjamin'
       OR NULLIF(BTRIM(v_resolution.owner_number), '') IS NULL
    THEN
      RAISE EXCEPTION 'Benjamin owner resolution failed for %', v_property_id;
    END IF;
  END LOOP;
END;
$$;
