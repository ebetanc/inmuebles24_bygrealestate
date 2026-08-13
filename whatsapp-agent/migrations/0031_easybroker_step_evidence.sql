-- Separate idempotency evidence for EasyBroker note and status side effects.
ALTER TABLE public.conversations
  ADD COLUMN IF NOT EXISTS eb_note_added boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS eb_note_added_at timestamptz;

UPDATE public.conversations
SET eb_note_added = true,
    eb_note_added_at = COALESCE(eb_note_added_at, eb_attended_at)
WHERE eb_marked_attended = true
  AND eb_note_added = false;

COMMENT ON COLUMN public.conversations.eb_note_added IS
  'TRUE once the EasyBroker assignment note was saved; independent from Atendida status.';
COMMENT ON COLUMN public.conversations.eb_note_added_at IS
  'Timestamp when EasyBroker note evidence was persisted.';

CREATE INDEX IF NOT EXISTS idx_conversations_eb_side_effects_pending
  ON public.conversations (conversation_id)
  WHERE eb_contact_id IS NOT NULL
    AND (eb_note_added = false OR eb_marked_attended = false);
