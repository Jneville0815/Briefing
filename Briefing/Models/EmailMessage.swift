//
//  EmailMessage.swift
//  Briefing
//

import Foundation

struct EmailMessage: Codable, Sendable, Identifiable {
    let id: String
    let threadId: String
    let from: String
    let to: [String]
    let subject: String
    let snippet: String
    let bodyText: String
    let receivedAt: Date
    let labelIds: [String]
}
