//
//  BriefingStore.swift
//  Briefing
//

import Foundation
import Observation

@MainActor
@Observable
final class BriefingStore {
    private let runner: BriefingRunner
    private let gmailSource: GmailSource
    private let factStore = FactStore()
    private let keychain = KeychainHelper()

    var events: [CalendarEvent] = []
    var notes: [VaultNote] = []
    var emails: [EmailMessage] = []
    var trips: [TripForecast] = []
    var todayWeather: TodayWeather?
    var briefing: Briefing?
    var recurringTasks: [RecurringTask] = []
    var dailyReminders: [DailyReminder] = []
    var outputURL: URL?
    var lastRun: Date?
    var isRunning = false
    var currentStep: String?
    var lastError: String?
    var hasAPIKey = false
    var gmailConnected = false

    init() {
        let calendarSource = CalendarSource()
        let gmail = GmailSource()
        let configStore = ConfigurationStore()
        self.gmailSource = gmail
        self.runner = BriefingRunner(
            calendarSource: calendarSource,
            gmailSource: gmail,
            configStore: configStore
        )

        hasAPIKey = (keychain.loadAPIKey()?.isEmpty == false)
        gmailConnected = gmail.isAuthenticated()
        let initialFacts = factStore.load()
        recurringTasks = initialFacts.recurringTasks
        dailyReminders = initialFacts.dailyReminders

        let config = configStore.load()
        if let latest = BriefingRunner.mostRecentBriefing(in: config.vaultPath) {
            self.lastRun = latest.date
            self.outputURL = latest.url
        }

        Task { [gmail] in
            await gmail.restoreSignInIfPossible()
            self.gmailConnected = gmail.isAuthenticated()
        }
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        currentStep = "Starting…"
        lastError = nil
        defer {
            isRunning = false
            currentStep = nil
        }

        let progressHandler: BriefingRunner.ProgressHandler = { [weak self] step in
            await self?.updateProgress(step)
        }

        do {
            let result = try await runner.run(progress: progressHandler)
            self.events = await runner.lastEvents
            self.notes = await runner.lastNotes
            self.emails = await runner.lastEmails
            self.trips = await runner.lastTrips
            self.todayWeather = await runner.lastTodayWeather
            self.outputURL = await runner.lastOutputURL
            self.briefing = result
            let refreshedFacts = factStore.load()
            self.recurringTasks = refreshedFacts.recurringTasks
            self.dailyReminders = refreshedFacts.dailyReminders
            self.lastRun = Date()
        } catch {
            Logger.shared.error("Briefing failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func updateProgress(_ step: String) {
        currentStep = step
    }

    func markRecurringDone(_ taskId: String) {
        var current = factStore.load()
        guard let i = current.recurringTasks.firstIndex(where: { $0.id == taskId }) else { return }
        let today = Calendar.current.startOfDay(for: Date())
        current.recurringTasks[i].lastCompleted = today
        factStore.save(current)
        recurringTasks = current.recurringTasks
        Logger.shared.info("Marked \(taskId) done at \(today)")
    }

    func addDailyReminder(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = factStore.load()
        let normalized = DailyReminder.normalize(trimmed)
        // Manual add re-arms a previously-tombstoned reminder.
        current.removedReminders.removeAll(where: { $0 == normalized })
        current.dailyReminders.append(DailyReminder(id: UUID().uuidString, text: trimmed))
        factStore.save(current)
        dailyReminders = current.dailyReminders
        Logger.shared.info("Added reminder: \(trimmed)")
    }

    func removeDailyReminder(_ id: String) {
        var current = factStore.load()
        let removed = current.dailyReminders.first(where: { $0.id == id })
        current.dailyReminders.removeAll(where: { $0.id == id })
        // Tombstone the text so future runs don't re-add it from notes/emails.
        if let removed {
            let normalized = DailyReminder.normalize(removed.text)
            if !current.removedReminders.contains(normalized) {
                current.removedReminders.append(normalized)
            }
        }
        factStore.save(current)
        dailyReminders = current.dailyReminders
        Logger.shared.info("Removed reminder \(id) (tombstoned)")
    }

    /// Reorders the dailyReminders list, inserting `draggedID` directly before `beforeID`.
    /// Pass `beforeID == nil` to move the reminder to the end of the list.
    func moveDailyReminder(draggedID: String, beforeID: String?) {
        guard draggedID != beforeID else { return }
        var current = factStore.load()
        guard let fromIdx = current.dailyReminders.firstIndex(where: { $0.id == draggedID }) else { return }
        let item = current.dailyReminders.remove(at: fromIdx)
        if let beforeID, let toIdx = current.dailyReminders.firstIndex(where: { $0.id == beforeID }) {
            current.dailyReminders.insert(item, at: toIdx)
        } else {
            current.dailyReminders.append(item)
        }
        factStore.save(current)
        dailyReminders = current.dailyReminders
        Logger.shared.info("Moved reminder \(draggedID) before \(beforeID ?? "end")")
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keychain.saveAPIKey(trimmed)
        hasAPIKey = true
    }

    func connectGmail() async {
        do {
            try await gmailSource.authenticate()
            gmailConnected = gmailSource.isAuthenticated()
            Logger.shared.info("Gmail connected: \(gmailConnected)")
        } catch {
            Logger.shared.error("Gmail connect failed: \(error.localizedDescription)")
            lastError = "Gmail connection failed: \(error.localizedDescription)"
        }
    }

    func disconnectGmail() async {
        await gmailSource.signOut()
        gmailConnected = gmailSource.isAuthenticated()
    }
}
