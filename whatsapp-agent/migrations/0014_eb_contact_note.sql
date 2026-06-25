-- 0014_eb_contact_note.sql
-- Owner-assignment note-back to EasyBroker: store the EB contact_id on
-- conversations sourced from EasyBroker (WF8b) so WF3b can append an
-- "Asignado a <agent>" note to the EB contact's private_description on claim.
-- NULL for non-EasyBroker leads (Inmuebles24 / WhatsApp direct).
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS eb_contact_id bigint;
COMMENT ON COLUMN conversations.eb_contact_id IS
  'EasyBroker contact_id for leads sourced from EasyBroker (WF8b); used to write an assignment note back to the EB contact on claim. NULL for non-EB leads.';
