-- One audited account-API retry for captures 107/108. Their first two HTTP
-- 200 responses came from the superseded endpoint and produced no request in
-- EasyBroker GET or Buzon. This gate is deliberately restricted to those IDs.
ALTER TABLE public.easybroker_contact_request_creation_ledger
  ADD COLUMN IF NOT EXISTS account_api_retry_authorized_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS account_api_retry_authorized_by TEXT,
  ADD COLUMN IF NOT EXISTS account_api_retry_reason TEXT,
  ADD COLUMN IF NOT EXISTS account_api_retry_consumed_at TIMESTAMPTZ;

ALTER TABLE public.easybroker_contact_request_creation_ledger
  DROP CONSTRAINT IF EXISTS easybroker_contact_request_creation_ledger_post_attempt_count_c;
ALTER TABLE public.easybroker_contact_request_creation_ledger
  DROP CONSTRAINT IF EXISTS easybroker_contact_request_creation_ledger_post_attempt_count_check;
ALTER TABLE public.easybroker_contact_request_creation_ledger
  DROP CONSTRAINT IF EXISTS eb_creation_post_attempt_count_check;
ALTER TABLE public.easybroker_contact_request_creation_ledger
  ADD CONSTRAINT eb_creation_post_attempt_count_check
  CHECK (post_attempt_count BETWEEN 0 AND 3);

CREATE OR REPLACE FUNCTION public.authorize_v3_easybroker_account_api_retry(
  p_capture_event_id BIGINT,
  p_authorized_by TEXT,
  p_reason TEXT,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE r public.easybroker_contact_request_creation_ledger;
BEGIN
  IF p_capture_event_id NOT IN (107, 108)
     OR NULLIF(BTRIM(p_authorized_by), '') IS NULL
     OR NULLIF(BTRIM(p_reason), '') IS NULL
     OR length(p_reason) < 20 OR length(p_reason) > 300 OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid account API retry authorization';
  END IF;
  SELECT * INTO r
  FROM public.easybroker_contact_request_creation_ledger
  WHERE capture_event_id = p_capture_event_id
  FOR UPDATE;
  IF NOT FOUND OR r.state <> 'recovery' OR r.post_attempt_count <> 2
     OR r.remote_request_id IS NOT NULL
     OR EXISTS (
       SELECT 1 FROM public.easybroker_i24_request_links l
       WHERE l.i24_capture_event_id = p_capture_event_id
     ) THEN
    RETURN jsonb_build_object('ok', FALSE, 'state', 'retry_not_eligible',
      'capture_event_id', p_capture_event_id);
  END IF;
  IF r.account_api_retry_authorized_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', TRUE, 'state', 'already_authorized',
      'capture_event_id', p_capture_event_id);
  END IF;
  UPDATE public.easybroker_contact_request_creation_ledger
  SET account_api_retry_authorized_at = p_now,
      account_api_retry_authorized_by = BTRIM(p_authorized_by),
      account_api_retry_reason = BTRIM(p_reason),
      updated_at = p_now
  WHERE capture_event_id = p_capture_event_id;
  RETURN jsonb_build_object('ok', TRUE, 'state', 'authorized',
    'capture_event_id', p_capture_event_id, 'authorized_at', p_now);
END;
$$;

CREATE OR REPLACE FUNCTION public.reserve_v3_easybroker_account_api_retry(
  p_capture_event_id BIGINT,
  p_lease_token UUID,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE r public.easybroker_contact_request_creation_ledger;
BEGIN
  IF p_capture_event_id NOT IN (107, 108) OR p_lease_token IS NULL OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid account API retry reservation';
  END IF;
  SELECT * INTO r
  FROM public.easybroker_contact_request_creation_ledger
  WHERE capture_event_id = p_capture_event_id
  FOR UPDATE;
  IF NOT FOUND OR r.state <> 'recovery' OR r.post_attempt_count <> 2
     OR r.remote_request_id IS NOT NULL
     OR r.account_api_retry_authorized_at IS NULL
     OR r.account_api_retry_consumed_at IS NOT NULL
     OR r.lease_token IS DISTINCT FROM p_lease_token
     OR r.lease_expires_at IS NULL OR r.lease_expires_at <= p_now
     OR EXISTS (
       SELECT 1 FROM public.easybroker_i24_request_links l
       WHERE l.i24_capture_event_id = p_capture_event_id
     ) THEN
    RETURN jsonb_build_object('ok', FALSE, 'state', 'retry_not_eligible',
      'post_allowed', FALSE);
  END IF;
  UPDATE public.easybroker_contact_request_creation_ledger
  SET post_attempt_count = 3,
      post_attempted_at = p_now,
      account_api_retry_consumed_at = p_now,
      updated_at = p_now
  WHERE capture_event_id = p_capture_event_id;
  RETURN jsonb_build_object('ok', TRUE, 'state', 'account_api_retry_reserved',
    'post_allowed', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.authorize_v3_easybroker_account_api_retry(
  BIGINT, TEXT, TEXT, TIMESTAMPTZ),
  public.reserve_v3_easybroker_account_api_retry(BIGINT, UUID, TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.authorize_v3_easybroker_account_api_retry(
  BIGINT, TEXT, TEXT, TIMESTAMPTZ),
  public.reserve_v3_easybroker_account_api_retry(BIGINT, UUID, TIMESTAMPTZ)
  TO service_role;
