# EasyBroker Buzón bot

Drives the EasyBroker Buzón UI to perform the two actions the EB public API does
**not** expose (confirmed against `dev.easybroker.com/llms.txt` — `contact_requests`
is GET/POST only, no status mutation, no notes endpoint):

1. Set a contact_request status to **Atendida** (`Cambiar estatus`).
2. Add a **timeline note** naming the assigned agent (`Agregar nota`).

For each EB-sourced lead that has been assigned to an agent, the bot opens the
conversation in the Buzón, sets it to Atendida, and writes `Atendido por <agente>`.

## How it picks work

Polls Supabase `conversations` for rows where:

```
eb_contact_id IS NOT NULL          -- came from EasyBroker (WF8b)
AND assigned_agent_id IS NOT NULL  -- an agent claimed it
AND eb_marked_attended = false     -- not done yet (idempotency guard)
```

After both UI actions succeed it sets `eb_marked_attended = true` +
`eb_attended_at = now()` so the lead is never touched again
(migration `whatsapp-agent/migrations/0015_eb_marked_attended.sql`).

## Run

```bash
# one lead, by phone (forces the gate on; ignores Supabase)
python -m easybroker --once 5519205636 --agent "Sandy" --headful

# poll + attend every pending EB lead (gated)
EB_MARK_ATTENDED=1 python -m easybroker

# diagnostics (read-only)
python -m easybroker --dry-run --headful           # verify login
python -m easybroker --inspect-login --headful      # dump login form
python -m easybroker --inspect-buzon 5519205636 --headful  # dump Buzón controls
```

Without `EB_MARK_ATTENDED=1` the default poll mode only lists pending leads.

## ⚠️ Headless is blocked — use xvfb on the Pi

EB's WAF returns **403 Forbidden to headless browsers**; only a headful Chrome
gets through (200). The Pi has no display, so run "headful" under a virtual
framebuffer:

```bash
sudo apt-get install -y xvfb
# cron (every 10 min), headful under xvfb:
*/10 * * * * cd /path/to/repo && EB_MARK_ATTENDED=1 xvfb-run -a python -m easybroker >> logs/eb_cron.log 2>&1
```

It uses its own Chrome profile (`.session/eb-chrome-profile`) and CDP port
(`9223`), so it coexists with the Inmuebles24 scraper (profile `chrome-profile`,
port `9222`). The persistent profile keeps the EB session logged in between runs.

## Env

`EASYBROKER_EMAIL`, `EASYBROKER_PASSWORD` (UI login, NOT the API key),
`SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `EB_MARK_ATTENDED=1`,
optional `CHROME_PATH` (e.g. Edge on Windows), `CHROME_PROXY`.
