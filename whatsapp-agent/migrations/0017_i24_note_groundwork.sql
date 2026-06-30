-- 0017: Groundwork for case A (Inmuebles24 advisor-note bot).
-- Store the i24 lead id so a note-back bot can open the lead, plus an
-- idempotency flag. Applied to prod 2026-06-30.
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS i24_lead_id text;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS i24_note_added boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN conversations.i24_lead_id IS 'Inmuebles24 interesado id (panel/interesados/<id>); set by WF10 for source=inmuebles24. NULL for non-i24.';
COMMENT ON COLUMN conversations.i24_note_added IS 'TRUE once the i24 note-back bot wrote the assignment note in the lead Notas tab. Idempotency guard.';
