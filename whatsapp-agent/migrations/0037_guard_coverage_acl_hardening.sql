-- 0037_guard_coverage_acl_hardening.sql
-- Remove the pre-existing direct table access that bypassed the service-role-only RPC contract.
-- Exact rollback to the inspected production prestate (maintenance window only):
--   GRANT ALL PRIVILEGES ON TABLE public.agent_schedule TO anon, authenticated;
--   GRANT ALL PRIVILEGES ON TABLE public.agents TO anon, authenticated;
-- PUBLIC had no privileges in the inspected prestate, so rollback must not grant it anything.

REVOKE ALL ON TABLE public.agent_schedule, public.agents
  FROM PUBLIC, anon, authenticated;
