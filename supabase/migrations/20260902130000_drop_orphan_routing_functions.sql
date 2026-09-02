-- DRAFT — apply only after 2026-09-03 and after a Supabase backup.
--
-- Drops routing functions with zero call sites. Every name below was checked
-- against whatsapp-agent/workflows/, n8n-export/, src/, dashboard/src/,
-- scripts/, whatsapp-agent/migrations/ and supabase/migrations/ — including
-- other functions' bodies, triggers, views, DEFAULTs and RLS policies.
--
-- Deliberately NOT dropped (each has a live reference):
--   claim_pending_v3_webhook_for_attempt(bigint,bigint)
--     called from v3_advance_routing_tier's body
--     (20260831170000_fix_v3_verified_webhook_claim_time.sql:316), which live
--     WF3c invokes.
--   is_daytime_at(timestamptz)
--     called from is_daytime()'s body (0023_routing_business_time.sql:19).
--   get_on_shift_agents()
--     called by the live, active WF19 Guard Notify workflow.
--   resolve_agent_from_tags(text[])
--     live WF12 no longer calls it, but whatsapp-agent/scripts/
--     02_verify_production.sql still asserts on it.
--   complete_unassigned_alert_delivery(bigint,uuid,text)
--     an intentional backward-compatible shim for older WF3c exports
--     (0045_finalize_easybroker_manager_assignment.sql:262). Drop only once no
--     stale WF3c export can be re-imported.
--
-- Before applying, note that whatsapp-agent/scripts/02_verify_production.sql
-- asserts the existence/privileges of mark_assigned, mark_offer_delivered,
-- mark_offer_delivery_failed and bind_delivery_message. That script needs
-- updating in the same change.
--
-- Rollback: re-run the migration that defined each function. The defining file
-- is named in the comment above each DROP.

BEGIN;

-- --------------------------------------------------------------------------
-- V3 orphans
-- --------------------------------------------------------------------------

-- 20260829134500_allow_account_api_retry_for_legacy_attempts.sql
DROP FUNCTION IF EXISTS public.authorize_v3_easybroker_account_api_retry(bigint, text, text, timestamptz);
DROP FUNCTION IF EXISTS public.reserve_v3_easybroker_account_api_retry(bigint, uuid, timestamptz);

-- 20260827154902_lead_routing_v3_easybroker_effects.sql
DROP FUNCTION IF EXISTS public.claim_v3_easybroker_effect_alerts(integer, timestamptz, interval);
DROP FUNCTION IF EXISTS public.finish_v3_easybroker_effect_alert(bigint, uuid, boolean, text, text, timestamptz);

-- 20260827154901_lead_routing_v3_claim_webhook.sql
DROP FUNCTION IF EXISTS public.replay_v3_meta_webhook_event(bigint, timestamptz);

-- --------------------------------------------------------------------------
-- V1 / V2 orphans
-- --------------------------------------------------------------------------

-- whatsapp-agent/migrations/0007_medium_fixes.sql
DROP FUNCTION IF EXISTS public.generate_tomo_code();

-- whatsapp-agent/migrations/0004_evolution.sql
DROP FUNCTION IF EXISTS public.evolution_phone(text);

-- whatsapp-agent/migrations/0010_crm_helpers.sql
DROP FUNCTION IF EXISTS public.mark_assigned(uuid, text, text);
DROP FUNCTION IF EXISTS public.mark_first_response(uuid);
DROP FUNCTION IF EXISTS public.record_sla_breach(uuid, text);
DROP FUNCTION IF EXISTS public.get_sla_breaches();

-- whatsapp-agent/migrations/0021_lead_routing_v2.sql
-- (already de-privileged by 0030_delivery_attempts.sql:266)
DROP FUNCTION IF EXISTS public.mark_offer_delivered(bigint, text, jsonb);
DROP FUNCTION IF EXISTS public.mark_offer_delivery_failed(bigint, text, jsonb);

-- whatsapp-agent/migrations/0027_advance_routing_tier.sql
DROP FUNCTION IF EXISTS public.sweep_expired_routing_tiers(integer, timestamptz);

-- whatsapp-agent/migrations/0028_routing_safe_mode.sql
DROP FUNCTION IF EXISTS public.exit_routing_safe_mode(text, boolean, text, timestamptz);

-- whatsapp-agent/migrations/0029_routing_v2_metrics.sql
DROP FUNCTION IF EXISTS public.acknowledge_unassigned_alert(bigint, text);

-- whatsapp-agent/migrations/0030_delivery_attempts.sql
-- bind_delivery_message had a 2-arg form that 0030:218 already dropped; an
-- un-migrated database may still carry it, so drop both identities.
DROP FUNCTION IF EXISTS public.bind_delivery_message(bigint, text, text);
DROP FUNCTION IF EXISTS public.bind_delivery_message(bigint, text);
DROP FUNCTION IF EXISTS public.sweep_owner_delivery_no_callback(interval, integer);
DROP FUNCTION IF EXISTS public.purge_delivery_callback_evidence(timestamptz);

-- whatsapp-agent/migrations/0040_recover_unbound_guard_delivery.sql
DROP FUNCTION IF EXISTS public.recover_unbound_guard_delivery(bigint, bigint, text);

-- whatsapp-agent/migrations/0042_retry_failed_guard_delivery.sql
DROP FUNCTION IF EXISTS public.requeue_failed_guard_delivery(bigint, text, text);

COMMIT;
