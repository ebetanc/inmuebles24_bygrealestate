# Makefile for whatsapp-agent subfolder.
# Run from THIS directory (whatsapp-agent/), not the repo root.

.PHONY: help setup migrate migrate-no-seed rollback check psql env-check _check-cwd

# Fail fast if run from the wrong directory.
_check-cwd:
	@if [ ! -f ./migrations/0001_init.sql ]; then \
		echo "❌ Run 'make' from inside the whatsapp-agent/ subfolder."; \
		echo "   cd whatsapp-agent && make <target>"; \
		exit 1; \
	fi

help:
	@echo "whatsapp-agent — common commands (run from whatsapp-agent/ subfolder)"
	@echo ""
	@echo "  make setup             Run migrations + seed dev data"
	@echo "  make migrate           Same as setup"
	@echo "  make migrate-no-seed   Run migrations without dev seed data"
	@echo "  make rollback          Drop all tables (DANGER, asks for confirmation)"
	@echo "  make check             Show current DB state (agents, auctions, messages)"
	@echo "  make psql              Open a psql shell to the database"
	@echo "  make env-check         Verify your .env is set up correctly"

setup: migrate

migrate: _check-cwd
	@./scripts/migrate.sh

migrate-no-seed: _check-cwd
	@./scripts/migrate.sh --no-seed

rollback: _check-cwd
	@./scripts/migrate.sh --rollback

check: _check-cwd
	@./scripts/check.sh

psql: _check-cwd
	@set -a; [ -f .env ] && . ./.env; set +a; psql "$$DATABASE_URL"

env-check: _check-cwd
	@if [ ! -f .env ]; then \
		echo "❌ .env not found. Run: cp .env.example .env"; \
		exit 1; \
	fi
	@set -a; . ./.env; set +a; \
	for var in DATABASE_URL TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN TWILIO_WHATSAPP_FROM EASYBROKER_API_KEY; do \
		if [ -z "$$(eval echo \$$$$var)" ]; then \
			echo "❌ $$var is empty"; \
		else \
			echo "✅ $$var is set"; \
		fi; \
	done
