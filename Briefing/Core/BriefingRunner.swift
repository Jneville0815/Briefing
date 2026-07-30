//
//  BriefingRunner.swift
//  Briefing
//

import Foundation

actor BriefingRunner {
    private let calendarSource: CalendarSource
    private let gmailSource: GmailSource
    private let weatherSource = WeatherSource()
    private let configStore: ConfigurationStore
    private let factStore = FactStore()
    private let deliveriesStore = DeliveriesStore()
    private let runStateStore = RunStateStore()
    private let keychain = KeychainHelper()

    private(set) var lastEvents: [CalendarEvent] = []
    private(set) var lastNotes: [VaultNote] = []
    private(set) var lastEmails: [EmailMessage] = []
    private(set) var lastTrips: [TripForecast] = []
    private(set) var lastTodayWeather: TodayWeather?
    private(set) var lastOutputURL: URL?
    private(set) var lastBriefing: Briefing?

    /// Minimum window for both email and vault-note fetching. If the last successful run
    /// was longer ago than this, the window expands to cover everything since that run.
    private let minimumLookback: TimeInterval = 24 * 60 * 60   // 24 hours

    init(
        calendarSource: CalendarSource,
        gmailSource: GmailSource,
        configStore: ConfigurationStore
    ) {
        self.calendarSource = calendarSource
        self.gmailSource = gmailSource
        self.configStore = configStore
    }

    typealias ProgressHandler = @Sendable (String) async -> Void

    func run(progress: ProgressHandler = { _ in }) async throws -> Briefing {
        await progress("Checking access…")
        guard let apiKey = keychain.loadAPIKey(), !apiKey.isEmpty else {
            throw BriefingError.missingAPIKey
        }

        Logger.shared.info("Briefing run started")

        let now = Date()
        let calendar = Calendar.current

        await progress("Requesting calendar access…")
        let granted = try await calendarSource.requestAccess()
        guard granted else { throw BriefingError.calendarAccessDenied }

        await progress("Fetching calendar events…")
        let events = try await calendarSource.fetchUpcomingEvents()
        lastEvents = events
        Logger.shared.info("Fetched \(events.count) events")

        await progress("Loading config and facts…")
        let config = configStore.load()
        var facts = factStore.load()
        Logger.shared.info("Loaded \(facts.recurringTasks.count) recurring tasks, \(facts.dailyReminders.count) reminders")

        // Compute the lookback window: at least 24 hours, or longer if the last successful
        // run was more than 24 hours ago. The user may run multiple times per day for testing
        // — the floor keeps the window meaningful.
        let runState = runStateStore.load()
        let twentyFourHoursAgo = now.addingTimeInterval(-minimumLookback)
        let windowStart: Date
        if let last = runState.lastRunAt {
            windowStart = min(twentyFourHoursAgo, last)
        } else {
            windowStart = twentyFourHoursAgo
        }
        let windowHours = Int((now.timeIntervalSince(windowStart) / 3600).rounded())
        Logger.shared.info("Fetch window: last \(windowHours)h (since \(windowStart))")

        // Vault notes: every daily note from the day containing windowStart through yesterday.
        await progress("Reading recent daily notes from vault…")
        let notesStartDay = calendar.startOfDay(for: windowStart)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let notesEnd = max(notesStartDay, yesterday)
        let notes = try await VaultSource(configuration: config).fetchDailyNotes(since: notesStartDay, until: notesEnd)
        lastNotes = notes
        Logger.shared.info("Fetched \(notes.count) vault note(s) from \(notesStartDay) → \(notesEnd)")

        // Gmail: same dynamic window.
        var contextEmails: [EmailMessage] = []
        if gmailSource.isAuthenticated() {
            await progress("Fetching email (last \(windowHours)h)…")
            let fetchSince = windowStart
            do {
                let raw = try await gmailSource.fetchRecentMessages(since: fetchSince)
                let filtered = raw.filter { email in
                    !facts.emailFilters.excludeSenderContains.contains { needle in
                        email.from.localizedCaseInsensitiveContains(needle)
                    } &&
                    !facts.emailFilters.excludeSubjectContains.contains { needle in
                        email.subject.localizedCaseInsensitiveContains(needle)
                    }
                }

                // Fact detection: scan EVERYTHING (including Promotions/Social) so we catch
                // InstaCart and similar transactional emails that Gmail auto-categorizes.
                var mutated = false
                for index in facts.recurringTasks.indices where facts.recurringTasks[index].hasEmailMatchers {
                    if let detected = facts.recurringTasks[index].lastEmailMatch(in: filtered, before: now) {
                        let existing = facts.recurringTasks[index].lastCompleted ?? .distantPast
                        if detected > existing {
                            facts.recurringTasks[index].lastCompleted = detected
                            mutated = true
                            Logger.shared.info("Auto-updated \(facts.recurringTasks[index].id).lastCompleted = \(detected) from email")
                        }
                    }
                }
                if mutated {
                    await progress("Updating recurring task records…")
                    factStore.save(facts)
                }

                // Send all (filtered) emails to Claude — including Promotions/Social, which
                // is where many delivery confirmations land. Claude is instructed to ignore
                // newsletter/marketing noise itself.
                contextEmails = filtered
                let droppedByUser = raw.count - filtered.count
                Logger.shared.info("Fetched \(raw.count) emails over \(windowHours)h (\(droppedByUser) filtered by user rules, all categories included)")
            } catch {
                Logger.shared.error("Gmail fetch failed (continuing without email): \(error.localizedDescription)")
            }
        } else {
            Logger.shared.info("Gmail not connected — skipping")
        }
        lastEmails = contextEmails

        // Today's home weather (NOAA, free).
        await progress("Fetching today's weather…")
        var todayWeather: TodayWeather?
        if !config.homeLocation.trimmingCharacters(in: .whitespaces).isEmpty {
            do {
                todayWeather = try await weatherSource.fetchTodayForecast(for: config.homeLocation)
                Logger.shared.info("Home weather fetched (\(todayWeather?.summary.count ?? 0) chars)")
            } catch {
                Logger.shared.error("Home weather fetch failed: \(error.localizedDescription)")
            }
        }
        lastTodayWeather = todayWeather

        // Trips — detected from calendar event notes.
        await progress("Detecting trips and fetching trip weather…")
        let trips = await fetchTrips(from: events)
        lastTrips = trips
        Logger.shared.info("Detected \(trips.count) trip(s)")

        await progress("Loading previous deliveries…")
        let previousDeliveries = deliveriesStore.load().items
        Logger.shared.info("Previous deliveries: \(previousDeliveries.count) item(s)")

        // Pre-filter delivery-related emails so Claude doesn't have to hunt for them
        // amid 150 unrelated messages. Match by carrier sender, merchant sender, or
        // shipping-keyword in the subject.
        let deliveryCandidates = Self.filterDeliveryCandidates(in: contextEmails)
        Logger.shared.info("Delivery candidates: \(deliveryCandidates.count) of \(contextEmails.count) emails matched shipping patterns")

        await progress("Building prompt…")
        let prompts = PromptBuilder().build(
            events: events,
            notes: notes,
            emails: contextEmails,
            facts: facts,
            todayWeather: todayWeather?.summary,
            homeLocation: config.homeLocation,
            trips: trips,
            previousDeliveries: previousDeliveries,
            deliveryCandidates: deliveryCandidates
        )

        await progress("Generating briefing with Claude…")
        let client = AnthropicClient(apiKey: apiKey)
        var briefing = try await client.generateBriefing(
            systemPrompt: prompts.system,
            userMessage: prompts.user
        )
        // App-managed: stuff today's weather text in directly so it can't get lost by the model.
        if let weather = todayWeather, !weather.summary.isEmpty {
            briefing.today.weather = weather.summary
        }
        Logger.shared.info("Received briefing (today=\(briefing.today.summary.prefix(60)))")

        // App-managed: stamp deliveredAt on transitions and drop anything delivered
        // more than 2 days ago. This makes the cutoff independent of Claude's reasoning.
        briefing.deliveries = reconcileDeliveryDates(
            new: briefing.deliveries,
            previous: previousDeliveries,
            now: now
        )

        // Persist the reconciled deliveries so next run has the prior state to work from.
        deliveriesStore.save(DeliveriesState(items: briefing.deliveries))
        Logger.shared.info("Saved \(briefing.deliveries.count) delivery item(s) to state")

        // Merge any newly-surfaced reminders Claude generated (e.g. from daily notes) into
        // the persistent list. Skip ones already there and ones the user has tombstoned.
        let factsBefore = facts.dailyReminders.count
        facts = mergeBriefingReminders(briefing.reminders, into: facts)
        if facts.dailyReminders.count != factsBefore {
            factStore.save(facts)
            Logger.shared.info("Persisted \(facts.dailyReminders.count - factsBefore) new reminder(s) into facts.json")
        }

        await progress("Saving briefing file…")
        let markdown = MarkdownExporter().render(
            briefing,
            recurringTasks: facts.recurringTasks,
            events: events,
            generatedAt: now
        )
        let outputURL = try writeBriefing(markdown: markdown)
        lastOutputURL = outputURL
        lastBriefing = briefing

        // Mark this run as successful so the next run can expand its window if more
        // than 24h passes before then.
        runStateStore.save(RunState(lastRunAt: now))

        return briefing
    }

    /// Merges the briefing's reminders array into the persistent dailyReminders list.
    /// Adds anything new — skipping items that are exact-text matches OR semantically
    /// similar (Jaccard >= 0.6 on word tokens) to an existing reminder or a tombstone.
    /// Tombstones win — once the user X's a reminder, neither the same text nor a
    /// rephrasing of it will come back.
    private func mergeBriefingReminders(_ texts: [String], into facts: Facts) -> Facts {
        var updated = facts
        let exactExisting = Set(facts.dailyReminders.map { DailyReminder.normalize($0.text) })
        let exactTombstones = Set(facts.removedReminders)
        let similarityThreshold = 0.6

        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = DailyReminder.normalize(trimmed)
            if exactExisting.contains(normalized) || exactTombstones.contains(normalized) { continue }

            // Fuzzy: skip if too similar to an existing reminder we'd already track.
            // updated.dailyReminders includes both the prior list and any items we've
            // appended in this same merge pass, so back-to-back near-duplicates dedupe too.
            if updated.dailyReminders.contains(where: {
                DailyReminder.similarity($0.text, trimmed) >= similarityThreshold
            }) {
                Logger.shared.info("Skipping near-duplicate reminder: \(trimmed)")
                continue
            }
            if facts.removedReminders.contains(where: {
                DailyReminder.similarity($0, trimmed) >= similarityThreshold
            }) {
                Logger.shared.info("Skipping tombstoned-similar reminder: \(trimmed)")
                continue
            }

            updated.dailyReminders.append(DailyReminder(id: UUID().uuidString, text: trimmed))
            Logger.shared.info("New reminder picked up from briefing: \(trimmed)")
        }
        return updated
    }

    /// Subset of emails likely related to shipping or deliveries — used to build a focused
    /// section for Claude so it doesn't have to find delivery signals in the broader feed.
    private static func filterDeliveryCandidates(in emails: [EmailMessage]) -> [EmailMessage] {
        let senderNeedles = [
            // Carriers
            "ups.com", "fedex.com", "usps.com", "ontrac", "dhl.com",
            "shipment-tracking@", "ship-confirm@", "auto-confirm@",
            // Big merchants
            "amazon.com", "rayban", "ray-ban", "instacart.com", "fullscript.com",
            "apple.com", "etsy.com", "ebay.com", "bestbuy.com", "best-buy",
            "target.com", "walmart.com", "rei.com", "patagonia.com",
            "shopify.com", "shopify-shipping", "stripe.com",
        ]
        let subjectNeedles = [
            "delivered", "out for delivery", "shipped", "in transit",
            "tracking", "your order", "your package", "your shipment",
            "expected to arrive", "expected delivery", "arriving",
            "label created", "shipment update", "package update",
            "has shipped", "is on the way", "on its way",
        ]
        return emails.filter { email in
            let from = email.from.lowercased()
            let subject = email.subject.lowercased()
            if senderNeedles.contains(where: { from.contains($0) }) { return true }
            if subjectNeedles.contains(where: { subject.contains($0) }) { return true }
            return false
        }
    }

    /// Reconciles Claude's output with the previous deliveries state. Owns:
    ///   - Stable `id` assignment for new items
    ///   - Preservation of `dateOrdered` for known items (Claude can't change it)
    ///   - Stamping `dateDelivered` on ordered→delivered transitions
    ///   - Carrying forward previous items Claude omitted (defensive — Claude shouldn't
    ///     silently drop ordered items, but if it does, we keep them)
    ///   - Dropping delivered items older than 2 days
    private func reconcileDeliveryDates(
        new: [Briefing.Delivery],
        previous: [Briefing.Delivery],
        now: Date
    ) -> [Briefing.Delivery] {
        let calendar = Calendar.current
        guard let twoDaysAgoStart = calendar.date(
            byAdding: .day,
            value: -2,
            to: calendar.startOfDay(for: now)
        ) else {
            return previous
        }

        var prevByID: [String: Briefing.Delivery] = [:]
        for d in previous { prevByID[d.id] = d }

        // Build the reconciled list, indexed by id.
        var reconciledByID: [String: Briefing.Delivery] = [:]

        for delivery in new {
            let id = delivery.id.isEmpty ? UUID().uuidString : delivery.id

            if let prev = prevByID[id] {
                // Existing item — preserve dateOrdered always (Claude can't change it).
                // For state transitions, prefer Claude's extracted dateDelivered; if missing,
                // fall back to the previous value, then to today.
                let dateDelivered: Date?
                if delivery.state == "delivered" {
                    dateDelivered = delivery.dateDelivered ?? prev.dateDelivered ?? now
                } else {
                    dateDelivered = nil
                }
                reconciledByID[id] = Briefing.Delivery(
                    id: id,
                    state: delivery.state,
                    item: delivery.item,
                    dateOrdered: prev.dateOrdered,
                    dateDelivered: dateDelivered
                )
            } else {
                // New item — use Claude's extracted dates when available. If Claude couldn't
                // determine the order date (e.g., we only saw a shipping email this run, not
                // the original order confirmation), leave dateOrdered nil so the UI can
                // show "unknown" rather than misleadingly stamping today.
                reconciledByID[id] = Briefing.Delivery(
                    id: id,
                    state: delivery.state,
                    item: delivery.item,
                    dateOrdered: delivery.dateOrdered,
                    dateDelivered: delivery.state == "delivered" ? (delivery.dateDelivered ?? now) : nil
                )
            }
        }

        // Defensive: carry forward any previous items Claude failed to return. The prompt
        // tells Claude not to drop items, but if it does we don't lose them.
        for prev in previous where reconciledByID[prev.id] == nil {
            Logger.shared.info("Carrying forward delivery '\(prev.item)' (id=\(prev.id)) — Claude omitted it")
            reconciledByID[prev.id] = prev
        }

        // Drop delivered items older than 2 days. Ordered items NEVER auto-drop.
        return reconciledByID.values.filter { delivery in
            guard delivery.state == "delivered" else { return true }
            guard let at = delivery.dateDelivered else { return false }
            return at >= twoDaysAgoStart
        }.sorted { (a, b) in
            // Sort by dateOrdered descending; nil dates sort last.
            switch (a.dateOrdered, b.dateOrdered) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.item < b.item
            }
        }
    }

    /// Detects trips from calendar events. A trip is any event (from a non-holiday calendar)
    /// whose **title contains "trip"** AND whose location or notes contains a `City, ST` pattern.
    private func fetchTrips(from events: [CalendarEvent]) async -> [TripForecast] {
        let cityStatePattern = #"\b[A-Za-z][A-Za-z\.\s]{1,40},\s*[A-Za-z]{2}\b"#

        let candidates: [(CalendarEvent, String)] = events.compactMap { event in
            // Skip events from holiday-style calendars to avoid Memorial Day / Cinco de Mayo / etc.
            if event.calendarName.localizedCaseInsensitiveContains("holiday") {
                return nil
            }
            // Title must contain "trip" (case-insensitive).
            guard event.title.localizedCaseInsensitiveContains("trip") else {
                return nil
            }
            // Location or notes must contain a City, ST.
            for field in [event.location ?? "", event.notes ?? ""] where !field.isEmpty {
                if let match = field.range(of: cityStatePattern, options: .regularExpression) {
                    let location = String(field[match]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (event, location)
                }
            }
            Logger.shared.info("Trip detection: '\(event.title)' has 'trip' in title but no City, ST in location/notes")
            return nil
        }

        Logger.shared.info("Trip detection: scanned \(events.count) events, \(candidates.count) trip candidate(s)")

        var results: [TripForecast] = []
        for (event, location) in candidates {
            do {
                let summary = try await weatherSource.fetchTripForecast(
                    for: location,
                    dates: event.startDate...event.endDate
                )
                results.append(TripForecast(event: event, location: location, summary: summary, error: nil))
            } catch {
                Logger.shared.error("Trip weather fetch for \(location) failed: \(error.localizedDescription)")
                results.append(TripForecast(event: event, location: location, summary: "", error: error.localizedDescription))
            }
        }
        return results
    }

    private func writeBriefing(markdown: String) throws -> URL {
        let config = configStore.load()
        let dir = Self.briefingsDirectory(in: config.vaultPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = formatter.string(from: Date()) + ".md"
        let url = dir.appendingPathComponent(filename)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func briefingsDirectory(in vaultPath: URL) -> URL {
        vaultPath.appendingPathComponent("Daily Briefing", isDirectory: true)
    }

    static func mostRecentBriefing(in vaultPath: URL) -> (url: URL, date: Date)? {
        let dir = briefingsDirectory(in: vaultPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        return contents
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }
    }
}

enum BriefingError: LocalizedError {
    case missingAPIKey
    case calendarAccessDenied

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key not set. Use the field at the bottom of the Briefing window."
        case .calendarAccessDenied:
            return "Calendar access denied. Enable it in System Settings → Privacy & Security → Calendars."
        }
    }
}
