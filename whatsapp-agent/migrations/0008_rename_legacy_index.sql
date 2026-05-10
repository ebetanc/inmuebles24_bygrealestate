-- Migration 0008: Rename legacy Twilio index to match current column name
-- The index was created in 0001_init.sql as messages_twilio_sid_key
-- but the column was renamed to msg_external_id in 0004_evolution.sql

ALTER INDEX IF EXISTS messages_twilio_sid_key RENAME TO messages_msg_external_id_key;
