-- PROPOSED / NO APLICADO. Two workers must yield one durable winner.
BEGIN;
SELECT claim_ready_delivery(2, INTERVAL '2 minutes', '2026-08-27T12:00:00Z'::timestamptz);
SELECT claim_ready_delivery(2, INTERVAL '2 minutes', '2026-08-27T12:00:00Z'::timestamptz);
ROLLBACK;
