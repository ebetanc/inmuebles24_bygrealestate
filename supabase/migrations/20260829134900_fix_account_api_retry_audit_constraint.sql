-- Forward fix: extend the existing manual-retry audit invariant for the one
-- restricted account-API retry introduced for captures 107/108.
ALTER TABLE public.easybroker_contact_request_creation_ledger
  DROP CONSTRAINT IF EXISTS easybroker_creation_manual_retry_audit;
ALTER TABLE public.easybroker_contact_request_creation_ledger
  ADD CONSTRAINT easybroker_creation_manual_retry_audit CHECK (
    (
      post_attempt_count < 2
      AND manual_retry_consumed_at IS NULL
      AND account_api_retry_consumed_at IS NULL
    ) OR (
      post_attempt_count = 2
      AND manual_retry_authorized_at IS NOT NULL
      AND manual_retry_consumed_at IS NOT NULL
      AND NULLIF(BTRIM(manual_retry_authorized_by), '') IS NOT NULL
      AND NULLIF(BTRIM(manual_retry_reason), '') IS NOT NULL
      AND account_api_retry_consumed_at IS NULL
    ) OR (
      post_attempt_count = 3
      AND capture_event_id IN (107, 108)
      AND manual_retry_authorized_at IS NOT NULL
      AND manual_retry_consumed_at IS NOT NULL
      AND NULLIF(BTRIM(manual_retry_authorized_by), '') IS NOT NULL
      AND NULLIF(BTRIM(manual_retry_reason), '') IS NOT NULL
      AND account_api_retry_authorized_at IS NOT NULL
      AND account_api_retry_consumed_at IS NOT NULL
      AND NULLIF(BTRIM(account_api_retry_authorized_by), '') IS NOT NULL
      AND NULLIF(BTRIM(account_api_retry_reason), '') IS NOT NULL
    )
  );
