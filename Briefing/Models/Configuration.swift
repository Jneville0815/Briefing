//
//  Configuration.swift
//  Briefing
//

import Foundation

struct Configuration: Sendable {
    var vaultPath: URL
    var dailyNotesSubpath: String
    var dailyNoteDateFormat: String
    var homeLocation: String   // e.g. "Atlanta, GA" — used for today's weather lookup

    static let `default` = Configuration(
        vaultPath: FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Obsidian"),
        dailyNotesSubpath: "Daily",
        dailyNoteDateFormat: "yyyy-MM-dd",
        homeLocation: ""
    )
}

extension Configuration: Codable {
    private enum CodingKeys: String, CodingKey {
        case vaultPath, dailyNotesSubpath, dailyNoteDateFormat, homeLocation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .vaultPath)
        let expanded = (raw as NSString).expandingTildeInPath
        self.vaultPath = URL(fileURLWithPath: expanded, isDirectory: true)
        self.dailyNotesSubpath = try container.decode(String.self, forKey: .dailyNotesSubpath)
        self.dailyNoteDateFormat = try container.decode(String.self, forKey: .dailyNoteDateFormat)
        self.homeLocation = try container.decodeIfPresent(String.self, forKey: .homeLocation) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vaultPath.path, forKey: .vaultPath)
        try container.encode(dailyNotesSubpath, forKey: .dailyNotesSubpath)
        try container.encode(dailyNoteDateFormat, forKey: .dailyNoteDateFormat)
        try container.encode(homeLocation, forKey: .homeLocation)
    }
}

final class ConfigurationStore {
    static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("Briefing", isDirectory: true)
            .appendingPathComponent("config.json")
    }()

    func load() -> Configuration {
        let url = Self.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let config = Configuration.default
            save(config)
            Logger.shared.info("Created default config at \(url.path) — edit it to point vaultPath at your Obsidian vault.")
            return config
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Configuration.self, from: data)
        } catch {
            Logger.shared.error("Failed to load config (\(error.localizedDescription)); using defaults.")
            return Configuration.default
        }
    }

    func save(_ configuration: Configuration) {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.shared.error("Failed to save config: \(error.localizedDescription)")
        }
    }
}
