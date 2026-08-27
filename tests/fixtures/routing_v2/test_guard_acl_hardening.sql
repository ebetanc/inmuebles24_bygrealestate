\set ON_ERROR_STOP on

BEGIN;

INSERT INTO public.agents(agent_id,name,whatsapp_number,is_available) VALUES
  ('acl_guard_test','ACL Guard','525500000310',true)
ON CONFLICT(agent_id) DO UPDATE SET is_available=true;

SET LOCAL ROLE anon;
DO $$ BEGIN
  IF has_table_privilege(current_user,'public.agent_schedule','SELECT')
     OR has_table_privilege(current_user,'public.agents','SELECT') THEN
    RAISE EXCEPTION 'anon retained direct guard table access';
  END IF;
END $$;
RESET ROLE;

SET LOCAL ROLE authenticated;
DO $$ BEGIN
  IF has_table_privilege(current_user,'public.agent_schedule','SELECT')
     OR has_table_privilege(current_user,'public.agents','SELECT') THEN
    RAISE EXCEPTION 'authenticated retained direct guard table access';
  END IF;
END $$;
RESET ROLE;

SET LOCAL ROLE service_role;
DO $$
DECLARE v_saved INTEGER; v_count INTEGER;
BEGIN
  SELECT public.save_month_schedule(
    (NOW() AT TIME ZONE 'America/Mexico_City')::date,
    (NOW() AT TIME ZONE 'America/Mexico_City')::date,
    jsonb_build_array(jsonb_build_object(
      'schedule_date',(NOW() AT TIME ZONE 'America/Mexico_City')::date::text,
      'shift','morning',
      'agent_id','acl_guard_test'
    ))
  ) INTO v_saved;
  IF v_saved <> 1 THEN RAISE EXCEPTION 'service-role calendar save failed'; END IF;
  SELECT count(*) INTO v_count FROM public.get_guard_coverage_slots(
    (NOW() AT TIME ZONE 'America/Mexico_City')::date, 'morning'
  );
  IF v_count <> 1 THEN RAISE EXCEPTION 'service-role calendar read failed'; END IF;
END $$;
RESET ROLE;

ROLLBACK;
