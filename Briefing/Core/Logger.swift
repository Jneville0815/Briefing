//
//  Logger.swift
//  Briefing
//

import Foundation
import os

final class Logger: Sendable {
    static let shared = Logger()

    private let logger: os.Logger

    private init() {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.jimmy.briefing.Briefing"
        self.logger = os.Logger(subsystem: subsystem, category: "Briefing")
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
