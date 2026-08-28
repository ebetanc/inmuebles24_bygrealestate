-- V3-09: explicit, operator-authorized retry for a confirmed provider absence.
-- This gate is never consumed by the normal worker: an operator must first
-- authorize the exact capture, then pass p_manual_retry=true to reserve.

ALTER TABLE public.easybroker_contact_request_creation_ledger
  ADD COLUMN IF NOT EXISTS manual_retry_authorized_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS manual_retry_authorized_by TEXT,
  ADD COLUMN IF NOT EXISTS manual_retry_reason TEXT,
  ADD COLUMN IF NOT EXISTS manual_retry_consumed_at TIMESTAMPTZ;

ALTER TABLE public.easybroker_contact_request_creation_ledger
  DROP CONSTRAINT IF EXISTS easybroker_contact_request_creation_le_post_attempt_count_check;
ALTER TABLE public.easybroker_contact_request_creation_ledger
  DROP CONSTRAINT IF EXISTS easybroker_contact_request_creation_ledger_post_attempt_count_check;
ALTER TABLE public.easybroker_contact_request_creation_ledger
  ADD CONSTRAINT easybroker_contact_request_creation_ledger_post_attempt_count_check
  CHECK (post_attempt_count BETWEEN 0 AND 2);

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='easybroker_creation_manual_retry_reason_len'
      AND conrelid='public.easybroker_contact_request_creation_ledger'::regclass
  ) THEN
    ALTER TABLE public.easybroker_contact_request_creation_ledger
      ADD CONSTRAINT easybroker_creation_manual_retry_reason_len
      CHECK (manual_retry_reason IS NULL OR length(manual_retry_reason) BETWEEN 10 AND 240);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='easybroker_creation_manual_retry_audit'
      AND conrelid='public.easybroker_contact_request_creation_ledger'::regclass
  ) THEN
    ALTER TABLE public.easybroker_contact_request_creation_ledger
      ADD CONSTRAINT easybroker_creation_manual_retry_audit CHECK (
        (post_attempt_count < 2 AND manual_retry_consumed_at IS NULL)
        OR (post_attempt_count = 2 AND manual_retry_authorized_at IS NOT NULL
            AND manual_retry_consumed_at IS NOT NULL
            AND NULLIF(BTRIM(manual_retry_authorized_by),'') IS NOT NULL
            AND NULLIF(BTRIM(manual_retry_reason),'') IS NOT NULL)
      );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.authorize_v3_easybroker_request_retry(
  p_capture_event_id BIGINT,
  p_authorized_by TEXT,
  p_reason TEXT,
  p_now TIMESTAMPTZ DEFAULT NOW()
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE r public.easybroker_contact_request_creation_ledger;
BEGIN
  IF p_capture_event_id IS NULL OR NULLIF(BTRIM(p_authorized_by),'') IS NULL
     OR NULLIF(BTRIM(p_reason),'') IS NULL OR length(p_reason) < 10
     OR length(p_reason) > 240 OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid manual EasyBroker retry authorization';
  END IF;
  SELECT * INTO r FROM public.easybroker_contact_request_creation_ledger
    WHERE capture_event_id=p_capture_event_id FOR UPDATE;
  IF NOT FOUND OR r.state <> 'recovery'
     OR r.post_attempt_count <> 1 OR r.remote_request_id IS NOT NULL THEN
    RETURN jsonb_build_object('ok',FALSE,'state','retry_not_eligible',
      'capture_event_id',p_capture_event_id);
  END IF;
  IF r.manual_retry_authorized_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok',TRUE,'state','already_authorized',
      'capture_event_id',p_capture_event_id);
  END IF;
  UPDATE public.easybroker_contact_request_creation_ledger
    SET manual_retry_authorized_at=p_now,
        manual_retry_authorized_by=BTRIM(p_authorized_by),
        manual_retry_reason=BTRIM(p_reason), updated_at=p_now
    WHERE capture_event_id=p_capture_event_id;
  RETURN jsonb_build_object('ok',TRUE,'state','authorized',
    'capture_event_id',p_capture_event_id,'authorized_at',p_now);
END;
$$;

-- Replace the old three-argument implementation. The default preserves the
-- existing worker call shape while making manual retry an explicit argument.
DROP FUNCTION IF EXISTS public.reserve_v3_easybroker_request_creation(BIGINT,UUID,TIMESTAMPTZ);
CREATE FUNCTION public.reserve_v3_easybroker_request_creation(
  p_capture_event_id BIGINT,
  p_lease_token UUID,
  p_now TIMESTAMPTZ DEFAULT NOW(),
  p_manual_retry BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog, public AS $$
DECLARE r public.easybroker_contact_request_creation_ledger;
BEGIN
  IF p_capture_event_id IS NULL OR p_lease_token IS NULL OR p_now IS NULL
     OR p_manual_retry IS NULL THEN
    RAISE EXCEPTION 'invalid EasyBroker creation reservation input';
  END IF;
  SELECT * INTO r FROM public.easybroker_contact_request_creation_ledger
    WHERE capture_event_id=p_capture_event_id FOR UPDATE;
  IF NOT FOUND OR r.state NOT IN ('pending','recovery')
     OR r.lease_token IS DISTINCT FROM p_lease_token
     OR r.lease_expires_at IS NULL OR r.lease_expires_at <= p_now THEN
    RETURN jsonb_build_object('ok',FALSE,'state','lease_conflict','post_allowed',FALSE);
  END IF;
  IF r.post_attempt_count >= 2 THEN
    RETURN jsonb_build_object('ok',TRUE,'state','retry_consumed','post_allowed',FALSE);
  END IF;
  IF p_manual_retry AND NOT (
       r.post_attempt_count=1 AND r.manual_retry_authorized_at IS NOT NULL
       AND r.manual_retry_consumed_at IS NULL AND r.remote_request_id IS NULL
     ) THEN
    RETURN jsonb_build_object('ok',TRUE,'state','retry_not_authorized','post_allowed',FALSE);
  END IF;
  IF NOT p_manual_retry AND r.post_attempt_count=1 THEN
    RETURN jsonb_build_object('ok',TRUE,'state','recovery','post_allowed',FALSE);
  END IF;
  IF EXISTS (SELECT 1 FROM public.easybroker_i24_request_links l
             WHERE l.i24_capture_event_id=p_capture_event_id) THEN
    RETURN jsonb_build_object('ok',TRUE,'state','already_linked','post_allowed',FALSE);
  END IF;
  UPDATE public.easybroker_contact_request_creation_ledger
    SET post_attempt_count=post_attempt_count+1, post_attempted_at=p_now,
        manual_retry_consumed_at=CASE WHEN p_manual_retry THEN p_now
          ELSE manual_retry_consumed_at END,
        updated_at=p_now
    WHERE capture_event_id=p_capture_event_id;
  RETURN jsonb_build_object('ok',TRUE,'state',CASE WHEN p_manual_retry
    THEN 'manual_retry_reserved' ELSE 'reserved' END,'post_allowed',TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.authorize_v3_easybroker_request_retry(BIGINT,TEXT,TEXT,TIMESTAMPTZ),
  public.reserve_v3_easybroker_request_creation(BIGINT,UUID,TIMESTAMPTZ,BOOLEAN)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.authorize_v3_easybroker_request_retry(BIGINT,TEXT,TEXT,TIMESTAMPTZ),
  public.reserve_v3_easybroker_request_creation(BIGINT,UUID,TIMESTAMPTZ,BOOLEAN)
  TO service_role;
