//
//  VaultNote.swift
//  Briefing
//

import Foundation

struct VaultNote: Sendable {
    let date: Date
    let path: URL
    let rawContent: String
}
