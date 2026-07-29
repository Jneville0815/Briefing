//
//  CalendarSource.swift
//  Briefing
//

import Foundation
import EventKit

actor CalendarSource {
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func fetchUpcomingEvents(daysAhead: Int = 16) async throws -> [CalendarEvent] {
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)

        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    location: event.location,
                    notes: event.notes,
                    calendarName: event.calendar.title,
                    isAllDay: event.isAllDay
                )
            }
    }
}
