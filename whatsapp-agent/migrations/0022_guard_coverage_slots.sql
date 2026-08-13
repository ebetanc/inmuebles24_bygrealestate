-- 0022_guard_coverage_slots.sql
-- Explicit primary/backup coverage. Legacy rows with more than one agent per
-- shift remain unranked: priority is never inferred from agent_id.

ALTER TABLE agent_schedule
  ADD COLUMN IF NOT EXISTS coverage_role text;

ALTER TABLE agent_schedule
  DROP CONSTRAINT IF EXISTS agent_schedule_coverage_role_check;

ALTER TABLE agent_schedule
  ADD CONSTRAINT agent_schedule_coverage_role_check
  CHECK (coverage_role IS NULL OR coverage_role IN ('primary', 'backup'));

CREATE UNIQUE INDEX IF NOT EXISTS agent_schedule_coverage_role_uniq
  ON agent_schedule (schedule_date, shift, coverage_role)
  WHERE coverage_role IS NOT NULL;

-- A legacy shift with exactly one agent is unambiguous: that agent is primary.
-- Multiple legacy agents intentionally remain NULL until calendar users choose
-- their ordered coverage explicitly.
WITH single_agent_shifts AS (
  SELECT schedule_date, shift
  FROM agent_schedule
  GROUP BY schedule_date, shift
  HAVING count(*) = 1 AND count(*) FILTER (WHERE coverage_role IS NULL) = 1
)
UPDATE agent_schedule s
SET coverage_role = 'primary'
FROM single_agent_shifts x
WHERE (s.schedule_date, s.shift) = (x.schedule_date, x.shift)
  AND s.coverage_role IS NULL;

CREATE OR REPLACE FUNCTION save_month_schedule(
  p_first_date date,
  p_last_date date,
  p_rows jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  inserted integer;
BEGIN
  IF p_first_date IS NULL OR p_last_date IS NULL
     OR p_first_date > p_last_date
     OR p_last_date - p_first_date > 30 THEN
    RAISE EXCEPTION 'schedule range must contain between 1 and 31 days';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array';
  END IF;

  IF jsonb_array_length(p_rows) > 124 THEN
    RAISE EXCEPTION 'schedule accepts at most two agents per day and shift';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_rows) AS input(row_data)
    WHERE jsonb_typeof(input.row_data) IS DISTINCT FROM 'object'
       OR CASE
            WHEN input.row_data->>'schedule_date' ~ '^\d{4}-\d{2}-\d{2}$'
              THEN (input.row_data->>'schedule_date')::date NOT BETWEEN p_first_date AND p_last_date
            ELSE true
          END
  ) THEN
    RAISE EXCEPTION 'every schedule date must be valid and inside the requested range';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS input(row_data, ordinal)
    LEFT JOIN public.agents a ON a.agent_id = input.row_data->>'agent_id'
    WHERE input.row_data->>'schedule_date' IS NULL
       OR input.row_data->>'shift' NOT IN ('morning', 'afternoon')
       OR input.row_data->>'agent_id' IS NULL
       OR a.agent_id IS NULL
       OR NOT a.is_available
       OR NULLIF(btrim(a.whatsapp_number), '') IS NULL
  ) THEN
    RAISE EXCEPTION 'coverage agents must exist, be active, and have WhatsApp';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS input(row_data, ordinal)
    GROUP BY input.row_data->>'schedule_date', input.row_data->>'shift', input.row_data->>'agent_id'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'primary and backup must be different agents';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS input(row_data, ordinal)
    GROUP BY input.row_data->>'schedule_date', input.row_data->>'shift'
    HAVING count(*) > 2
  ) THEN
    RAISE EXCEPTION 'a shift accepts at most primary and backup coverage';
  END IF;

  DELETE FROM public.agent_schedule
  WHERE schedule_date BETWEEN p_first_date AND p_last_date;

  INSERT INTO public.agent_schedule (schedule_date, shift, agent_id, coverage_role)
  SELECT
    (input.row_data->>'schedule_date')::date,
    input.row_data->>'shift',
    input.row_data->>'agent_id',
    CASE row_number() OVER (
      PARTITION BY input.row_data->>'schedule_date', input.row_data->>'shift'
      ORDER BY input.ordinal
    )
      WHEN 1 THEN 'primary'
      WHEN 2 THEN 'backup'
    END
  FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS input(row_data, ordinal);

  GET DIAGNOSTICS inserted = ROW_COUNT;
  RETURN inserted;
END;
$$;

REVOKE ALL ON FUNCTION save_month_schedule(date, date, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION save_month_schedule(date, date, jsonb) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION save_month_schedule(date, date, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION get_guard_coverage_slots(
  p_schedule_date date DEFAULT (now() AT TIME ZONE 'America/Mexico_City')::date,
  p_shift text DEFAULT current_shift()
)
RETURNS TABLE (
  coverage_role text,
  agent_id text,
  agent_name text,
  whatsapp_number text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
  SELECT s.coverage_role, a.agent_id, a.name, a.whatsapp_number
  FROM public.agent_schedule s
  JOIN public.agents a ON a.agent_id = s.agent_id
  WHERE s.schedule_date = p_schedule_date
    AND s.shift = p_shift
    AND s.coverage_role IN ('primary', 'backup')
    AND a.is_available
    AND NULLIF(btrim(a.whatsapp_number), '') IS NOT NULL
  ORDER BY CASE s.coverage_role WHEN 'primary' THEN 1 WHEN 'backup' THEN 2 END;
$$;

REVOKE ALL ON FUNCTION get_guard_coverage_slots(date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION get_guard_coverage_slots(date, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION get_guard_coverage_slots(date, text) TO service_role;

COMMENT ON COLUMN agent_schedule.coverage_role IS
  'Explicit guard priority: primary then backup. NULL means legacy, unranked coverage.';
COMMENT ON FUNCTION get_guard_coverage_slots(date, text) IS
  'Returns explicit primary then backup coverage. It never derives priority from agent_id.';

-- Manual SQL checks after applying in a non-production database:
-- SELECT * FROM get_guard_coverage_slots('2026-08-12', 'morning');
-- INSERT INTO agent_schedule (schedule_date, shift, agent_id, coverage_role)
-- VALUES ('2026-08-12', 'morning', 'agent_a', 'primary'); -- duplicate role fails
