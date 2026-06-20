-- 0013_agent_roles.sql
-- Owner/manager/asesor role on agents. Owner = Marusa (la Dueña); manager = Sandy.
-- Role is informational + drives the dashboard badge; routing tiers still live in n8n.
ALTER TABLE agents
  ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'asesor'
  CHECK (role IN ('owner','manager','asesor'));

UPDATE agents SET role = 'owner'   WHERE agent_id = 'agent_manager_2'; -- Marusa
UPDATE agents SET role = 'manager' WHERE agent_id = 'agent_manager';   -- Sandy

-- At most one owner: partial unique index on role='owner'.
CREATE UNIQUE INDEX IF NOT EXISTS agents_single_owner ON agents ((role)) WHERE role = 'owner';
