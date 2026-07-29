//
//  DeliveriesState.swift
//  Briefing
//

import Foundation

struct DeliveriesState: Codable, Sendable {
    var items: [Briefing.Delivery]

    static let empty = DeliveriesState(items: [])
}

final class DeliveriesStore {
    static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("Briefing", isDirectory: true)
            .appendingPathComponent("deliveries.json")
    }()

    func load() -> DeliveriesState {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(DeliveriesState.self, from: data)
        } catch {
            Logger.shared.error("Failed to load deliveries state (\(error.localizedDescription)); resetting.")
            return .empty
        }
    }

    func save(_ state: DeliveriesState) {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.shared.error("Failed to save deliveries state: \(error.localizedDescription)")
        }
    }
}
