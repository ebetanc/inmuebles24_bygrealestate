-- PROPOSED / NO APLICADO. Exact request ID; no phone/name heuristic.
BEGIN;
SELECT correlate_easybroker_request(900000001::bigint, 1001, 'fixture:correlation:1', '{}'::jsonb);
ROLLBACK;
