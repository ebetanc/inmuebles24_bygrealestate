-- PROPOSED / NO APLICADO. Lease token binds finish/timeout to one worker.
BEGIN;
SELECT finish_delivery_lease(1001, '00000000-0000-0000-0000-000000000001', 'delivered', '{}'::jsonb);
SELECT close_delivery_timeout(1001, 'technical_timeout', '00000000-0000-0000-0000-000000000001', '2026-08-27T12:02:00Z'::timestamptz);
ROLLBACK;
