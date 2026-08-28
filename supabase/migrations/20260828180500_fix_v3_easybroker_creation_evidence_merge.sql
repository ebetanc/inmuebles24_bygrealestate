-- Preserve prior response evidence when finishing the EasyBroker creation ledger.
-- This is a forward-only replacement of the existing RPC contract.
CREATE OR REPLACE FUNCTION public.finish_v3_easybroker_request_creation(
  p_capture_event_id BIGINT,
  p_lease_token UUID,
  p_state TEXT,
  p_remote_request_id BIGINT DEFAULT NULL,
  p_evidence JSONB DEFAULT '{}'::JSONB,
  p_error TEXT DEFAULT NULL,
  p_preexisting BOOLEAN DEFAULT FALSE,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE r public.easybroker_contact_request_creation_ledger;
BEGIN
  IF p_capture_event_id IS NULL OR p_lease_token IS NULL OR p_now IS NULL
     OR p_preexisting IS NULL
     OR p_state NOT IN ('created','recovery','manual_review')
     OR length(COALESCE(p_error,'')) > 120
     OR (p_state='created' AND (p_remote_request_id IS NULL OR NOT p_preexisting
         OR p_evidence->>'correlation_state' NOT IN ('linked','already_linked')))
     OR (p_state='manual_review' AND NULLIF(BTRIM(p_error),'') IS NULL) THEN
    RAISE EXCEPTION 'invalid EasyBroker creation result';
  END IF;
  SELECT * INTO r
  FROM public.easybroker_contact_request_creation_ledger
  WHERE capture_event_id=p_capture_event_id FOR UPDATE;
  IF NOT FOUND OR r.state NOT IN ('pending','recovery') OR r.lease_token IS DISTINCT FROM p_lease_token
     OR r.lease_expires_at IS NULL OR r.lease_expires_at <= p_now THEN
    RETURN jsonb_build_object('ok',FALSE,'state','lease_conflict',
      'capture_event_id',p_capture_event_id);
  END IF;
  UPDATE public.easybroker_contact_request_creation_ledger
  SET state=p_state, remote_request_id=COALESCE(p_remote_request_id,remote_request_id),
      response_evidence=response_evidence || COALESCE(p_evidence,'{}'::JSONB),
      last_error=NULLIF(BTRIM(p_error),''), lease_token=NULL,
      lease_expires_at=NULL, updated_at=p_now
  WHERE capture_event_id=p_capture_event_id;
  RETURN jsonb_build_object('ok',TRUE,'state',p_state,
    'capture_event_id',p_capture_event_id,
    'remote_request_id',p_remote_request_id,'changed_at',p_now);
END;
$$;

REVOKE ALL ON FUNCTION public.finish_v3_easybroker_request_creation(BIGINT,UUID,TEXT,BIGINT,JSONB,TEXT,BOOLEAN,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finish_v3_easybroker_request_creation(BIGINT,UUID,TEXT,BIGINT,JSONB,TEXT,BOOLEAN,TIMESTAMPTZ)
  TO service_role;
