# Briefing

macOS menu bar app that assembles a daily briefing from your calendar, Gmail, and Obsidian vault using the Claude API.

## Configuration

Settings live in a JSON file at:

```
~/Library/Application Support/Briefing/config.json
```

It's created automatically the first time you hit **Run Now** (with sensible defaults). Edit the file manually for now — a settings UI will come later.

### Fields

| Key | Meaning | Default |
| --- | --- | --- |
| `vaultPath` | Absolute path to your Obsidian vault root. `~` is expanded. | `~/Documents/Obsidian` |
| `dailyNotesSubpath` | Folder inside the vault containing daily notes. Use `""` if they live at the vault root. | `Daily` |
| `dailyNoteDateFormat` | `DateFormatter` pattern used to match filenames. | `yyyy-MM-dd` |

Example:

```json
{
  "dailyNoteDateFormat" : "yyyy-MM-dd",
  "dailyNotesSubpath" : "Daily Notes",
  "vaultPath" : "/Users/you/Obsidian/Personal"
}
```

The app looks for `<vaultPath>/<dailyNotesSubpath>/<date>.md` for **yesterday's date only** and reads the whole note. If it's missing, that's fine — it just skips the section.

## Sandboxing

The app is **unsandboxed in v1** so it can read your Obsidian vault from wherever you keep it. If you want to re-enable the sandbox later, you'll need to:

1. Add `com.apple.security.app-sandbox` back to `Briefing.entitlements`.
2. Flip `ENABLE_APP_SANDBOX = YES` in the target build settings.
3. Swap `VaultSource`'s plain `FileManager` reads for a security-scoped bookmark flow (user picks the vault once via `NSOpenPanel`, the bookmark is stored in config, resolved on each run).

## Run windows

| Source | Window |
| --- | --- |
| Calendar | next 14 days |
| Vault daily notes | yesterday only |
| Email | last 30 days (Gmail's `after:YYYY/MM/DD` query) |

**How fact-store completion stays current:** every run scans the 30-day email window and writes detected completion dates back into `facts.json` as `lastCompleted` (newer wins). Status calculation reads from `facts.json` only.

## Facts

Recurring tasks, daily reminders, and email filters live in:

```
~/Library/Application Support/Briefing/facts.json
```

Created on first run with sensible defaults. Edit it manually to update `lastCompleted` dates, change cadences, add reminders, or tweak filters.

### `recurringTasks[]`

| Key | Meaning |
| --- | --- |
| `id` | Stable identifier (used to match across edits) |
| `label` | Human-readable name surfaced to Claude |
| `cadenceDaysMin` | Earliest day this task is "due" |
| `cadenceDaysMax` | Latest day before it's "overdue" |
| `lastCompleted` | `yyyy-MM-dd` (or `null` if never logged) |
| `matchCalendarTitles` | Substrings (case-insensitive) used to match calendar event titles. Optional, defaults to `[]`. |
| `matchEmailSenders` | Substrings (case-insensitive) used to match email `From:` headers. Optional. |
| `matchEmailSubjects` | Substrings (case-insensitive) used to match email `Subject:` headers. Optional — combined with senders via AND when both are present. |

For a single-cadence item, set `cadenceDaysMin == cadenceDaysMax`.

Status fed to Claude (computed, not stored):

| Condition | Surfaced as |
| --- | --- |
| Future calendar event matches `matchCalendarTitles` | `SCHEDULED for {date}` (overrides everything else) |
| Effective last-completed null | `NO RECORD — please log when last done` |
| days-since > max | `OVERDUE by N days` |
| days-since ≥ min | `DUE (N days since)` |
| otherwise | `OK (N days until due)` |

"Effective last-completed" = the most recent of three sources:

1. Manual `lastCompleted` from the JSON
2. Most-recent past calendar event whose title matches `matchCalendarTitles`
3. Most-recent received email matching `matchEmailSenders` AND `matchEmailSubjects` (within the last 30 days, since that's the email fetch window)

So if your haircut is on the calendar and InstaCart sends a delivery email, the JSON's `lastCompleted` becomes optional — calendar/email become the source of truth. The prompt notes the source in parentheses (`last on 2026-04-22 (from email)`) so you can see where the date came from.

The prompt instructs Claude to fold every DUE/OVERDUE task into "Things to prep for", and to leave SCHEDULED tasks alone (no nagging to schedule).

### `dailyReminders[]`

`{ "id": "...", "text": "..." }`. Claude is instructed to include each `text` verbatim in the briefing every day — useful for coaching cues, mantras, or temporary focuses.

### `emailFilters`

- `excludeSenderContains[]` — substrings matched against the `From:` header (case-insensitive)
- `excludeSubjectContains[]` — substrings matched against the `Subject:` header (case-insensitive)

Filtered emails are dropped before being passed to Claude (and before being shown in the debug section).

### Updating `lastCompleted`

For now, edit the file by hand. A "Mark done" UI is planned for a later phase.

## Trips & weather

The runner detects trips automatically from your calendar:

- Any event whose **location** ends with `, XX` (a 2-letter US state code) is treated as a trip.
- Examples: `Boulder, CO`, `Hyatt Regency, San Francisco, CA`, `1234 Main St, Austin, TX`. All match.
- `Conference Room A` doesn't match. Neither does `Boulder, Colorado` (use the 2-letter code).

For each detected trip, the app:

1. Geocodes the location via Apple's `CLGeocoder` (no API key needed).
2. Calls NOAA's `api.weather.gov` for the forecast (free, no key, US-only — `User-Agent` header required and set automatically).
3. Filters forecast periods to the trip's date range.
4. Passes them to Claude under `# Upcoming trips`. Claude is told to synthesize a 1-2 sentence weather summary, not dump every period verbatim.

NOAA's forecast horizon is ~7 days. Trips farther out get a "forecast unavailable" placeholder until the date enters the window.

The window is also visible in the debug section under "Trips" — useful for confirming the location was parsed and the forecast was fetched.

## Permissions

On first run the app prompts for **Calendar** access (TCC). If you dismiss it, re-enable under System Settings → Privacy & Security → Calendars, or reset with:

```
tccutil reset Calendar com.jimmy.briefing.Briefing
```

## Gmail integration

Gmail is optional — if you haven't connected it, the briefing runs without email context. To enable it:

### 1. Add the Swift package (Xcode UI, one time)

Xcode → **File → Add Package Dependencies…**

- Paste `https://github.com/google/GoogleSignIn-iOS` → Add Package → pick **GoogleSignIn** (`GoogleSignInSwift` is harmless if it gets selected too).

That's the only package needed — Gmail's REST API is called directly with `URLSession`, using the OAuth access token from `GoogleSignIn`. The `#if canImport(GoogleSignIn)` guard in `GmailSource.swift` flips once the package is added.

### 2. Google Cloud setup (one time)

1. Go to https://console.cloud.google.com and create a project (or reuse one).
2. Enable the **Gmail API**: APIs & Services → Library → search "Gmail API" → Enable.
3. Configure the **OAuth consent screen**: APIs & Services → OAuth consent screen. Pick *External*, name the app, add your own Gmail as a test user, add the scope `https://www.googleapis.com/auth/gmail.readonly`.
4. Create credentials: APIs & Services → Credentials → **Create Credentials → OAuth client ID** → **Application type: iOS** (works for macOS apps too). Set the bundle ID to `com.jimmy.briefing.Briefing`. Copy the resulting client ID — it looks like `1234567890-abc123xyz.apps.googleusercontent.com`.

### 3. Wire the client ID into the app

Open `Info.plist` (at the repo root) and replace both placeholders:

| Key | Replace `REPLACE_WITH_YOUR_CLIENT_ID` with |
| --- | --- |
| `GIDClientID` | The full client ID, e.g. `1234567890-abc123xyz.apps.googleusercontent.com` |
| `CFBundleURLTypes` → `CFBundleURLSchemes` | The **reversed** client ID (drop the `.apps.googleusercontent.com` suffix), e.g. `com.googleusercontent.apps.1234567890-abc123xyz` |

Rebuild. Click the menu bar → **Connect Gmail…** — a browser opens for consent. After approval the menu shows **Gmail: Connected** and the next run includes email signals.

**Reset Gmail auth:** use **Disconnect Gmail** in the menu, or delete the `com.google.GIDSignIn` keychain entries.

