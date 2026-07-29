//
//  VaultSource.swift
//  Briefing
//

import Foundation

struct VaultSource: Sendable {
    let configuration: Configuration

    /// Fetches all daily notes whose filename date falls in `[since, until]` (inclusive, day-resolution).
    /// Missing daily-note files are skipped silently.
    func fetchDailyNotes(since: Date, until: Date) async throws -> [VaultNote] {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: since)
        let endDay = calendar.startOfDay(for: until)
        guard startDay <= endDay else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = configuration.dailyNoteDateFormat

        let dailyDir = configuration.dailyNotesSubpath.isEmpty
            ? configuration.vaultPath
            : configuration.vaultPath.appendingPathComponent(configuration.dailyNotesSubpath, isDirectory: true)

        var notes: [VaultNote] = []
        var current = startDay
        while current <= endDay {
            let filename = formatter.string(from: current) + ".md"
            let noteURL = dailyDir.appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: noteURL.path) {
                do {
                    let content = try String(contentsOf: noteURL, encoding: .utf8)
                    notes.append(VaultNote(date: current, path: noteURL, rawContent: content))
                } catch {
                    Logger.shared.error("Failed to read \(noteURL.path): \(error.localizedDescription)")
                }
            }

            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        return notes.sorted { $0.date > $1.date }
    }
}
