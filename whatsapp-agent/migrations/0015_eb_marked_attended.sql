-- 0015_eb_marked_attended.sql
-- EasyBroker Buzón pseudo-actions via browser automation (the EB public API
-- exposes neither contact_request status changes nor timeline notes — confirmed
-- against dev.easybroker.com/llms.txt: contact_requests is GET/POST only, no
-- notes endpoint). A Playwright bot (src/easybroker) logs into the EB Buzón and,
-- for each assigned EB-sourced lead, sets the request status to "Atendida" and
-- adds a timeline note naming the assigned agent.
--
-- This column is the idempotency flag so the bot never re-acts on the same lead.
-- Set TRUE only after BOTH UI actions (status + note) succeed for the request.
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS eb_marked_attended boolean NOT NULL DEFAULT false;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS eb_attended_at timestamptz;

COMMENT ON COLUMN conversations.eb_marked_attended IS
  'TRUE once the EB Buzón bot (src/easybroker) set the contact_request to Atendida AND added the assignment note. Idempotency guard. Always false for non-EB leads (eb_contact_id IS NULL).';
COMMENT ON COLUMN conversations.eb_attended_at IS
  'UTC timestamp when the EB Buzón bot marked the request Atendida + noted the agent.';

-- Partial index: the bot polls only assigned EB leads not yet attended.
-- (conversations has no claimed_at — assignment is recorded by assigned_agent_id;
-- the auction's claimed_at lives on the auctions table.)
CREATE INDEX IF NOT EXISTS idx_conversations_eb_pending_attend
  ON conversations (assigned_agent_id)
  WHERE eb_contact_id IS NOT NULL AND eb_marked_attended = false;
