# EasyBroker Buzón bot

Drives the EasyBroker Buzón UI to perform the two actions the EB public API does
**not** expose (confirmed against `dev.easybroker.com/llms.txt` — `contact_requests`
is GET/POST only, no status mutation, no notes endpoint):

1. Set a contact_request status to **Atendida** (`Cambiar estatus`).
2. Add a **timeline note** naming the assigned agent (`Agregar nota`).

For each lead with a final responsible agent, the bot opens the exact Buzón
request, writes one `RESPONSABLE: <agente>` note, and sets it to Atendida.

## How it picks work

Polls Supabase `conversations` for rows where:

```
eb_contact_id IS NOT NULL          -- exact EasyBroker request is known
AND assigned_agent_id IS NOT NULL  -- final responsible agent is known
AND (eb_note_added = false OR eb_marked_attended = false)
```

Before polling, assigned Inmuebles24 leads are correlated with the read-only
EasyBroker `contact_requests` API. A link is written only when property ID,
email or normalized phone, and event time produce exactly one request. Zero or
multiple matches are left untouched for Sandy to review; the bot never guesses.

`attend_lead` navigates by exact `eb_contact_id` (URL `/agent/conversations/{id}`);
phone lookup only runs when `allow_phone_fallback=True` is passed explicitly (never
enabled in production or `--once`).

An atomic expiring lease prevents two workers from opening the same request.
Each retry executes only the missing step and persists note/status evidence with
the lease token before releasing it.

## Run

```bash
# one lead, by exact EasyBroker request ID (forces the gate on; ignores Supabase)
python -m easybroker --once 12345678 --agent "Sandy"

# poll + attend every pending EB lead (gated)
EB_MARK_ATTENDED=1 python -m easybroker

# diagnostics (read-only)
python -m easybroker --dry-run                     # verify login
python -m easybroker --inspect-login               # dump login form
python -m easybroker --inspect-buzon 5519205636    # dump Buzón controls
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

`EASYBROKER_EMAIL`, `EASYBROKER_PASSWORD` (UI login), `EASYBROKER_API_KEY`
(account API GET reconciliation), `EASYBROKER_PARTNER_API_KEY` (Partners API
creation; no fallback to the account key), `EASYBROKER_PARTNER_COUNTRY_CODE=MX`
(two-letter country code),
`SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `EB_MARK_ATTENDED=1`,
`EASYBROKER_V3_INBOX=1`, and `EASYBROKER_CREATE_REQUESTS=1` (POST creation only when `EASYBROKER_CREATE_REQUESTS=1`; explicitly
enables the durable one-shot Partners API POST for captures 107/108 and newer
eligible `created_new` captures; disabled by default). Each POST carries the
numeric I24 lead ID as stable `remote_id`; a fallback message is always sent.
optional `CHROME_PATH` (e.g. Edge on Windows), `CHROME_PROXY`.
