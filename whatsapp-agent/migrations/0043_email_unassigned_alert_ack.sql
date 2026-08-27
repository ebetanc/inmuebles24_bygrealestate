-- 0043_email_unassigned_alert_ack.sql
-- Records a successfully sent final unassigned alert using its real channel.
-- Rollback:
--   DROP FUNCTION IF EXISTS public.complete_unassigned_alert_notification(BIGINT, UUID, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.complete_unassigned_alert_notification(
  p_opportunity_id BIGINT,
  p_lease_token UUID,
  p_channel TEXT,
  p_external_id TEXT
) RETURNS public.routing_v2_unassigned_alerts AS $$
DECLARE
  v_channel TEXT := lower(NULLIF(btrim(p_channel), ''));
  v_external_id TEXT := NULLIF(btrim(p_external_id), '');
  v_row public.routing_v2_unassigned_alerts;
BEGIN
  IF p_opportunity_id IS NULL OR p_lease_token IS NULL
     OR v_channel NOT IN ('email', 'whatsapp')
     OR v_external_id IS NULL THEN
    RAISE EXCEPTION 'invalid unassigned alert notification evidence';
  END IF;

  UPDATE public.routing_v2_unassigned_alerts
  SET acknowledged = TRUE,
      acknowledged_at = now(),
      acknowledged_by = 'wf3c:' || v_channel || ':' || v_external_id,
      lease_token = NULL,
      lease_expires_at = NULL
  WHERE opportunity_id = p_opportunity_id
    AND acknowledged = FALSE
    AND lease_token = p_lease_token
    AND lease_expires_at > now()
  RETURNING * INTO v_row;

  IF v_row.alert_id IS NULL THEN
    RAISE EXCEPTION 'stale or missing unassigned alert lease: %', p_opportunity_id;
  END IF;

  RETURN v_row;
END;
$$ LANGUAGE plpgsql VOLATILE SECURITY INVOKER SET search_path = pg_catalog, public;

REVOKE ALL ON FUNCTION public.complete_unassigned_alert_notification(BIGINT, UUID, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_unassigned_alert_notification(BIGINT, UUID, TEXT, TEXT)
  TO service_role;
