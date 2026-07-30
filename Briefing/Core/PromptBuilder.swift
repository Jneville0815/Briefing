//
//  PromptBuilder.swift
//  Briefing
//

import Foundation

struct PromptBuilder: Sendable {
    struct Prompts: Sendable {
        let system: String
        let user: String
    }

    func build(
        events: [CalendarEvent],
        notes: [VaultNote],
        emails: [EmailMessage] = [],
        facts: Facts = Facts(),
        todayWeather: String? = nil,
        homeLocation: String = "",
        trips: [TripForecast] = [],
        previousDeliveries: [Briefing.Delivery] = [],
        deliveryCandidates: [EmailMessage] = []
    ) -> Prompts {
        let todayFormatter = DateFormatter()
        todayFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        let today = todayFormatter.string(from: Date())

        let system = """
        You are a personal daily briefing assistant. \
        You return a strictly-structured JSON briefing matching the provided schema. \
        Tone for any free-text fields: direct, warm, understated. No filler. \
        Today's date is \(today).
        """

        let weatherHeading = homeLocation.trimmingCharacters(in: .whitespaces).isEmpty
            ? "# Today's weather"
            : "# Today's weather (\(homeLocation))"

        let user = """
        \(weatherHeading)
        \(todayWeather ?? "_(weather unavailable)_")

        # Calendar (next 14 days)
        \(formatEvents(events))

        # Trips and forecasts
        \(formatTrips(trips))

        # Recurring tasks (status as of today)
        \(formatRecurringTasks(facts.recurringTasks, events: events))

        # Daily reminders (include verbatim in the reminders array)
        \(formatDailyReminders(facts.dailyReminders))

        # Recent daily notes (the user's own writing — surface forward-looking items, see task instructions)
        \(formatNotes(notes))

        # Previous deliveries (state from the last run — RECONCILE with new emails below)
        \(formatPreviousDeliveries(previousDeliveries))

        # Delivery-related emails (PRE-FILTERED — use these as the primary source for the deliveries section)
        \(formatDeliveryCandidates(deliveryCandidates))

        # Recent email signals (general context)
        \(formatEmails(emails))

        # Your task
        Return a JSON object matching the provided schema. Section guidance:

        - `today.summary`: 1-2 sentences. Set the tone for the day.
        - `today.weather`: leave as an empty string. The app fills this in directly from a separate weather service post-parse.
        - `today.items`: the most important things on today's calendar/agenda. 2-5 items max, in chronological order. If a recurring task is DUE/OVERDUE, mention it here. ALSO include any actionable items the user wrote down for themselves in "Recent daily notes" that are clearly meant for today (e.g. "tomorrow remind me to call X", "need to do Y"). CRITICAL: only include events from the `## Today` bucket above. NEVER pull from `## Tomorrow`, `## Later this week`, or `## Beyond this week` — those events are explicitly NOT today.
        - `reminders`: start with the daily reminders verbatim, one per element. THEN scan "Recent daily notes" for any forward-looking notes the user wrote to themselves — things like "remind me of X", "don't forget Y", pending tasks they jotted down to track, deferred decisions, anything that reads like "future me, do this." Add each as its own reminder element, paraphrased tightly into a short reminder (one short sentence each). CRITICAL — DEDUPLICATE: before adding a derived reminder from notes, scan the existing daily reminders list above. If a daily reminder already covers the same idea (even if the wording differs), DO NOT add a new variant — the existing one is already in the list verbatim, and rephrasing it just creates duplicate-looking entries. Only add a derived reminder if it represents a genuinely NEW commitment not already tracked. Do NOT include a dedicated "Recent daily notes" section in the briefing and do NOT echo the note verbatim — synthesize the actionable bits into reminders.
        - `thisWeek`: ALWAYS return EXACTLY 7 entries with `dayOffset` 0, 1, 2, 3, 4, 5, 6 — one per day starting today. Each entry's `items` is an array of short strings describing that day's calendar items (use the events from the matching bucket above — `## Today` for offset 0, `## Tomorrow` for offset 1, and the appropriate day from `## Later this week` for offsets 2–6). Use an empty `items` array for days with nothing on the calendar. Do NOT skip empty days. Do NOT add extra entries.
        - `upcomingTrips`: one entry per trip listed under "Trips and forecasts" above. Set `title` from the calendar event title, `destination` from the parsed location, `dates` to a friendly date range, and `weather` to a 1-2 sentence summary based on the forecast text (do not just copy verbatim — synthesize). If the forecast is unavailable, say so briefly in `weather`. CRITICAL: ONLY include trips listed under "Trips and forecasts" above. If that section says "_(no trips detected ...)_", return an empty array. Holidays (Memorial Day, Cinco de Mayo, etc.), regular meetings, and any other calendar event NOT in the trips list are NOT trips — never invent them.
        - `deliveries`: produce a reconciled list of orders and deliveries. Each entry has five fields: `id`, `state` (must be `"ordered"` or `"delivered"`), `item`, `dateOrdered`, and `dateDelivered`. \
          ID HANDLING: \
          - For items already listed in "Previous deliveries" above: use that item's exact `id` value. \
          - For NEW orders not in "Previous deliveries": set `id` to an empty string `""`. The app will assign one. \
          DATE HANDLING (use `yyyy-MM-dd` format, e.g. `"2026-04-27"`): \
          Each email in "Delivery-related emails" above has its received date in TWO formats — the human-readable `Received: ...` line AND a `[date=YYYY-MM-DD]` ISO tag at the end of that line. **Copy the `[date=...]` value verbatim** — do not infer, do not default to today. \
          - `dateOrdered`: \
            * For previous items: copy the `ordered` date shown in "Previous deliveries" above (the app preserves it anyway). \
            * For NEW items: ONLY set this if you actually find an order confirmation email for the item in the email feed. Take the `[date=...]` value from that order confirmation email, or use an explicit "Order placed on X" inside the body if clearly stated. \
            * If you only see shipping / in-transit / delivery emails for the item but NO order confirmation (which is common with a 24h email window), set `dateOrdered` to empty string `""`. The app stores it as "unknown" — DO NOT default to today's date. \
          - `dateDelivered`: \
            * For state `"ordered"`: set to empty string `""`. \
            * For state `"delivered"`: take the `[date=...]` value from the actual DELIVERY email (the email whose subject/body confirms delivery), not the order confirmation. If the delivery body explicitly says "Delivered on April 25" or similar, use that — but only if it's clearly stated. Otherwise just copy the delivery email's `[date=...]`. \
          EXAMPLES: \
          * Email "Subject: Your Ray-Ban order has been delivered ... Received: Mon Apr 27 [date=2026-04-27]" → `dateDelivered = "2026-04-27"`. \
          * Email "Subject: Order confirmed ... Received: Fri Apr 24 [date=2026-04-24]" → `dateOrdered = "2026-04-24"`. \
          NEVER use today's date as a default. If you genuinely cannot find a date, leave the field empty — the app will fall back. \
          DATA SOURCES (priority order): \
          - "Previous deliveries" above (state from last run, with stable ids) \
          - "Delivery-related emails" above (PRE-FILTERED — primary source for delivery signals) \
          - "Recent email signals" (general context only) \
          RECONCILIATION (follow exactly): \
          A. PRESERVE every item from "Previous deliveries" — return EVERY one of them in your output. The app trusts you not to silently drop ordered items. The ONLY way an item leaves the list is: \
             1. State changes to `"delivered"` (because you found a delivery email for it), OR \
             2. The app removes it after 2 days post-delivery (don't worry about this — the app handles it). \
          B. For each previous "ordered" item: scan delivery emails for a delivery confirmation that matches the item. If found → flip its state to `"delivered"` (keep the same `id`). If not found → leave it as `"ordered"` with the same `id`. \
          C. For each previous "delivered" item: keep it as `"delivered"` with the same `id`. The app drops it after 2 days. \
          D. Add NEW items from delivery emails not already in the previous list. Use `id: ""` for these. \
          PER-PACKAGE STATE ALGORITHM (when classifying email signals): \
          1. Group emails by tracking number when present, otherwise by sender + item. \
          2. Find all emails for that package and sort by received date. \
          3. Most recent email is "delivered" → state `"delivered"`. \
          4. Most recent email is anything else (order placed, shipped, in transit, out for delivery) → state `"ordered"`. \
          5. ABSOLUTE: a package whose latest email is a delivery confirmation is NEVER `"ordered"`. \
          EXCLUDE: returns / refunds / cancellations (never include in your output — even if previously listed); generic newsletters or promos not tied to a real order. \
          `item`: clear description of WHAT it is (e.g. "Ray-Ban sunglasses", "Fullscript digestive enzymes"). Skip generic "your order".

        Do not invent data. If a section has nothing relevant, return an empty array. Keep all strings tight.
        """

        return Prompts(system: system, user: user)
    }

    private func formatDeliveryCandidates(_ emails: [EmailMessage]) -> String {
        guard !emails.isEmpty else { return "_(none — no shipping/order signals found in recent email)_" }

        let humanDate = DateFormatter()
        humanDate.dateFormat = "EEE MMM d, h:mm a"
        let isoDate = DateFormatter()
        isoDate.dateFormat = "yyyy-MM-dd"

        return emails.prefix(80).map { email in
            let preview = email.bodyText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(700)
                .replacingOccurrences(of: "\n", with: " ")
            // Both the human-friendly format and the yyyy-MM-dd are included so Claude
            // can copy the ISO string directly into `dateOrdered` / `dateDelivered`.
            return """
            - From: \(email.from)
              Subject: \(email.subject)
              Received: \(humanDate.string(from: email.receivedAt))   [date=\(isoDate.string(from: email.receivedAt))]
              Preview: \(preview)
            """
        }.joined(separator: "\n\n")
    }

    private func formatPreviousDeliveries(_ items: [Briefing.Delivery]) -> String {
        guard !items.isEmpty else {
            return "_(none — this is either the first run or no deliveries were tracked previously)_"
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let ordered = items.filter { $0.state == "ordered" }
        let delivered = items.filter { $0.state == "delivered" }
        var lines: [String] = []
        if !ordered.isEmpty {
            lines.append("**Ordered (still tracking — keep these unless you find a delivery email):**")
            for item in ordered {
                let when = item.dateOrdered.map { dateFormatter.string(from: $0) } ?? "unknown"
                lines.append("- id=\(item.id) | \(item.item) | ordered \(when)")
            }
        }
        if !delivered.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("**Delivered (already confirmed — keep their state, the app drops them after 2 days):**")
            for item in delivered {
                let when = item.dateDelivered.map { dateFormatter.string(from: $0) } ?? "unknown"
                lines.append("- id=\(item.id) | \(item.item) | delivered \(when)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func formatTrips(_ trips: [TripForecast]) -> String {
        guard !trips.isEmpty else {
            return "_(no trips detected — events whose notes contain a `City, ST` pattern get flagged here)_"
        }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE MMM d"
        return trips.map { trip in
            let title = trip.event.title.isEmpty ? "(untitled)" : trip.event.title
            let dates = "\(dayFormatter.string(from: trip.event.startDate)) → \(dayFormatter.string(from: trip.event.endDate))"
            let forecastBlock: String
            if let err = trip.error {
                forecastBlock = "Forecast unavailable: \(err)"
            } else if trip.summary.isEmpty {
                forecastBlock = "Forecast unavailable."
            } else {
                forecastBlock = trip.summary
            }
            return """
            ## \(title) — \(trip.location)
            Dates: \(dates)
            Forecast: \(forecastBlock)
            """
        }.joined(separator: "\n\n")
    }

    private func formatDailyReminders(_ reminders: [DailyReminder]) -> String {
        guard !reminders.isEmpty else { return "_(none)_" }
        return reminders.map { "- \($0.text)" }.joined(separator: "\n")
    }

    private func formatRecurringTasks(
        _ tasks: [RecurringTask],
        events: [CalendarEvent]
    ) -> String {
        guard !tasks.isEmpty else { return "_(none configured)_" }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let scheduledFormatter = DateFormatter()
        scheduledFormatter.dateFormat = "EEE MMM d"

        return tasks.map { task in
            let cadence = "every \(task.cadenceDays) days"

            let statusText: String
            switch task.status(events: events) {
            case .noRecord:
                statusText = "NO RECORD — please log when last done"
            case .ok(let daysUntilDue):
                statusText = "OK (\(daysUntilDue) days until due)"
            case .due(let daysSince):
                statusText = "DUE (\(daysSince) days since)"
            case .overdue(let daysOverdue):
                statusText = "OVERDUE by \(daysOverdue) days"
            case .scheduled(let date, let daysUntil):
                let when: String
                switch daysUntil {
                case 0: when = "today"
                case 1: when = "tomorrow"
                default: when = "\(scheduledFormatter.string(from: date)) (in \(daysUntil) days)"
                }
                statusText = "SCHEDULED for \(when) — no action needed"
            }

            let lastStr: String
            if let effective = task.effectiveLastCompleted(events: events) {
                lastStr = "last on \(dayFormatter.string(from: effective))"
            } else {
                lastStr = "no record"
            }
            return "- \(task.label) (\(cadence)): \(lastStr) — \(statusText)"
        }.joined(separator: "\n")
    }

    private func formatEvents(_ events: [CalendarEvent]) -> String {
        guard !events.isEmpty else { return "_(no upcoming events)_" }

        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        // Group events by their day-offset from today (0 = today, 1 = tomorrow, …).
        var bucketed: [Int: [CalendarEvent]] = [:]
        for event in events {
            let eventDayStart = calendar.startOfDay(for: event.startDate)
            let delta = calendar.dateComponents([.day], from: todayStart, to: eventDayStart).day ?? 0
            bucketed[delta, default: []].append(event)
        }

        // Render one event line, including a relative-day tag so Claude can't misread the date.
        func line(for event: CalendarEvent, delta: Int) -> String {
            let title = event.title.isEmpty ? "(untitled)" : event.title
            let dayStr = dayFormatter.string(from: event.startDate)

            let tag: String
            switch delta {
            case ..<0: tag = "(\(-delta) days ago)"
            case 0:    tag = "(TODAY)"
            case 1:    tag = "(TOMORROW)"
            default:   tag = "(in \(delta) days)"
            }

            let when: String
            if event.isAllDay {
                when = "\(dayStr) \(tag), all day"
            } else {
                let start = timeFormatter.string(from: event.startDate)
                let end = timeFormatter.string(from: event.endDate)
                when = "\(dayStr) \(tag), \(start)–\(end)"
            }
            var out = "- \(when) | \(title) (\(event.calendarName))"
            if let location = event.location, !location.isEmpty {
                out += "\n  Location: \(location)"
            }
            return out
        }

        var sections: [String] = []

        let todayEvents = bucketed[0] ?? []
        sections.append("## Today (\(dayFormatter.string(from: now)))")
        if todayEvents.isEmpty {
            sections.append("_(nothing on the calendar today)_")
        } else {
            sections.append(todayEvents.map { line(for: $0, delta: 0) }.joined(separator: "\n"))
        }

        let tomorrowEvents = bucketed[1] ?? []
        let tomorrowDate = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        sections.append("\n## Tomorrow (\(dayFormatter.string(from: tomorrowDate)))")
        if tomorrowEvents.isEmpty {
            sections.append("_(nothing on the calendar tomorrow)_")
        } else {
            sections.append(tomorrowEvents.map { line(for: $0, delta: 1) }.joined(separator: "\n"))
        }

        let laterThisWeekDeltas = (2...6)
        let laterThisWeekEvents = laterThisWeekDeltas.flatMap { delta in
            (bucketed[delta] ?? []).map { (delta, $0) }
        }
        if !laterThisWeekEvents.isEmpty {
            sections.append("\n## Later this week (next 5 days)")
            sections.append(laterThisWeekEvents.map { line(for: $0.1, delta: $0.0) }.joined(separator: "\n"))
        }

        let beyondEvents = bucketed
            .filter { $0.key > 6 }
            .sorted { $0.key < $1.key }
            .flatMap { delta, evts in evts.map { (delta, $0) } }
        if !beyondEvents.isEmpty {
            sections.append("\n## Beyond this week")
            sections.append(beyondEvents.map { line(for: $0.1, delta: $0.0) }.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n")
    }

    private func formatNotes(_ notes: [VaultNote]) -> String {
        guard !notes.isEmpty else { return "_(no note from yesterday)_" }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        return notes.map { note in
            let trimmed = note.rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return "## \(dayFormatter.string(from: note.date))\n\(trimmed)"
        }.joined(separator: "\n\n")
    }

    private func formatEmails(_ emails: [EmailMessage]) -> String {
        guard !emails.isEmpty else { return "_(no recent email context)_" }

        let capped = Array(emails.prefix(120))
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE MMM d, h:mm a"

        return capped.map { email in
            let preview = email.bodyText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(400)
                .replacingOccurrences(of: "\n", with: " ")
            return """
            - From: \(email.from)
              Subject: \(email.subject)
              Received: \(dateFormatter.string(from: email.receivedAt))
              Preview: \(preview)
            """
        }.joined(separator: "\n\n")
    }
}
