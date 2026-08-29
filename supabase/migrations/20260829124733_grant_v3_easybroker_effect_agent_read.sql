-- enqueue_v3_easybroker_effect is SECURITY INVOKER and resolves the canonical
-- final responsible from agents. Keep access server-only and read-only.
GRANT SELECT ON TABLE public.agents TO service_role;
