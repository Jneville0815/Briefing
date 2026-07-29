//
//  CalendarEvent.swift
//  Briefing
//

import Foundation

struct CalendarEvent: Codable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let calendarName: String
    let isAllDay: Bool
}
