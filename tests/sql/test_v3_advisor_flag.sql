-- Execute after the full migration chain, in the SAME transaction, then ROLLBACK.
-- No HTTP calls, no WhatsApp sends, nothing committed.
DO $$
DECLARE
  r record; op_prev bigint; op bigint; op_corp bigint; op_prev2 bigint; op_e bigint; cap_e bigint; wh bigint; att bigint; res jsonb;
  -- gmail: a consumer domain, so only the explicit flag can exclude this person.
  em text := gen_random_uuid()::text || '@gmail.com';
  ph text := '+52155' || lpad((floor(random() * 100000000))::bigint::text, 8, '0');
  em2 text := gen_random_uuid()::text || '@empresa-prueba.com';
  ph2 text := '+52155' || lpad((floor(random() * 100000000))::bigint::text, 8, '0');
  carol_num text;
BEGIN
 -- (a) heurística
 IF public.v3_identity_looks_like_advisor('ana@gmail.com', 'Ana López', 'Me interesa') IS NOT NULL THEN
   RAISE EXCEPTION 'gmail client flagged'; END IF;
 IF public.v3_identity_looks_like_advisor('ventas@consorciosantore.com', 'Inmobiliaria', '') IS DISTINCT FROM 'name' THEN
   RAISE EXCEPTION 'name heuristic'; END IF;
 IF public.v3_identity_looks_like_advisor('i.ayala@citymax-pm.com', 'Ian', '') IS DISTINCT FROM 'email' THEN
   RAISE EXCEPTION 'corporate email heuristic'; END IF;
 IF public.v3_identity_looks_like_advisor('x@prodigy.net.mx', 'Sergio', 'hola') IS NOT NULL THEN
   RAISE EXCEPTION 'prodigy is consumer mail'; END IF;
 IF public.v3_identity_looks_like_advisor('x@hotmail.com', 'Luis', 'Soy asesor, tengo un cliente') IS DISTINCT FROM 'message' THEN
   RAISE EXCEPTION 'message heuristic'; END IF;
 IF public.v3_identity_looks_like_advisor(NULL, NULL, NULL) IS NOT NULL THEN
   RAISE EXCEPTION 'nulls are not advisors'; END IF;

 -- (b) cliente tomado por Carol hace 10 días → regresa a Carol
 INSERT INTO public.lead_routing_opportunities(state, v3_enabled, property_id, normalized_email, e164_phone, assigned_agent_id, assigned_at)
 VALUES ('assigned', true, 'EB-PREV01', em, ph, 'agent_carol', now() - interval '10 days') RETURNING opportunity_id INTO op_prev;
 INSERT INTO public.lead_routing_opportunities(state, v3_enabled, property_id, normalized_email, e164_phone, v3_offer_context)
 VALUES ('captured', true, 'EB-NEW001', em, ph, jsonb_build_object('portal', 'inmuebles24', 'name', 'Cliente Prueba'))
 RETURNING opportunity_id INTO op;
 SELECT * INTO r FROM public.v3_returning_client_agent(op);
 IF NOT FOUND OR r.agent_id <> 'agent_carol' THEN RAISE EXCEPTION 'client should return to Carol'; END IF;
 IF public.v3_advisor_reason(op) IS NOT NULL THEN RAISE EXCEPTION 'client has no advisor reason'; END IF;

 -- (c) marcado por la asesora → ya no regresa
 INSERT INTO public.lead_advisor_flags(opportunity_id, normalized_email, e164_phone, flagged_by_agent_id)
 VALUES (op_prev, em, ph, 'agent_carol');
 IF public.v3_advisor_reason(op) IS DISTINCT FROM 'agent_flag' THEN RAISE EXCEPTION 'flag not detected'; END IF;
 SELECT * INTO r FROM public.v3_returning_client_agent(op);
 IF FOUND THEN RAISE EXCEPTION 'flagged advisor still returns to Carol'; END IF;

 -- (d) heurística: correo de empresa, mismo historial con Carol → reparto normal
 INSERT INTO public.lead_routing_opportunities(state, v3_enabled, property_id, normalized_email, e164_phone, assigned_agent_id, assigned_at)
 VALUES ('assigned', true, 'EB-PREV02', em2, ph2, 'agent_carol', now() - interval '3 days') RETURNING opportunity_id INTO op_prev2;
 INSERT INTO public.lead_routing_opportunities(state, v3_enabled, property_id, normalized_email, e164_phone, v3_offer_context)
 VALUES ('captured', true, 'EB-NEW002', em2, ph2, jsonb_build_object('portal', 'inmuebles24', 'name', 'Pedro'))
 RETURNING opportunity_id INTO op_corp;
 IF public.v3_advisor_reason(op_corp) IS DISTINCT FROM 'heuristic_email' THEN RAISE EXCEPTION 'corporate mail not detected'; END IF;
 SELECT * INTO r FROM public.v3_returning_client_agent(op_corp);
 IF FOUND THEN RAISE EXCEPTION 'corporate mail still returns to Carol'; END IF;

 -- (e) "asesor" citando la oferta de un lead ofrecido a Carol → marca + evento.
 -- El intento se crea con la función real (como mk() en v3_shared_hour_check.py),
 -- no a mano, para respetar las columnas obligatorias del ledger.
 SELECT whatsapp_number INTO carol_num FROM public.agents WHERE agent_id = 'agent_carol';
 INSERT INTO public.lead_routing_opportunities(state, v3_enabled, property_id, normalized_email, e164_phone)
 VALUES ('resolved', true, 'EB-OFFER01', gen_random_uuid()::text || '@example.invalid', '+5215588' || lpad((floor(random() * 1000000))::int::text, 6, '0'))
 RETURNING opportunity_id INTO op_e;
 INSERT INTO public.i24_capture_events(account_key, source, happened_at, idempotency_key, disposition, contactado_status, opportunity_id, offer_context)
 VALUES ('default', 'inmuebles24', now(), 'test:asesor:cap:' || op_e::text, 'created_new', 'verified', op_e, '{}')
 RETURNING capture_event_id INTO cap_e;
 att := public.v3_request_offer(cap_e, 'owner', 'test:asesor:offer:' || op_e::text, 'agent_carol', carol_num);
 UPDATE public.lead_routing_delivery_attempts SET provider_message_id = 'wamid.offer.' || op_e::text, status = 'sent'
 WHERE attempt_id = att;
 INSERT INTO public.lead_routing_meta_webhook_inbox(idempotency_key, event_kind, wamid, sanitized_payload, payload_sha256, hmac_verified, created_at)
 VALUES ('test:asesor:1', 'message', 'wamid.in.asesor1',
   jsonb_build_object('kind', 'message', 'wamid', 'wamid.in.asesor1', 'context_id', 'wamid.offer.' || op_e::text,
     'event', jsonb_build_object('id', 'wamid.in.asesor1', 'from', regexp_replace(carol_num, '[ +()-]', '', 'g'), 'type', 'text',
       'text', jsonb_build_object('body', 'Asesor'), 'context', jsonb_build_object('id', 'wamid.offer.' || op_e::text))),
   md5('a') || md5('b'), true, now())
 RETURNING webhook_event_id INTO wh;
 res := public.v3_flag_advisor_from_webhook(wh);
 IF res->>'outcome' <> 'advisor_flagged' OR (res->>'opportunity_id')::bigint <> op_e THEN
   RAISE EXCEPTION 'quoted asesor did not flag: %', res; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.lead_advisor_flags WHERE opportunity_id = op_e AND flagged_by_agent_id = 'agent_carol') THEN
   RAISE EXCEPTION 'flag row missing'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.lead_routing_events WHERE opportunity_id = op_e AND event_type = 'advisor_flagged') THEN
   RAISE EXCEPTION 'advisor_flagged event missing'; END IF;
 -- repetir es idempotente
 res := public.v3_flag_advisor_from_webhook(wh);
 IF res->>'outcome' <> 'advisor_flagged' THEN RAISE EXCEPTION 'second asesor not idempotent: %', res; END IF;

 -- (f) sin cita: Carol tiene op_prev2 asignado hace 3 días → fuera de 24 h; se le
 -- acerca a 1 h para que compita con la oferta abierta op_e → dos candidatos → ambiguo
 UPDATE public.lead_routing_opportunities SET assigned_at = now() - interval '1 hour' WHERE opportunity_id = op_prev2;
 INSERT INTO public.lead_routing_meta_webhook_inbox(idempotency_key, event_kind, wamid, sanitized_payload, payload_sha256, hmac_verified, created_at)
 VALUES ('test:asesor:2', 'message', 'wamid.in.asesor2',
   jsonb_build_object('kind', 'message', 'wamid', 'wamid.in.asesor2', 'context_id', NULL,
     'event', jsonb_build_object('id', 'wamid.in.asesor2', 'from', regexp_replace(carol_num, '[ +()-]', '', 'g'), 'type', 'text',
       'text', jsonb_build_object('body', 'asesor'))),
   md5('c') || md5('d'), true, now())
 RETURNING webhook_event_id INTO wh;
 res := public.v3_flag_advisor_from_webhook(wh);
 IF res->>'outcome' <> 'advisor_ambiguous' THEN RAISE EXCEPTION 'two leads should be ambiguous: %', res; END IF;

 -- (g) un número que no es de asesora → rechazado
 INSERT INTO public.lead_routing_meta_webhook_inbox(idempotency_key, event_kind, wamid, sanitized_payload, payload_sha256, hmac_verified, created_at)
 VALUES ('test:asesor:3', 'message', 'wamid.in.asesor3',
   jsonb_build_object('kind', 'message', 'wamid', 'wamid.in.asesor3', 'context_id', NULL,
     'event', jsonb_build_object('id', 'wamid.in.asesor3', 'from', '5215599999999', 'type', 'text',
       'text', jsonb_build_object('body', 'asesor'))),
   md5('e') || md5('f'), true, now())
 RETURNING webhook_event_id INTO wh;
 res := public.v3_flag_advisor_from_webhook(wh);
 IF res->>'outcome' <> 'wrong_sender_number' THEN RAISE EXCEPTION 'stranger should be rejected: %', res; END IF;

 RAISE NOTICE 'V3_ADVISOR_FLAG_TESTS_PASS';
END $$;
