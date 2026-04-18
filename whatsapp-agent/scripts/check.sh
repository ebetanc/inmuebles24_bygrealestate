#!/usr/bin/env bash
# =============================================================================
# scripts/check.sh — sanity check that the DB is in a healthy state
# =============================================================================

set -euo pipefail

if [ -f .env ]; then set -a; source .env; set +a; fi

if [ -z "${DATABASE_URL:-}" ]; then
  echo "❌ DATABASE_URL not set."
  exit 1
fi

psql "$DATABASE_URL" <<'SQL'
\echo '── agents (on_shift) ──'
SELECT agent_id, name, whatsapp_number, on_shift, is_available FROM agents;

\echo ''
\echo '── conversations ──'
SELECT conversation_id, lead_phone, lead_name, mode, assigned_agent_id FROM conversations ORDER BY created_at DESC LIMIT 5;

\echo ''
\echo '── recent auctions ──'
SELECT short_code, status, winner_agent_id, notified_agents, created_at, expires_at FROM auctions ORDER BY created_at DESC LIMIT 10;

\echo ''
\echo '── recent messages ──'
SELECT created_at, direction, sender_type, left(body, 80) AS body_preview FROM messages ORDER BY created_at DESC LIMIT 10;
SQL
