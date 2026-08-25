# Inmobiliaria24

24/7 lead management system for BYG Real Estate. Captures leads from 3 sources, runs daytime TOMO auctions to assign agents, and handles after-hours leads with an AI bot + morning queue.

## Estado operativo actual (2026-08-25)

Esta sección reemplaza la descripción histórica v5 para el flujo de leads de propiedades:

- **Captura activa:** Inmuebles24 consulta pendientes cada 15 minutos y envía los leads a WF10.
- **Consulta EasyBroker activa:** el scraper relaciona el ID numérico de Inmuebles24 con el código público `EB-...`; WF12 consulta la propiedad y usa literalmente `tags[0]` para identificar al responsable.
- **Entrega dirigida:** WF10 llama WF12 y, si `tags[0]` coincide con un alias exacto, WF13 notifica únicamente a esa persona. El cargo no veta la propiedad: Sandy recibe directamente cuando su alias coincide aunque tenga rol `manager`. Disponibilidad y WhatsApp válido siguen siendo obligatorios; si faltan datos, aplica guardia primaria, respaldo y alerta.
- **Captación directa EasyBroker pausada:** WF8/WF8b siguen inactivos. No deben activarse para resolver al propietario de un lead de Inmuebles24; son una fuente distinta y conservan lógica heredada.

Flujo vigente: `Inmuebles24 → ID del anuncio → código EB → EasyBroker → tags[0] → responsable → WhatsApp dirigido`.

## Architecture (v5)

```
                     +-----------------+
                     |   3 Lead Sources |
                     +-----------------+
                     /        |         \
            Inmuebles24   EasyBroker   WhatsApp Direct
          (scraper 2h)   (API 15min)   (bot number)
                     \        |         /
                      v       v        v
                  +---------------------+
                  |  n8n Workflow Engine |
                  | (11 workflows, VPS) |
                  +---------------------+
                           |
              +------------+------------+
              |                         |
         Day (8AM-9PM)           Night (9PM-8AM)
              |                         |
      TOMO Auction               AI Bot (OpenRouter)
    to 2 on-duty agents          + Night Queue
              |                         |
      Agent claims via WA        8AM Morning Report
      -> human handoff           -> auto-TOMO at 8:05
              |                         |
              +------------+------------+
                           |
                  +---------------------+
                  |    Supabase (DB)    |
                  |  9 tables + RLS     |
                  +---------------------+
                           |
                  +---------------------+
                  |  Next.js Dashboard  |
                  |  (Vercel)           |
                  +---------------------+
```

### Lead Sources

| Source | Trigger | Workflow |
|--------|---------|----------|
| **Inmuebles24** | Scraper every 2h (Raspberry Pi) | WF10 webhook -> WF2 |
| **EasyBroker** | API polling every 15 min | WF8 -> WF3a |
| **WhatsApp Direct** | Incoming message to bot number | WF1 -> WF2 |

### Day vs Night

- **Day (8 AM - 9 PM CDMX):** TOMO auction sent to 2 on-duty agents. First to reply `TOMO-XXXX` claims the lead. 5-min expiry escalates to manager.
- **Night (9 PM - 8 AM CDMX):** AI bot responds with property info (OpenRouter/Claude). Lead queued. 8:00 AM morning report to manager. 8:05 AM auto-TOMO for queued leads.

### Team

6 agents rotating in 2-per-shift schedule: Lupita, Paty, Yol, Gina, Carol, Moni. Manager always active.

## Components

| Component | Location | Tech |
|-----------|----------|------|
| Scraper | `src/inmobiliaria24/` | Python 3.12, Playwright, SQLite |
| n8n Workflows (11) | `whatsapp-agent/workflows/` | n8n self-hosted on Hostinger VPS |
| DB Schema (6 migrations) | `whatsapp-agent/migrations/` | Supabase (Postgres) |
| Dashboard | `dashboard/` | Next.js 16, Vercel |
| WhatsApp gateway | Evolution API | Hostinger VPS |
| Deploy configs | `deploy/` | systemd, nginx, certbot |

## n8n Workflows

| # | Workflow | Role | Trigger |
|---|----------|------|---------|
| WF1 | Inbound Router | Classifies WhatsApp messages, routes to appropriate handler | Webhook (Evolution) |
| WF2 | Lead Intake | Creates conversation, checks returning leads, routes day/night | Called by WF1/WF10 |
| WF3a | Auction Launcher | Creates TOMO auction, notifies on-duty agents | Called by WF2/WF8/WF10 |
| WF3b | Claim Handler | Processes agent TOMO claims (atomic), confirms winner | Called by WF1 |
| WF3c | Expiry Sweeper | Finds expired auctions, escalates to manager | Schedule (every 1 min) |
| WF4 | AI Conversation | Handles AI bot responses via OpenRouter | Called by WF1 |
| WF5 | Human Handoff | Transfers conversation from AI to human agent | Called by WF4 |
| WF6 | Guard Schedule | Syncs `agents.on_shift` from `agent_schedule` table | Schedule (shift changes) |
| WF7 | Morning Report | Sends overnight summary to manager, auto-TOMOs queued leads | Schedule (8:00 + 8:05 AM) |
| WF8 | EasyBroker Polling | Polls EasyBroker API for new unassigned contacts | Schedule (every 15 min) |
| WF10 | Scraper Intake | Receives leads from scraper webhook, routes day/night | Webhook |

## Dashboard

Next.js 16 app deployed on Vercel with password auth.

| Page | Description |
|------|-------------|
| `/` | Overview KPIs: leads today, active auctions, unassigned leads |
| `/leads` | All leads with status, source, assigned agent |
| `/agentes` | Agent list with shift status, availability |
| `/subastas` | Active and historical TOMO auctions |
| `/calendario` | Interactive guard schedule editor (saves to Supabase) |
| `/nocturno` | Night queue: AI bot conversations waiting for morning |
| `/login` | Password authentication |

## Scraper

Python/Playwright scraper for Inmuebles24's "Interesados" inbox.

- **Deduplication** via SQLite state store (WAL mode)
- **3 tabs**: Messages, Phone, WhatsApp
- **Retry logic** with exponential backoff
- **Session recovery** on stale detection
- **Screenshot capture** on failures
- **Telegram monitoring** for errors and heartbeats

### Run

```bash
pip install -e ".[dev]"
playwright install chromium

# Dry run (no webhook)
inmobiliaria24 --dry-run

# Full run
inmobiliaria24

# Debug with visible browser
inmobiliaria24 --headful
```

### Deploy (Raspberry Pi)

```bash
sudo cp deploy/inmobiliaria24.service /etc/systemd/system/
sudo cp deploy/inmobiliaria24.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now inmobiliaria24.timer
```

## Database Schema

9 tables in Supabase with RLS enabled:

| Table | Purpose |
|-------|---------|
| `agents` | 7 agents (6 + manager), shift status, contact info |
| `conversations` | Lead conversations with mode (ai/human/tomo), source, property |
| `messages` | Full message history linked to conversations |
| `auctions` | TOMO auction records with status and claimed_by |
| `night_queue` | Overnight leads waiting for morning processing |
| `agent_schedule` | Monthly guard calendar (2 agents per shift per day) |
| `listings` | Cached property listings from scraper |
| `properties_cache` | Property details for AI bot context |
| `scrape_logs` | Scraper run history and stats |

Key functions: `classify_sender()`, `is_daytime()`, `current_shift()`, `get_on_shift_agents()`, `find_returning_lead()`, `save_month_schedule()`, `generate_tomo_code()`.

## Testing

```bash
# 112 tests
pytest

# Verbose
pytest -v
```

## Go-Live

See [GO_LIVE_CHECKLIST.md](GO_LIVE_CHECKLIST.md) for the 11-stage deployment plan (~4 days once client provides data).

## Configuration

Copy `.env.example` to `.env` for the scraper. n8n environment variables are configured in n8n Settings. Dashboard uses `.env.local` (not tracked).

## License

Private / proprietary. All rights reserved.
