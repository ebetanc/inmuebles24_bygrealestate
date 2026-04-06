# Inmuebles24 Production Scraper + WhatsApp Bot

## Project Overview
Production-grade Inmuebles24 lead scraper for BYG Real Estate. Runs on Raspberry Pi 5 (16GB) behind Bright Data residential proxy (Mexico IPs), pushes leads to Postgres via n8n on Hostinger VPS, with a WhatsApp customer service bot powered by n8n AI Agent nodes.

## Tech Stack
- **Language:** Python 3.12+
- **Browser automation:** Playwright with system Chromium
- **Proxy:** Bright Data residential (Mexico)
- **Orchestration:** n8n (self-hosted on Hostinger VPS)
- **Database:** Postgres/Supabase
- **WhatsApp:** Meta Cloud API (Business Platform)
- **Bot AI:** n8n AI Agent nodes
- **Deployment:** Raspberry Pi 5, systemd timer

## Project Structure
```
src/inmobiliaria24/
  __main__.py          # Entry point
  main.py              # CLI & async orchestrator
  config.py            # Settings from env vars
  auth.py              # Playwright auth + session management
  scraper.py           # Lead extraction from Interesados inbox
tests/
  test_config.py       # Config validation tests
docs/superpowers/specs/
  2026-04-06-*.md      # Approved design spec
```

## Running
```bash
# Install
pip install -e .
playwright install chromium

# Run
python -m inmobiliaria24              # headless
python -m inmobiliaria24 --headful    # visible browser
python -m inmobiliaria24 --dry-run    # auth only, no scraping
```

## Environment Variables
```
INMUEBLES24_EMAIL=...
INMUEBLES24_PASSWORD=...
PROXY_HOST=...
PROXY_PORT=...
PROXY_USER=...
PROXY_PASS=...
```

## Key Design Decisions
- Uses real Chrome (not Playwright Chromium) to avoid bot detection
- Persistent Chrome profile at `.session/chrome-profile/` for session reuse
- Bright Data proxy with Mexico IPs — NEVER fall back to direct IP
- Deduplication via local JSON state file with atomic writes
- CRM integration is pluggable — currently a disabled placeholder in n8n
- WhatsApp bot has persistent conversation memory in Postgres (not volatile n8n memory)
- All bot responses in Spanish

## Architecture
- **Pi** runs scraper only (systemd timer, every 15min 7am-18pm CDMX)
- **VPS** runs n8n with 3 workflows: lead ingestion, heartbeat monitor, WhatsApp bot
- **DB** stores leads + conversation history
- See `docs/superpowers/specs/2026-04-06-production-scraper-whatsapp-bot-design.md` for full spec

## Testing
```bash
pytest tests/ -v
```

## Important
- Do not hardcode credentials — always use .env
- Do not expose Pi's real IP to Inmuebles24
- Conversation memory is critical — users must be able to continue WhatsApp chats after days/weeks
