# 🏠 Inmuebles24 CDMX — Real Estate Scraper & Notification System

An automated n8n workflow that scrapes [Inmuebles24](https://www.inmuebles24.com/inmuebles-en-ciudad-de-mexico.html) for new property listings in Mexico City, stores them in Supabase, deduplicates against existing records, and sends real-time notifications via Telegram (or Slack/Discord/Email) when new properties appear.

---

## System Architecture

```
┌─────────────┐     ┌──────────────┐     ┌──────────────────┐     ┌─────────────┐
│  ⏰ Cron     │────▶│ 🔥 Firecrawl │────▶│ 🤖 Parse & Hash  │────▶│ 💾 Supabase │
│  3x / day   │     │  Scrape 3pg  │     │  Extract listings │     │  Get existing│
└─────────────┘     └──────────────┘     └──────────────────┘     └──────┬──────┘
                                                                         │
                    ┌──────────────┐     ┌──────────────────┐     ┌──────▼──────┐
                    │ 📢 Telegram  │◀────│ 📝 Format Message│◀────│ 🔍 Compare  │
                    │ Notification │     │  + Log to DB     │     │ New vs Known │
                    └──────────────┘     └──────────────────┘     └─────────────┘
```

---

## Files Included

| File | Purpose |
|------|---------|
| `inmuebles24_scraper_workflow.json` | **The n8n workflow** — import directly into n8n |
| `supabase_setup.sql` | **Database schema** — run in Supabase SQL Editor |
| `architecture.mermaid` | **Visual diagram** — system architecture flowchart |
| `README.md` | This documentation |

---

## Prerequisites

Before setting up, you'll need accounts and API keys for:

1. **n8n** — Self-hosted or n8n Cloud ([n8n.io](https://n8n.io))
2. **Firecrawl** — Web scraping API ([firecrawl.dev](https://firecrawl.dev)) — Free tier: 500 credits/month
3. **Supabase** — PostgreSQL database ([supabase.com](https://supabase.com)) — Free tier available
4. **Telegram Bot** (recommended) — For notifications ([BotFather](https://t.me/botfather))

---

## Setup Guide

### Step 1: Create the Supabase Database

1. Go to [supabase.com](https://supabase.com) and create a new project
2. Open the **SQL Editor** (left sidebar)
3. Paste the entire contents of `supabase_setup.sql` and click **Run**
4. This creates three tables:
   - `listings` — Stores all scraped property listings
   - `scrape_logs` — Tracks every scrape execution
   - `notification_log` — Records sent notifications
5. Go to **Settings → API** and copy:
   - **Project URL** (e.g., `https://xxxxx.supabase.co`)
   - **service_role key** (under Project API keys — use this one, NOT the anon key)

> ⚠️ **Important**: Use the `service_role` key, not the `anon` key. The service_role key bypasses Row Level Security, which is required for the workflow to read/write data.

### Step 2: Get Your Firecrawl API Key

1. Go to [firecrawl.dev](https://firecrawl.dev) and create an account
2. Navigate to your dashboard and copy your API key (starts with `fc-`)
3. The free tier gives you 500 credits/month (each scrape = 1 credit)
4. With 3 pages × 3 times/day = 9 credits/day ≈ 270 credits/month (fits free tier)

### Step 3: Set Up Telegram Bot (Recommended)

1. Open Telegram and message [@BotFather](https://t.me/botfather)
2. Send `/newbot` and follow prompts to create your bot
3. Copy the **bot token** (looks like `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)
4. Start a chat with your new bot (or add it to a group)
5. To get your **chat_id**:
   - Send any message to your bot
   - Visit `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates`
   - Find `"chat":{"id": YOUR_CHAT_ID}` in the response

### Step 4: Configure n8n Credentials

In your n8n instance, create these credentials:

#### Firecrawl (HTTP Header Auth)
1. Go to **Credentials → Add Credential → HTTP Header Auth**
2. Set:
   - **Name**: `Firecrawl API Key`
   - **Header Name**: `Authorization`
   - **Header Value**: `Bearer fc-YOUR_API_KEY_HERE`

#### Supabase
1. Go to **Credentials → Add Credential → Supabase**
2. Set:
   - **Name**: `Supabase Inmuebles24`
   - **Host**: `https://xxxxx.supabase.co` (your project URL)
   - **Service Role Key**: your service_role key from Step 1

### Step 5: Set n8n Environment Variables

For Telegram notifications, set these environment variables in n8n:

- `TELEGRAM_BOT_TOKEN` = your bot token from Step 3
- `TELEGRAM_CHAT_ID` = your chat ID from Step 3

**Alternative**: You can hardcode these values directly in the Telegram HTTP Request node instead of using environment variables.

### Step 6: Import the Workflow

1. Open your n8n instance
2. Click the **three dots menu** (upper right) → **Import from File**
3. Select `inmuebles24_scraper_workflow.json`
4. The workflow will appear on your canvas
5. **Update credential references**: Click on each Supabase and Firecrawl node and select your newly created credentials
6. **Test manually** by clicking **Execute Workflow**
7. Once verified, toggle the workflow **Active** to enable the cron schedule

---

## Workflow Node-by-Node Breakdown

### 1. Schedule: 3x Daily
- **Type**: Schedule Trigger
- **Config**: Cron expression `0 8,14,20 * * *` (8AM, 2PM, 8PM)
- **Note**: Times are in your server's timezone. Adjust for Mexico City (UTC-6)

### 2. Setup: Generate Run Config
- **Type**: Code
- **Purpose**: Creates a unique run ID and generates items for each page URL to scrape
- **Output**: 3 items (one per page), each containing the URL and metadata

### 3. Firecrawl: Scrape Page
- **Type**: HTTP Request → Firecrawl API
- **Endpoint**: `POST https://api.firecrawl.dev/v1/scrape`
- **Config**: Markdown format, 5s wait for JS rendering, 30s timeout
- **Retry**: 3 attempts with 5s delay on failure
- **Output**: Raw markdown content of each page

### 4. Parse: Extract Listings from Markdown
- **Type**: Code (JavaScript)
- **Purpose**: The core parsing engine — extracts structured data from Firecrawl's markdown output
- **Extracts**: Title, price, location, URL, property type, bedrooms, bathrooms, area, images
- **Hashing**: Generates a unique hash per listing for deduplication
- **Output**: Array of structured listing objects

### 5. Supabase: Get Existing Listings
- **Type**: Supabase node (Get All)
- **Purpose**: Fetches all `listing_hash` values from active listings
- **Used for**: O(1) comparison against new scrape results

### 6. Compare: Find New Listings
- **Type**: Code
- **Purpose**: Compares scraped hashes against existing database hashes
- **Output**: Only listings NOT already in the database

### 7. IF: New Listings Found?
- **Type**: IF node
- **Condition**: `newCount > 0`
- **YES branch** → Insert + Notify
- **NO branch** → Log and end

### 8–9. Insert into Supabase
- **Purpose**: Splits new listings into individual items and inserts each as a row

### 10. Format Notification Message
- **Type**: Code
- **Purpose**: Creates formatted messages for Telegram (HTML) and Email (plain text)
- **Content**: Property details, prices, locations, direct links

### 11. Telegram: Send Notification
- **Type**: HTTP Request → Telegram Bot API
- **Format**: HTML with property details, emojis, and clickable links

### 12. Log Run (both branches)
- **Purpose**: Records scrape statistics to `scrape_logs` table

---

## Customization Options

### Scrape More Pages
In the **"Setup: Generate Run Config"** Code node, modify the `pages` array:

```javascript
const pages = [
  'https://www.inmuebles24.com/inmuebles-en-ciudad-de-mexico.html',
  'https://www.inmuebles24.com/inmuebles-en-ciudad-de-mexico-pagina-2.html',
  'https://www.inmuebles24.com/inmuebles-en-ciudad-de-mexico-pagina-3.html',
  // Add more pages:
  'https://www.inmuebles24.com/inmuebles-en-ciudad-de-mexico-pagina-4.html',
  'https://www.inmuebles24.com/inmuebles-en-ciudad-de-mexico-pagina-5.html',
];
```

### Filter by Property Type or Price
In the **"Compare: Find New Listings"** Code node, add filters:

```javascript
const newListings = listings.filter(l => {
  if (existingHashes.has(l.listing_hash)) return false;
  // Filter by price range (MXN)
  if (l.price_numeric && l.price_numeric < 2000000) return false;
  if (l.price_numeric && l.price_numeric > 10000000) return false;
  // Filter by property type
  if (l.property_type && l.property_type.toLowerCase() === 'terreno') return false;
  return true;
});
```

### Change Scrape Frequency
Modify the cron expression in the Schedule Trigger:
- Every 4 hours: `0 */4 * * *`
- Twice daily: `0 9,18 * * *`
- Every hour during business hours: `0 9-18 * * 1-5`

### Add WhatsApp Notifications
Replace the Telegram node with a Twilio HTTP Request:

```json
{
  "url": "https://api.twilio.com/2010-04-01/Accounts/YOUR_SID/Messages.json",
  "method": "POST",
  "body": {
    "From": "whatsapp:+14155238886",
    "To": "whatsapp:+52XXXXXXXXXX",
    "Body": "{{$json.emailBody}}"
  }
}
```

### Add Slack Notifications
Enable the disabled **"Webhook: Slack/Discord"** node and set your Slack Incoming Webhook URL.

### Target Different Cities or Searches
Change the URLs in the Setup node to target other searches:

```javascript
const pages = [
  // Guadalajara
  'https://www.inmuebles24.com/inmuebles-en-guadalajara.html',
  // Only apartments for rent in CDMX
  'https://www.inmuebles24.com/departamentos-en-renta-en-ciudad-de-mexico.html',
  // Houses for sale in Polanco
  'https://www.inmuebles24.com/casas-en-venta-en-polanco.html',
];
```

---

## Troubleshooting

### Firecrawl returns empty markdown
- The site may be blocking scrapers. Try increasing `waitFor` to 10000ms
- Check if your Firecrawl account has remaining credits
- Try adding `"actions": [{"type": "scroll", "direction": "down"}]` to trigger lazy-loaded content

### Supabase credential errors
- Make sure you're using the `service_role` key, not the `anon` key
- Check that RLS policies were created (run the SQL setup script)
- Verify the project URL format: `https://xxxxx.supabase.co`

### No listings being parsed
- Run the workflow manually and inspect the output of the Parse node
- The markdown structure may have changed — check Firecrawl output and adjust regex patterns
- Consider adding Firecrawl's `jsonOptions` with a prompt for AI-powered extraction as a fallback

### Telegram not sending
- Verify bot token and chat_id are correct
- Make sure you've started a conversation with the bot first
- Check that environment variables are set: Settings → Environment Variables

### Duplicate notifications
- This shouldn't happen due to hash-based deduplication
- If it does, check if the listing hash generation is producing different hashes for the same listing (URL changes, title formatting changes)

---

## Cost Estimation (Monthly)

| Service | Usage | Cost |
|---------|-------|------|
| **Firecrawl** | 3 pages × 3/day × 30 days = 270 credits | Free tier (500/month) |
| **Supabase** | ~1000 rows, minimal queries | Free tier |
| **n8n Cloud** | ~90 executions/month | Free tier or ~$20/mo |
| **Telegram** | Bot API | Free |
| **Total** | | **$0–20/month** |

---

## Advanced: Using Firecrawl Extract (AI-Powered)

For more reliable parsing, you can replace the markdown approach with Firecrawl's JSON extract feature. Modify the HTTP Request body:

```json
{
  "url": "https://www.inmuebles24.com/inmuebles-en-ciudad-de-mexico.html",
  "formats": ["json"],
  "jsonOptions": {
    "prompt": "Extract all real estate listings from this page. For each listing, extract: title, price, currency, location/neighborhood, property type, operation type (sale/rent), number of bedrooms, number of bathrooms, area in m2, the listing URL, and image URL.",
    "schema": {
      "type": "object",
      "properties": {
        "listings": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "title": {"type": "string"},
              "price": {"type": "string"},
              "currency": {"type": "string"},
              "location": {"type": "string"},
              "property_type": {"type": "string"},
              "operation_type": {"type": "string"},
              "bedrooms": {"type": "integer"},
              "bathrooms": {"type": "integer"},
              "area_m2": {"type": "number"},
              "url": {"type": "string"},
              "image_url": {"type": "string"}
            }
          }
        }
      }
    }
  }
}
```

This uses Firecrawl's built-in AI to extract structured data, making the Parse node much simpler. Note: JSON format may consume additional credits.

---

## License

This project is provided as-is for personal use. Inmuebles24 is a third-party website — please review their terms of service regarding automated access. Scrape responsibly and respect rate limits.
