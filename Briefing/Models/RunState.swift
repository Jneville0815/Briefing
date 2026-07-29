//
//  RunState.swift
//  Briefing
//

import Foundation

struct RunState: Codable, Sendable {
    var lastRunAt: Date?
}

final class RunStateStore {
    static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("Briefing", isDirectory: true)
            .appendingPathComponent("state.json")
    }()

    func load() -> RunState {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RunState(lastRunAt: nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(RunState.self, from: data)
        } catch {
            Logger.shared.error("Failed to load run state (\(error.localizedDescription)); resetting.")
            return RunState(lastRunAt: nil)
        }
    }

    func save(_ state: RunState) {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.shared.error("Failed to save run state: \(error.localizedDescription)")
        }
    }
}
