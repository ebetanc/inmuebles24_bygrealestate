-- 0034: claim_lead_opportunity necesita pgcrypto (digest) visible en su search_path.
--
-- Contexto (E2E LRV2 2026-08-13): en Supabase la extension pgcrypto vive en el schema
-- `extensions`, no en `public`. 0026 fijo `SET search_path=pg_catalog,public` dentro de
-- public.claim_lead_opportunity, por lo que su digest() interno (autenticacion del actor,
-- hash SHA-256 del telefono) falla en produccion con
-- "function digest(text, unknown) does not exist".
-- El gate PG17 previo no lo detecto porque instalaba pgcrypto en `public` (falso verde);
-- el fixture test_claim_pgcrypto.sql reproduce ahora el layout Supabase.
--
-- Forward-only: NO se edita 0026. Este ALTER es reaplicable (idempotente): fija la misma
-- configuracion las veces que se ejecute. En entornos sin schema `extensions` (gate local
-- pre-Supabase) el search_path simplemente ignora el schema inexistente.
--
-- Rollback (forward-fix, nunca editar/re-ejecutar migraciones aplicadas): nueva migracion
-- 0035+ con:
--   ALTER FUNCTION public.claim_lead_opportunity(bigint, text, text, text, text)
--     SET search_path = pg_catalog, public;

DO $$
DECLARE
  v_count INT;
  v_args TEXT;
BEGIN
  SELECT count(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'claim_lead_opportunity';
  IF v_count <> 1 THEN
    RAISE EXCEPTION '0034: expected exactly one public.claim_lead_opportunity, found %', v_count;
  END IF;

  SELECT pg_get_function_identity_arguments(p.oid) INTO v_args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'claim_lead_opportunity';
  IF v_args IS DISTINCT FROM 'p_opportunity_id bigint, p_tier text, p_agent_id text, p_actor_phone_hash text, p_idempotency_key text' THEN
    RAISE EXCEPTION '0034: unexpected claim_lead_opportunity signature: %', v_args;
  END IF;
END $$;

ALTER FUNCTION public.claim_lead_opportunity(bigint, text, text, text, text)
  SET search_path = pg_catalog, public, extensions;
