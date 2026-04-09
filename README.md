# Inmobiliaria24

Production-grade lead capture and WhatsApp qualification bot for [Inmuebles24](https://www.inmuebles24.com/) real estate portal.

Scrapes new leads from the Inmuebles24 panel, deduplicates them, pushes to a CRM, and auto-qualifies via a WhatsApp Business bot before handing off to a human agent.

## Architecture

```
Inmuebles24.com
      |
      v
[Scraper] --> [State DB] --> [CRM Adapter] --> [Client CRM]
      |                            |
      |                            v
      |                   [WhatsApp Business API]
      |                       |           ^
      |                       v           |
      |                  [Greeting]   [Lead replies]
      v                                   |
[Telegram Alerts]                  [Qualification Bot]
 (errors only)                    (budget/timeline/zone)
                                          |
                                          v
                                 [Qualified Lead --> CRM + Agent WA]
```

## Features

- **Automated scraping** of Inmuebles24 Interesados inbox (all tabs: messages, phone, WhatsApp)
- **Lead deduplication** via SQLite-backed state store (WAL mode, concurrent-safe)
- **Pluggable CRM adapter** layer (webhook, HubSpot, or custom)
- **WhatsApp Business bot** with multi-step qualification flow (intent, budget, timeline, zone)
- **Natural language parsing** for Mexican Spanish (budget: "2 millones", timeline: "3 meses")
- **Agent handoff** with full lead brief via WhatsApp
- **Session recovery** with automatic re-authentication on stale sessions
- **Error resilience** with exponential backoff retries and screenshot capture on failures
- **Telegram monitoring** for error alerts, heartbeats, stale-run detection, and daily summaries
- **Structured JSON logging** for production log aggregation
- **FastAPI webhook server** for receiving WhatsApp messages with HMAC-SHA256 signature verification

## Requirements

- Python 3.12+
- Google Chrome (system install)
- A `.env` file with credentials (see below)

## Quick Start

```bash
# Clone the repository
git clone https://github.com/estebanmorenoit/inmuebles24_bygrealestate.git
cd inmuebles24_bygrealestate

# Create and activate a virtual environment
python -m venv .venv
source .venv/bin/activate  # Linux/macOS
# .venv\Scripts\activate   # Windows

# Install dependencies
pip install -e ".[dev]"

# Install Playwright browsers (only needed once)
playwright install chromium

# Set up environment variables
cp .env.example .env
# Edit .env with your credentials

# Run a dry-run to verify authentication
inmobiliaria24 --dry-run

# Run the full scraper
inmobiliaria24

# Run with visible browser (debugging)
inmobiliaria24 --headful
```

## Configuration

Copy `.env.example` to `.env` and fill in your values:

```bash
# Required — Inmuebles24 credentials
INMUEBLES24_EMAIL=your_email@example.com
INMUEBLES24_PASSWORD=your_password_here

# State database path (default: data/state.db)
# STATE_DB_PATH=data/state.db

# CRM adapter — webhook (default) or hubspot
# WEBHOOK_URL=https://your-n8n-instance.com/webhook/your-id
# CRM_API_KEY=              # HubSpot API key

# WhatsApp Business API
# WA_API_KEY=               # Meta / BSP access token
# WA_PHONE_NUMBER_ID=       # WhatsApp phone number ID
# WA_WEBHOOK_VERIFY_TOKEN=inmobiliaria24_verify
# WA_WEBHOOK_SECRET=        # Webhook signature secret

# Bot configuration
# BOT_AGENT_PHONE=+521234567890
# BOT_AGENT_NAME=Carlos
# BOT_TIMEOUT_HOURS=24

# Monitoring — Telegram (errors only)
# TELEGRAM_BOT_TOKEN=123456:ABC-DEF
# TELEGRAM_ALERT_CHAT_ID=1234567890
```

## Project Structure

```
src/inmobiliaria24/
  auth.py            # Chrome launch, login, Cloudflare handling
  config.py          # Settings from environment variables
  main.py            # CLI entrypoint with logging and error handling
  scraper.py         # SPA navigation, lead extraction, webhook
  state.py           # SQLite-backed lead dedup and run tracking
  monitor.py         # Telegram alerts, heartbeats, daily summary
  pipeline.py        # Lead processing: scrape -> dedup -> CRM push
  server.py          # FastAPI webhook server for WhatsApp
  crm/
    base.py          # CRMAdapter interface + Lead data model
    webhook.py       # Generic webhook CRM adapter
    hubspot.py       # HubSpot API v3 adapter (template)
  whatsapp/
    client.py        # WhatsApp Cloud API client
    templates.py     # Meta-approved message templates
    parser.py        # NL parser for Spanish (budget, timeline, intent)
    conversation_store.py  # SQLite conversation state persistence
    bot.py           # Qualification state machine

deploy/
  deploy.sh                    # Pull, install, restart services
  inmobiliaria24.service       # Systemd service (scraper)
  inmobiliaria24.timer         # Systemd timer (every 2h, business hours)
  inmobiliaria24-server.service # Systemd service (webhook server)
  nginx-webhook.conf           # Nginx reverse proxy config

tests/                         # 49 tests (pytest)
```

## Testing

```bash
# Run all tests
pytest

# Run with verbose output
pytest -v

# Run a specific test file
pytest tests/test_pipeline_integration.py -v
```

## Production Deployment

### Systemd (scraper on timer)

```bash
sudo cp deploy/inmobiliaria24.service /etc/systemd/system/
sudo cp deploy/inmobiliaria24.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now inmobiliaria24.timer
```

### Webhook Server (WhatsApp)

```bash
sudo cp deploy/inmobiliaria24-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now inmobiliaria24-server
```

### Nginx Reverse Proxy

```bash
sudo cp deploy/nginx-webhook.conf /etc/nginx/sites-available/inmobiliaria24
sudo ln -s /etc/nginx/sites-available/inmobiliaria24 /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

### Deploy Updates

```bash
bash deploy/deploy.sh
```

## WhatsApp Bot Flow

```
NEW_LEAD
  -> Send greeting + property context
  -> "Estas interesado en comprar o rentar?"

AWAITING_INTENT -> Capture: comprar/rentar
AWAITING_BUDGET -> Capture: budget ("2 millones", "$500k", range)
AWAITING_TIMELINE -> Capture: inmediato / 1-3 meses / 3-6 meses / explorando
AWAITING_ZONE -> Capture: zone preference

QUALIFIED
  -> Push qualification data to CRM
  -> Notify agent via WhatsApp with lead brief
  -> Agent takes over conversation

TIMEOUT (24h no response)
  -> Follow-up template
  -> 2nd timeout -> mark as cold in CRM
```

## License

Private / proprietary. All rights reserved.
