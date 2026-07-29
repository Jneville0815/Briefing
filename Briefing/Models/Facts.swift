//
//  Facts.swift
//  Briefing
//

import Foundation

struct NotifyContact: Codable, Sendable, Equatable {
    var name: String
    var phone: String
    var messageTemplate: String
}

struct RecurringTask: Codable, Sendable, Identifiable {
    var id: String
    var label: String
    var cadenceDays: Int
    var lastCompleted: Date?
    var matchCalendarTitles: [String]
    var matchEmailSenders: [String]
    var matchEmailSubjects: [String]
    /// When true, the UI shows a "mark done" button. When false (default), the task is
    /// tracked automatically from email/calendar matches.
    var requiresManualLog: Bool
    /// When set, the UI shows a message-bubble button (when status is DUE/OVERDUE/NO RECORD)
    /// that opens Messages.app with this contact pre-filled.
    var notifyContact: NotifyContact?
    /// When set, the UI shows a link button (when status is DUE/OVERDUE/NO RECORD) that
    /// opens this URL in the default browser — typically a booking or reorder page.
    var bookingURL: String?

    init(
        id: String,
        label: String,
        cadenceDays: Int,
        lastCompleted: Date? = nil,
        matchCalendarTitles: [String] = [],
        matchEmailSenders: [String] = [],
        matchEmailSubjects: [String] = [],
        requiresManualLog: Bool = false,
        notifyContact: NotifyContact? = nil,
        bookingURL: String? = nil
    ) {
        self.id = id
        self.label = label
        self.cadenceDays = cadenceDays
        self.lastCompleted = lastCompleted
        self.matchCalendarTitles = matchCalendarTitles
        self.matchEmailSenders = matchEmailSenders
        self.matchEmailSubjects = matchEmailSubjects
        self.requiresManualLog = requiresManualLog
        self.notifyContact = notifyContact
        self.bookingURL = bookingURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, cadenceDays, cadenceDaysMin, cadenceDaysMax, lastCompleted
        case matchCalendarTitles, matchEmailSenders, matchEmailSubjects
        case requiresManualLog, notifyContact, bookingURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        // Prefer the new single `cadenceDays`; fall back to legacy `cadenceDaysMin` for
        // older facts.json files that haven't been rewritten yet.
        if let cadence = try c.decodeIfPresent(Int.self, forKey: .cadenceDays) {
            self.cadenceDays = cadence
        } else if let legacyMin = try c.decodeIfPresent(Int.self, forKey: .cadenceDaysMin) {
            self.cadenceDays = legacyMin
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.cadenceDays,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing cadenceDays")
            )
        }
        self.lastCompleted = try c.decodeIfPresent(Date.self, forKey: .lastCompleted)
        self.matchCalendarTitles = try c.decodeIfPresent([String].self, forKey: .matchCalendarTitles) ?? []
        self.matchEmailSenders = try c.decodeIfPresent([String].self, forKey: .matchEmailSenders) ?? []
        self.matchEmailSubjects = try c.decodeIfPresent([String].self, forKey: .matchEmailSubjects) ?? []
        self.requiresManualLog = try c.decodeIfPresent(Bool.self, forKey: .requiresManualLog) ?? false
        self.notifyContact = try c.decodeIfPresent(NotifyContact.self, forKey: .notifyContact)
        self.bookingURL = try c.decodeIfPresent(String.self, forKey: .bookingURL)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(cadenceDays, forKey: .cadenceDays)
        try c.encodeIfPresent(lastCompleted, forKey: .lastCompleted)
        try c.encode(matchCalendarTitles, forKey: .matchCalendarTitles)
        try c.encode(matchEmailSenders, forKey: .matchEmailSenders)
        try c.encode(matchEmailSubjects, forKey: .matchEmailSubjects)
        try c.encode(requiresManualLog, forKey: .requiresManualLog)
        try c.encodeIfPresent(notifyContact, forKey: .notifyContact)
        try c.encodeIfPresent(bookingURL, forKey: .bookingURL)
    }

    enum Status: Sendable, Equatable {
        case noRecord
        case ok(daysUntilDue: Int)
        case due(daysSince: Int)
        case overdue(daysOverdue: Int)
        case scheduled(date: Date, daysUntil: Int)
    }

    var hasEmailMatchers: Bool {
        !matchEmailSenders.isEmpty || !matchEmailSubjects.isEmpty
    }

    func status(
        asOf reference: Date = Date(),
        events: [CalendarEvent] = []
    ) -> Status {
        if let upcoming = nextScheduledMatch(in: events, after: reference) {
            let days = Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: reference),
                to: Calendar.current.startOfDay(for: upcoming.startDate)
            ).day ?? 0
            return .scheduled(date: upcoming.startDate, daysUntil: max(0, days))
        }

        guard let last = effectiveLastCompleted(asOf: reference, events: events) else {
            return .noRecord
        }

        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: last),
            to: calendar.startOfDay(for: reference)
        ).day ?? 0

        if days > cadenceDays {
            return .overdue(daysOverdue: days - cadenceDays)
        } else if days == cadenceDays {
            return .due(daysSince: days)
        } else {
            return .ok(daysUntilDue: cadenceDays - days)
        }
    }

    /// Most recent of (manual `lastCompleted`) and (most-recent matching past calendar event).
    /// Email-derived completions are persisted into `lastCompleted` by the runner, so they're
    /// already reflected here.
    func effectiveLastCompleted(
        asOf reference: Date = Date(),
        events: [CalendarEvent] = []
    ) -> Date? {
        let manual = lastCompleted.flatMap { $0 <= reference ? $0 : nil }
        let calendarLast = lastCalendarMatch(in: events, before: reference)
        return [manual, calendarLast].compactMap { $0 }.max()
    }

    /// Most recent received email that matches this task's email patterns.
    /// Used by the runner to update `lastCompleted` after each Gmail fetch.
    func lastEmailMatch(in emails: [EmailMessage], before reference: Date = Date()) -> Date? {
        let senderNeedles = matchEmailSenders.map { $0.lowercased() }
        let subjectNeedles = matchEmailSubjects.map { $0.lowercased() }
        guard !senderNeedles.isEmpty || !subjectNeedles.isEmpty else { return nil }
        return emails
            .filter { $0.receivedAt <= reference }
            .filter { email in
                let from = email.from.lowercased()
                let subject = email.subject.lowercased()
                let senderOK = senderNeedles.isEmpty || senderNeedles.contains(where: { from.contains($0) })
                let subjectOK = subjectNeedles.isEmpty || subjectNeedles.contains(where: { subject.contains($0) })
                return senderOK && subjectOK
            }
            .map { $0.receivedAt }
            .max()
    }

    private func nextScheduledMatch(in events: [CalendarEvent], after reference: Date) -> CalendarEvent? {
        let needles = matchCalendarTitles.map { $0.lowercased() }
        guard !needles.isEmpty else { return nil }
        return events
            .filter { $0.startDate > reference && titleMatches($0.title, needles: needles) }
            .min(by: { $0.startDate < $1.startDate })
    }

    private func lastCalendarMatch(in events: [CalendarEvent], before reference: Date) -> Date? {
        let needles = matchCalendarTitles.map { $0.lowercased() }
        guard !needles.isEmpty else { return nil }
        return events
            .filter { $0.startDate <= reference && titleMatches($0.title, needles: needles) }
            .map { $0.startDate }
            .max()
    }

    private func titleMatches(_ title: String, needles: [String]) -> Bool {
        let lower = title.lowercased()
        return needles.contains(where: { lower.contains($0) })
    }
}

struct DailyReminder: Codable, Sendable, Identifiable {
    var id: String
    var text: String

    /// Trimmed + lowercased text — used for dedupe and tombstone comparisons so trivial
    /// case/whitespace variations don't bypass the dedupe.
    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Common English filler words that inflate similarity scores without carrying meaning.
    /// Kept short — only the most generic words.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "for", "in", "on", "at",
        "by", "with", "from", "is", "are", "was", "were", "be", "been",
        "have", "has", "had", "this", "that", "it", "its", "as"
    ]

    /// Lowercased alphanumeric word tokens, dropping stop words and 1-character tokens.
    /// Used by the Jaccard similarity check to detect semantically-identical reminders
    /// that differ only in phrasing.
    static func tokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let raw = lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(raw.filter { $0.count > 1 && !stopWords.contains($0) })
    }

    /// Token-set Jaccard similarity in [0, 1]. Returns 0 for either-empty input.
    static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a)
        let tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let intersection = ta.intersection(tb).count
        let union = ta.union(tb).count
        return Double(intersection) / Double(union)
    }
}

struct EmailFilters: Codable, Sendable {
    var excludeSubjectContains: [String] = []
    var excludeSenderContains: [String] = []
}

struct Facts: Codable, Sendable {
    var recurringTasks: [RecurringTask] = []
    var dailyReminders: [DailyReminder] = []
    var emailFilters: EmailFilters = EmailFilters()
    /// Normalized texts of reminders the user has removed via the UI. Newly-surfaced
    /// reminders matching one of these are filtered out instead of re-added.
    var removedReminders: [String] = []

    init(
        recurringTasks: [RecurringTask] = [],
        dailyReminders: [DailyReminder] = [],
        emailFilters: EmailFilters = EmailFilters(),
        removedReminders: [String] = []
    ) {
        self.recurringTasks = recurringTasks
        self.dailyReminders = dailyReminders
        self.emailFilters = emailFilters
        self.removedReminders = removedReminders
    }

    private enum CodingKeys: String, CodingKey {
        case recurringTasks, dailyReminders, emailFilters, removedReminders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.recurringTasks = try c.decodeIfPresent([RecurringTask].self, forKey: .recurringTasks) ?? []
        self.dailyReminders = try c.decodeIfPresent([DailyReminder].self, forKey: .dailyReminders) ?? []
        self.emailFilters = try c.decodeIfPresent(EmailFilters.self, forKey: .emailFilters) ?? EmailFilters()
        self.removedReminders = try c.decodeIfPresent([String].self, forKey: .removedReminders) ?? []
    }

    static let `default` = Facts(
        recurringTasks: [
            RecurringTask(
                id: "haircut",
                label: "Haircut",
                cadenceDays: 21,
                matchCalendarTitles: ["haircut", "hair cut", "barber"],
                matchEmailSenders: ["squareup.com", "messaging.squareup.com"]
            ),
            RecurringTask(
                id: "instacart",
                label: "InstaCart order",
                cadenceDays: 4,
                matchEmailSenders: ["instacart.com"]
            ),
            RecurringTask(
                id: "digestive_enzymes",
                label: "Digestive enzymes order (Fullscript)",
                cadenceDays: 30,
                matchEmailSenders: ["fullscript.com"]
            ),
            RecurringTask(
                id: "riley_meds",
                label: "Riley's meds refill",
                cadenceDays: 30,
                matchCalendarTitles: ["riley meds", "riley refill"],
                requiresManualLog: true
            ),
            RecurringTask(
                id: "couch_wash",
                label: "Wash couch",
                cadenceDays: 180,
                requiresManualLog: true
            ),
            RecurringTask(
                id: "leather_shoe_care",
                label: "Leather shoe care",
                cadenceDays: 180,
                requiresManualLog: true
            ),
            RecurringTask(
                id: "truck_wash",
                label: "Wash truck",
                cadenceDays: 90,
                requiresManualLog: true
            ),
        ],
        dailyReminders: [
            DailyReminder(id: "disc_golf_form", text: "Focus on one link when putting; balance on your back foot when throwing backhand"),
            DailyReminder(id: "claude_balance_check", text: "Check Claude API balance: https://console.claude.com/settings/billing"),
        ],
        emailFilters: EmailFilters(
            excludeSubjectContains: [],
            excludeSenderContains: []
        )
    )
}

final class FactStore {
    static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("Briefing", isDirectory: true)
            .appendingPathComponent("facts.json")
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    func load() -> Facts {
        let url = Self.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let facts = Facts.default
            save(facts)
            Logger.shared.info("Created default facts at \(url.path) — set lastCompleted dates and tweak cadences as needed.")
            return facts
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .formatted(Self.dateFormatter)
            return try decoder.decode(Facts.self, from: data)
        } catch {
            Logger.shared.error("Failed to load facts (\(error.localizedDescription)); using defaults.")
            return Facts.default
        }
    }

    func save(_ facts: Facts) {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .formatted(Self.dateFormatter)
            let data = try encoder.encode(facts)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.shared.error("Failed to save facts: \(error.localizedDescription)")
        }
    }
}
