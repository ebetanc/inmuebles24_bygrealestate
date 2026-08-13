-- LRV2-012: serialize EasyBroker note/status UI effects across workers.
-- Emergency rollback (approved runbook only):
-- DROP FUNCTION public.finish_easybroker_attend_effect(uuid,uuid,boolean,boolean,text,timestamptz);
-- DROP FUNCTION public.claim_easybroker_attend_effects(integer,timestamptz);
-- DROP INDEX public.idx_conversations_eb_effect_claimable;
-- ALTER TABLE public.conversations
--   DROP COLUMN IF EXISTS eb_effect_last_error,
--   DROP COLUMN IF EXISTS eb_effect_attempts,
--   DROP COLUMN IF EXISTS eb_effect_lease_expires_at,
--   DROP COLUMN IF EXISTS eb_effect_lease_token;
ALTER TABLE public.conversations
  ADD COLUMN IF NOT EXISTS eb_effect_lease_token UUID,
  ADD COLUMN IF NOT EXISTS eb_effect_lease_expires_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS eb_effect_attempts INTEGER NOT NULL DEFAULT 0 CHECK (eb_effect_attempts >= 0),
  ADD COLUMN IF NOT EXISTS eb_effect_last_error TEXT;

CREATE INDEX IF NOT EXISTS idx_conversations_eb_effect_claimable
  ON public.conversations (eb_effect_lease_expires_at, conversation_id)
  WHERE eb_contact_id IS NOT NULL
    AND assigned_agent_id IS NOT NULL
    AND (eb_note_added = false OR eb_marked_attended = false);

CREATE OR REPLACE FUNCTION public.claim_easybroker_attend_effects(
  p_limit INTEGER DEFAULT 20,
  p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE(
  conversation_id UUID,
  lead_phone TEXT,
  lead_name TEXT,
  assigned_agent_id TEXT,
  eb_contact_id BIGINT,
  eb_note_added BOOLEAN,
  eb_marked_attended BOOLEAN,
  lease_token UUID
) AS $$
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 OR p_now IS NULL THEN
    RAISE EXCEPTION 'invalid EasyBroker effect claim input';
  END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT c.conversation_id
    FROM public.conversations c
    WHERE c.eb_contact_id IS NOT NULL
      AND c.assigned_agent_id IS NOT NULL
      AND (c.claimed_via IS NULL OR c.claimed_via <> 'escalation' OR c.first_response_at IS NOT NULL)
      AND (c.eb_note_added = false OR c.eb_marked_attended = false)
      AND (c.eb_effect_lease_token IS NULL
           OR COALESCE(c.eb_effect_lease_expires_at, '-infinity'::timestamptz) <= p_now)
    ORDER BY c.created_at, c.conversation_id
    FOR UPDATE OF c SKIP LOCKED
    LIMIT p_limit
  ), claimed AS (
    UPDATE public.conversations c
    SET eb_effect_lease_token = gen_random_uuid(),
        eb_effect_lease_expires_at = p_now + INTERVAL '15 minutes',
        eb_effect_attempts = c.eb_effect_attempts + 1,
        eb_effect_last_error = NULL
    FROM candidates q
    WHERE c.conversation_id = q.conversation_id
    RETURNING c.conversation_id, c.lead_phone, c.lead_name, c.assigned_agent_id,
      c.eb_contact_id, c.eb_note_added, c.eb_marked_attended, c.eb_effect_lease_token
  )
  SELECT c.conversation_id, c.lead_phone, c.lead_name, c.assigned_agent_id,
    c.eb_contact_id, c.eb_note_added, c.eb_marked_attended, c.eb_effect_lease_token
  FROM claimed c;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

CREATE OR REPLACE FUNCTION public.finish_easybroker_attend_effect(
  p_conversation_id UUID,
  p_lease_token UUID,
  p_note_ok BOOLEAN,
  p_status_ok BOOLEAN,
  p_error_code TEXT DEFAULT NULL,
  p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS BOOLEAN AS $$
DECLARE
  v_conversation public.conversations;
BEGIN
  IF p_conversation_id IS NULL OR p_lease_token IS NULL OR p_note_ok IS NULL
     OR p_status_ok IS NULL OR p_now IS NULL OR length(COALESCE(p_error_code, '')) > 120 THEN
    RAISE EXCEPTION 'invalid EasyBroker effect completion input';
  END IF;

  SELECT * INTO v_conversation
  FROM public.conversations c
  WHERE c.conversation_id = p_conversation_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_conversation.eb_effect_lease_token IS DISTINCT FROM p_lease_token
     OR v_conversation.eb_effect_lease_expires_at <= p_now THEN
    RETURN FALSE;
  END IF;

  UPDATE public.conversations c
  SET eb_note_added = c.eb_note_added OR p_note_ok,
      eb_note_added_at = CASE
        WHEN NOT c.eb_note_added AND p_note_ok THEN p_now ELSE c.eb_note_added_at END,
      eb_marked_attended = c.eb_marked_attended OR p_status_ok,
      eb_attended_at = CASE
        WHEN NOT c.eb_marked_attended AND p_status_ok THEN p_now ELSE c.eb_attended_at END,
      eb_effect_lease_token = NULL,
      eb_effect_lease_expires_at = NULL,
      eb_effect_last_error = CASE
        WHEN (c.eb_note_added OR p_note_ok) AND (c.eb_marked_attended OR p_status_ok)
          THEN NULL
        ELSE NULLIF(btrim(p_error_code), '')
      END
  WHERE c.conversation_id = p_conversation_id
    AND c.eb_effect_lease_token = p_lease_token;
  RETURN FOUND;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER SET search_path=pg_catalog,public;

REVOKE ALL ON FUNCTION public.claim_easybroker_attend_effects(INTEGER,TIMESTAMPTZ),
  public.finish_easybroker_attend_effect(UUID,UUID,BOOLEAN,BOOLEAN,TEXT,TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_easybroker_attend_effects(INTEGER,TIMESTAMPTZ),
  public.finish_easybroker_attend_effect(UUID,UUID,BOOLEAN,BOOLEAN,TEXT,TIMESTAMPTZ)
  TO service_role;
