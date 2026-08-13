-- LRV2-012: two workers, expired-crash recovery, token-bound evidence.
BEGIN;

DO $$
DECLARE
  v_conversation_id UUID := gen_random_uuid();
  v_first RECORD;
  v_second RECORD;
  v_retry RECORD;
  v_count INTEGER;
  v_ok BOOLEAN;
  v_now TIMESTAMPTZ := '2026-08-13 12:00:00+00';
BEGIN
  INSERT INTO public.agents(agent_id, name, whatsapp_number)
  VALUES ('fixture-eb-worker', 'Fixture EB', '+5215550009912')
  ON CONFLICT(agent_id) DO NOTHING;

  -- Keep shared PG17 rows out of this bounded queue assertion; ROLLBACK restores them.
  UPDATE public.conversations
  SET eb_effect_lease_token = gen_random_uuid(),
      eb_effect_lease_expires_at = v_now + INTERVAL '1 day'
  WHERE eb_contact_id IS NOT NULL
    AND assigned_agent_id IS NOT NULL
    AND (eb_note_added = false OR eb_marked_attended = false);

  INSERT INTO public.conversations(
    conversation_id, lead_phone, lead_name, assigned_agent_id, source,
    claimed_via, eb_contact_id, eb_note_added, eb_marked_attended, created_at
  ) VALUES (
    v_conversation_id, '+5215550009913', 'Fixture EB lease', 'fixture-eb-worker',
    'easybroker', 'tomo_auction', 990013, false, false, '2000-01-01 00:00:00+00'
  );

  SELECT * INTO v_first FROM public.claim_easybroker_attend_effects(1, v_now);
  IF v_first.conversation_id IS DISTINCT FROM v_conversation_id OR v_first.lease_token IS NULL THEN
    RAISE EXCEPTION 'first worker did not claim fixture';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.claim_easybroker_attend_effects(1, v_now) c
  WHERE c.conversation_id = v_conversation_id;
  IF v_count <> 0 THEN RAISE EXCEPTION 'second worker claimed leased fixture'; END IF;

  -- Worker one crashes. After expiry another worker receives a different token.
  SELECT * INTO v_retry
  FROM public.claim_easybroker_attend_effects(1, v_now + INTERVAL '16 minutes');
  IF v_retry.conversation_id IS DISTINCT FROM v_conversation_id
     OR v_retry.lease_token IS NULL OR v_retry.lease_token = v_first.lease_token THEN
    RAISE EXCEPTION 'expired lease was not recovered with a fresh token';
  END IF;

  SELECT public.finish_easybroker_attend_effect(
    v_conversation_id, v_first.lease_token, true, true, NULL, v_now + INTERVAL '16 minutes'
  ) INTO v_ok;
  IF v_ok THEN RAISE EXCEPTION 'stale worker finished replacement lease'; END IF;

  -- Retry reconciles the deterministic marker as note_ok and leaves status pending.
  SELECT public.finish_easybroker_attend_effect(
    v_conversation_id, v_retry.lease_token, true, false, 'status_failed',
    v_now + INTERVAL '16 minutes'
  ) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'retry could not persist partial evidence'; END IF;

  SELECT * INTO v_second
  FROM public.claim_easybroker_attend_effects(1, v_now + INTERVAL '16 minutes');
  IF v_second.eb_note_added IS DISTINCT FROM true
     OR v_second.eb_marked_attended IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'retry did not receive separate step evidence';
  END IF;

  SELECT public.finish_easybroker_attend_effect(
    v_conversation_id, v_second.lease_token, true, true, NULL,
    v_now + INTERVAL '16 minutes'
  ) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'final retry failed'; END IF;

  SELECT count(*) INTO v_count
  FROM public.claim_easybroker_attend_effects(1, v_now + INTERVAL '16 minutes') c
  WHERE c.conversation_id = v_conversation_id;
  IF v_count <> 0 THEN RAISE EXCEPTION 'completed fixture was reclaimed'; END IF;
END;
$$;

ROLLBACK;
