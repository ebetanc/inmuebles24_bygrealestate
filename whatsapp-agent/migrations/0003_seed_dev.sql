-- ============================================================================
-- 0003_seed_dev.sql — development seed data
--
-- DO NOT run in production. Replace the numbers below with real agent
-- WhatsApp numbers before activating any workflow.
--
-- Numbers are stored in E.164 WITHOUT the 'whatsapp:' prefix. Workflows
-- add the prefix at send time.
-- ============================================================================

INSERT INTO agents (agent_id, name, whatsapp_number, on_shift, is_available)
VALUES
  ('agent_yolanda', 'Yolanda', '+5215500000001', true, true),
  ('agent_marusa',  'Marusa',  '+5215500000002', true, true),
  ('agent_gina',    'Gina',    '+5215500000003', true, true)
ON CONFLICT (agent_id) DO NOTHING;

-- Test conversation so you can manually trigger WF3a without needing WF2 yet.
INSERT INTO conversations (conversation_id, lead_phone, lead_name, current_property)
VALUES ('00000000-0000-0000-0000-000000000001',
        '+5215512345678',
        'María García (test)',
        'EB-12345')
ON CONFLICT (lead_phone) DO NOTHING;
