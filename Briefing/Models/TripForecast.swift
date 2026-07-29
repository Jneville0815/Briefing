//
//  TripForecast.swift
//  Briefing
//

import Foundation

struct TripForecast: Sendable {
    let event: CalendarEvent
    let location: String
    let summary: String   // human-readable forecast summary, possibly empty
    let error: String?
}
