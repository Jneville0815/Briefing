# Briefing

A SwiftUI macOS app that assembles a daily briefing — today's agenda and weather, recurring-task status, upcoming trip forecasts, and package deliveries — from your Calendar, Gmail, and Obsidian vault, then hands it to Claude to synthesize into one structured briefing. It's a normal window app (not a menu-bar item): launch it, hit **Run**, and the window fills in.

Under the hood, the runner calls Anthropic's Messages API (model `claude-opus-4-7`, in `AnthropicClient.swift`) with a strict JSON schema, so the response decodes directly into the app's data model — Claude doesn't write free-form text that needs parsing.

## Setup

1. **Anthropic API key.** Either:
   - use the key field in the bottom bar of the window ("No API key" → paste your `sk-ant-…` key → Save), or
   - set it directly in Keychain: `security add-generic-password -a api-key -s com.briefing.anthropic -w 'sk-ant-…'`
2. **Calendar access.** The app prompts for it on first run — see [Permissions](#permissions).
3. **(Optional) Obsidian vault + home location.** Edit `config.json` (see [Configuration](#configuration)) to point at your vault and set a home location for weather. The briefing still runs fine without either.
4. **(Optional) Gmail.** Click **Connect** in the bottom bar — see [Gmail integration](#gmail-integration). Optional; the briefing runs without it, just with less context.
5. Hit **Run**.

## Using the app

The window is one scrollable view built from cards, populated after a run:

| Card | Contents |
| --- | --- |
| **Today** | 1-2 sentence summary, a weather chip (icon + condition, from Open-Meteo), and the day's 2-5 most important items |
| **Reminders** | Persistent list from `facts.json` — drag to reorder, add inline, remove with the ×. Claude also proposes new reminders mined from your daily notes (deduped — see [`dailyReminders[]`](#dailyreminders)) |
| **This Week** | 7-day outlook, one row per day |
| **Upcoming Trips** | One card per detected trip with a synthesized weather summary (hidden entirely when no trips are detected) |
| **Recurring** | A status badge per recurring task (NO REC / OVERDUE / DUE / SCHEDULED / OK), plus contextual action buttons — mark done, text a contact, or open a booking link |
| **Deliveries** | Ordered/delivered packages, auto-tracked across runs |
| **Debug — raw sources** | Collapsible section showing the raw weather, trips, calendar events, emails, and notes that fed the prompt |

The bottom bar (always visible) shows Gmail connection status and the Anthropic API key field.

## Configuration

Settings live in a JSON file at:

```
~/Library/Application Support/Briefing/config.json
```

It's created automatically the first time you hit **Run** (with sensible defaults). Edit the file manually — there's no settings UI for it yet.

### Fields

| Key | Meaning | Default |
| --- | --- | --- |
| `vaultPath` | Absolute path to your Obsidian vault root. `~` is expanded. | `~/Documents/Obsidian` |
| `dailyNotesSubpath` | Folder inside the vault containing daily notes. Use `""` if they live at the vault root. | `Daily` |
| `dailyNoteDateFormat` | `DateFormatter` pattern used to match filenames. | `yyyy-MM-dd` |
| `homeLocation` | Location string geocoded for today's home weather (e.g. `"Knoxville, TN"`). Leave `""` to skip home weather entirely. | `""` |

Example:

```json
{
  "dailyNoteDateFormat" : "yyyy-MM-dd",
  "dailyNotesSubpath" : "Daily Notes",
  "homeLocation" : "Knoxville, TN",
  "vaultPath" : "/Users/you/Obsidian/Personal"
}
```

The app looks for `<vaultPath>/<dailyNotesSubpath>/<date>.md` for each date in the lookback window (below) and reads the whole note. Missing files are skipped silently.

## How the lookback window works

Vault notes and Gmail both use the same dynamic window instead of a fixed number of days:

- The floor is **24 hours**.
- If the last successful run (tracked in `state.json`) was longer ago than that, the window expands to cover everything since that run — so skipping a few days doesn't lose anything.
- **Vault notes:** every daily note from the day the window starts through **yesterday** — today's own note is never read.
- **Gmail:** every message received since the window start, via Gmail's `after:YYYY/MM/DD` query (day resolution), capped at 250 messages per run.

On a successful run, its timestamp is written to `state.json` so the next run knows where to start.

## Facts

Recurring tasks, daily reminders, and email filters live in:

```
~/Library/Application Support/Briefing/facts.json
```

Created on first run with sensible defaults. Edit it manually to update `lastCompleted` dates, change cadences, add reminders, or tweak filters — or use the in-app controls where available (mark-done button, reminders list).

### `recurringTasks[]`

| Key | Meaning |
| --- | --- |
| `id` | Stable identifier (used to match across edits) |
| `label` | Human-readable name surfaced to Claude and the UI |
| `cadenceDays` | Days between occurrences — status flips to DUE at exactly this many days since last completion, OVERDUE past it. (Older files with `cadenceDaysMin`/`cadenceDaysMax` still load — `cadenceDaysMin` becomes `cadenceDays`.) |
| `lastCompleted` | `yyyy-MM-dd` (or `null` if never logged) |
| `matchCalendarTitles` | Substrings (case-insensitive) used to match calendar event titles. Optional, defaults to `[]`. |
| `matchEmailSenders` | Substrings (case-insensitive) used to match email `From:` headers. Optional. |
| `matchEmailSubjects` | Substrings (case-insensitive) used to match email `Subject:` headers. Optional — combined with senders via AND when both are present. |
| `requiresManualLog` | When `true`, the Recurring card shows a checkmark button to mark the task done today. When `false` (default), the task is expected to auto-update from calendar/email matches, and the card shows a small antenna icon instead. |
| `notifyContact` | Optional `{ name, phone, messageTemplate }`. When set, the Recurring card can show a message-bubble button that opens Messages.app (`sms:`) pre-filled with `messageTemplate`, for tasks that need attention. |
| `bookingURL` | Optional URL. When set, the Recurring card can show a button that opens it in the default browser (e.g. a booking or reorder page), for tasks that need attention. |

Status fed to Claude (computed, not stored):

| Condition | Surfaced as |
| --- | --- |
| Future calendar event matches `matchCalendarTitles` | `SCHEDULED for {date}` (overrides everything else) |
| Effective last-completed null | `NO RECORD — please log when last done` |
| days-since > cadenceDays | `OVERDUE by N days` |
| days-since == cadenceDays | `DUE (N days since)` |
| otherwise | `OK (N days until due)` |

"Effective last-completed" = the more recent of:

1. Manual `lastCompleted` from the JSON
2. Most-recent past calendar event whose title matches `matchCalendarTitles`

Email matches aren't recomputed at prompt time — every run scans the fetch window's emails (see [above](#how-the-lookback-window-works)) and writes any newly-detected completion straight into `lastCompleted` in `facts.json` (newer wins). So by the time status is computed, email-derived completions are already folded into source 1. So if your haircut is on the calendar and InstaCart sends a delivery email, you never have to touch `lastCompleted` by hand — the calendar and inbox keep it current automatically.

The prompt tells Claude to mention any DUE/OVERDUE task under `today.items`, and the SCHEDULED status text is explicitly labeled "no action needed" so Claude doesn't nag about scheduling something that's already on the calendar.

### `dailyReminders[]`

`{ "id": "...", "text": "..." }` — shown in the Reminders card (drag to reorder, click × to remove, type in the field to add). Claude includes each `text` verbatim in the briefing's `reminders` array every day — useful for coaching cues, mantras, or temporary focuses.

Claude also mines "Recent daily notes" for forward-looking things you jotted down to yourself ("remind me to X", "don't forget Y") and proposes them as additional reminders. The app merges these into `dailyReminders` automatically, skipping:

- exact-text duplicates of an existing reminder,
- near-duplicates (≥60% word-overlap / Jaccard similarity) of an existing reminder, and
- anything textually similar to a reminder you've previously removed — removing a reminder via the UI **tombstones** its normalized text in `removedReminders`, so it (or a rephrasing of it) won't silently come back. Adding it again manually clears the tombstone.

### `emailFilters`

- `excludeSenderContains[]` — substrings matched against the `From:` header (case-insensitive)
- `excludeSubjectContains[]` — substrings matched against the `Subject:` header (case-insensitive)

Filtered emails are dropped before being passed to Claude (and before appearing in the Debug section).

## Deliveries

The app tracks ordered/delivered packages across runs, persisted in `deliveries.json`.

Each run:

1. Pre-filters recent emails into "delivery candidates" — sender matches a list of carriers (UPS, FedEx, USPS, OnTrac, DHL) and merchants (Amazon, Ray-Ban, Instacart, Fullscript, Apple, Etsy, eBay, Best Buy, Target, Walmart, REI, Patagonia, Shopify, Stripe, and more), or the subject contains a shipping keyword ("shipped," "out for delivery," "tracking," "your order," etc.).
2. Sends those candidates, plus the previous run's delivery state, to Claude, which reconciles them into `{ id, state, item, dateOrdered, dateDelivered }` entries (`state` is `"ordered"` or `"delivered"`).
3. The app then enforces a few invariants Claude can't override:
   - stable `id`s persist across runs (Claude sets `id: ""` for genuinely new items; the app assigns a UUID);
   - `dateOrdered` never changes once known;
   - `dateDelivered` is stamped on the ordered→delivered transition;
   - if Claude drops a previously-tracked item by mistake, the app carries it forward;
   - delivered items are dropped from the list 2 days after delivery — ordered items never auto-expire.

Returns, refunds, and cancellations are excluded, as are generic newsletters/promos not tied to a real order.

## Trips & weather

Weather — both today's home forecast and trip forecasts — comes from **Open-Meteo** (`api.open-meteo.com`): free, no API key, worldwide coverage, up to a 16-day forecast window. Locations are geocoded with Apple's `CLGeocoder` (also no API key).

**Home weather** — set `homeLocation` in `config.json`. Every run fetches today's forecast for that location: condition, high/low, chance of rain, and — if the hourly data shows a contiguous stretch of ≥40% rain probability — a "rain likely 2pm–6pm"-style window. This becomes the weather chip on the Today card. The app splices this text into the briefing directly after Claude responds — Claude never writes `today.weather` itself.

**Trips** are detected automatically from your calendar. An event counts as a trip if:

- it isn't on a calendar whose name contains "holiday" (keeps Memorial Day, Cinco de Mayo, etc. out), **and**
- its **title contains "trip"** (case-insensitive), **and**
- its **location or notes field contains a `City, ST` pattern** — a word, a comma, then a 2-letter state code (e.g. `Boulder, CO`, `Hyatt Regency, San Francisco, CA`, `1234 Main St, Austin, TX`).

A meeting called "Team Offsite" with a Denver address won't match unless "trip" is in the title; "Boulder, Colorado" won't match either — it needs the 2-letter code.

For each detected trip, the app fetches an Open-Meteo forecast for the trip's date range and passes the raw daily forecasts to Claude under "Trips and forecasts," which synthesizes a 1-2 sentence summary per trip rather than dumping every period verbatim. Trips farther out than the 16-day window get a "forecast unavailable" placeholder until the date comes into range.

The Debug section in the window shows the raw home-weather summary and each detected trip with its forecast (or error) — useful for confirming a location geocoded and forecasted correctly.

## Output & state files

Everything besides the briefing itself lives under `~/Library/Application Support/Briefing/`:

| File | Contents |
| --- | --- |
| `config.json` | vault path, daily-notes settings, home location — see [Configuration](#configuration) |
| `facts.json` | recurring tasks, daily reminders, email filters, reminder tombstones — see [Facts](#facts) |
| `deliveries.json` | tracked ordered/delivered packages — see [Deliveries](#deliveries) |
| `state.json` | timestamp of the last successful run, used to size the lookback window — see [above](#how-the-lookback-window-works) |

Each run also writes a Markdown briefing to `<vaultPath>/Daily Briefing/<yyyy-MM-dd>.md` (the folder is created if missing). Re-running on the same day overwrites that day's file.

App logs go through `os.Logger` (subsystem `com.jimmy.briefing.Briefing`, category `Briefing`) — filter for those in Console.app if something needs debugging.

## Permissions

On first run the app prompts for **Calendar** access (TCC). If you dismiss it, re-enable under System Settings → Privacy & Security → Calendars, or reset with:

```
tccutil reset Calendar com.jimmy.briefing.Briefing
```

## Gmail integration

Gmail is optional — without it, the briefing runs without email context (which also disables recurring-task email auto-detection and the deliveries feature).

The Google Sign-In package and OAuth client ID are already wired into this project:

- `GoogleSignIn-iOS` (9.1.0) is a resolved Swift Package dependency on the `Briefing` target — nothing to add in Xcode.
- `Info.plist` already has a real `GIDClientID` and matching reversed-client-id URL scheme configured for bundle ID `com.jimmy.briefing.Briefing`.

**To connect:** click **Connect** in the bottom bar of the window — a browser opens for Google's consent flow. Once approved, the bar shows "Gmail connected" and the next run includes email signals.

**To disconnect:** click **Disconnect** in the bottom bar, or delete the `com.google.GIDSignIn` Keychain entries directly.

### If you ever need to recreate the Google Cloud credentials

1. Go to https://console.cloud.google.com and create a project (or reuse one).
2. Enable the **Gmail API**: APIs & Services → Library → search "Gmail API" → Enable.
3. Configure the **OAuth consent screen**: APIs & Services → OAuth consent screen. Pick *External*, name the app, add your own Gmail as a test user, add the scope `https://www.googleapis.com/auth/gmail.readonly`.
4. Create credentials: APIs & Services → Credentials → **Create Credentials → OAuth client ID** → **Application type: iOS** (works for macOS apps too). Set the bundle ID to `com.jimmy.briefing.Briefing`. Copy the resulting client ID.
5. Update both places in `Info.plist`:

   | Key | Replace with |
   | --- | --- |
   | `GIDClientID` | The full client ID, e.g. `1234567890-abc123xyz.apps.googleusercontent.com` |
   | `CFBundleURLTypes` → `CFBundleURLSchemes` | The **reversed** client ID (drop the `.apps.googleusercontent.com` suffix), e.g. `com.googleusercontent.apps.1234567890-abc123xyz` |

6. Rebuild.

## Sandboxing

The app is **unsandboxed in v1** so it can read your Obsidian vault from wherever you keep it. If you want to re-enable the sandbox later, you'll need to:

1. Add `com.apple.security.app-sandbox` back to `Briefing.entitlements`.
2. Flip `ENABLE_APP_SANDBOX = YES` in the target build settings.
3. Swap `VaultSource`'s plain `FileManager` reads for a security-scoped bookmark flow (user picks the vault once via `NSOpenPanel`, the bookmark is stored in config, resolved on each run).
