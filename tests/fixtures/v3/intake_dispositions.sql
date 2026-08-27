-- PROPOSED / NO APLICADO. Local transactional contract fixture only.
BEGIN;
SELECT upsert_routing_opportunity(
  'fixture:event:new',
  '00000000-0000-0000-0000-000000001001'::uuid,
  'EB-FIXTURE-1',
  'i24',
  '{}'::jsonb
);
SELECT enqueue_ready_delivery(1001, 'owner', '2026-08-27T12:00:00Z'::timestamptz, 'fixture:ready:1001');
ROLLBACK;
