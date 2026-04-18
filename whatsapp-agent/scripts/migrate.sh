#!/usr/bin/env bash
# =============================================================================
# scripts/migrate.sh — run all migrations in order against $DATABASE_URL
#
# Usage:
#   ./scripts/migrate.sh              # runs 0001, 0002, 0003 (seed) in order
#   ./scripts/migrate.sh --no-seed    # skips 0003_seed_dev.sql
#   ./scripts/migrate.sh --rollback   # runs 9999_rollback.sql (DANGER)
# =============================================================================

set -euo pipefail

# Load .env if present
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if [ -z "${DATABASE_URL:-}" ]; then
  echo "❌ DATABASE_URL is not set. Copy .env.example to .env and fill it in."
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "❌ psql not found. Install PostgreSQL client tools first."
  echo "   macOS:  brew install libpq && brew link --force libpq"
  echo "   Ubuntu: sudo apt install postgresql-client"
  exit 1
fi

MODE="${1:-normal}"

if [ "$MODE" = "--rollback" ]; then
  echo "⚠️  About to DROP ALL TABLES in $DATABASE_URL"
  read -r -p "Type 'yes' to confirm: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/9999_rollback.sql
  echo "✅ Rollback complete."
  exit 0
fi

echo "→ Running 0001_init.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/0001_init.sql

echo "→ Running 0002_rls.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/0002_rls.sql

if [ "$MODE" != "--no-seed" ]; then
  echo "→ Running 0003_seed_dev.sql"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/0003_seed_dev.sql
fi

echo "✅ Migrations complete."
