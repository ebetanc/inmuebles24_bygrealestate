-- Forward fix: PostgreSQL truncated the original inline CHECK name differently
-- than the explicit V3-09 replacement. Remove the surviving one-attempt check.
ALTER TABLE public.easybroker_contact_request_creation_ledger
  DROP CONSTRAINT IF EXISTS easybroker_contact_request_creation_le_post_attempt_count_check;

-- Fail closed if the intended two-attempt cap is not present.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid='public.easybroker_contact_request_creation_ledger'::regclass
      AND conname='easybroker_contact_request_creation_ledger_post_attempt_count_c'
      AND pg_get_constraintdef(oid) LIKE '%post_attempt_count <= 2%'
  ) THEN
    RAISE EXCEPTION 'two-attempt EasyBroker retry constraint is missing';
  END IF;
END;
$$;
