-- Repository-owned prerequisite for WF10's idempotent conversation UPSERT.
-- Emergency rollback (only after WF10 stops using this conflict target):
-- DROP INDEX IF EXISTS public.conversations_i24_lead_id_uniq;

CREATE UNIQUE INDEX IF NOT EXISTS conversations_i24_lead_id_uniq
  ON public.conversations (i24_lead_id)
  WHERE i24_lead_id IS NOT NULL;
