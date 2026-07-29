//
//  MarkdownExporter.swift
//  Briefing
//

import Foundation

struct MarkdownExporter: Sendable {
    func render(
        _ briefing: Briefing,
        recurringTasks: [RecurringTask] = [],
        events: [CalendarEvent] = [],
        generatedAt: Date = Date()
    ) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        var lines: [String] = []

        lines.append("# Briefing — \(dayFormatter.string(from: generatedAt))")
        lines.append("")

        lines.append("## Today")
        lines.append(briefing.today.summary)
        if !briefing.today.weather.isEmpty {
            lines.append("")
            lines.append("**Weather:** \(briefing.today.weather)")
        }
        if !briefing.today.items.isEmpty {
            lines.append("")
            for item in briefing.today.items {
                lines.append("- \(item)")
            }
        }
        lines.append("")

        if !briefing.reminders.isEmpty {
            lines.append("## Reminders")
            for reminder in briefing.reminders {
                lines.append("- \(reminder)")
            }
            lines.append("")
        }

        if !briefing.thisWeek.isEmpty {
            lines.append("## This Week")
            let weekFormatter = DateFormatter()
            weekFormatter.dateFormat = "EEE MMM d"
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: generatedAt)
            for day in briefing.thisWeek {
                let date = calendar.date(byAdding: .day, value: day.dayOffset, to: todayStart) ?? generatedAt
                lines.append("**\(weekFormatter.string(from: date))**")
                for item in day.items {
                    lines.append("- \(item)")
                }
                lines.append("")
            }
        }

        if !briefing.upcomingTrips.isEmpty {
            lines.append("## Upcoming Trips")
            for trip in briefing.upcomingTrips {
                lines.append("### \(trip.title) — \(trip.destination) (\(trip.dates))")
                lines.append(trip.weather)
                lines.append("")
            }
        }

        if !recurringTasks.isEmpty {
            lines.append("## Recurring")
            for task in recurringTasks {
                let statusText: String
                switch task.status(events: events) {
                case .noRecord: statusText = "no record"
                case .ok(let n): statusText = "OK (\(n) days until due)"
                case .due(let n): statusText = "DUE (\(n) days since)"
                case .overdue(let n): statusText = "OVERDUE by \(n) days"
                case .scheduled(_, let n):
                    if n == 0 { statusText = "scheduled today" }
                    else if n == 1 { statusText = "scheduled tomorrow" }
                    else { statusText = "scheduled in \(n) days" }
                }
                lines.append("- **\(task.label):** \(statusText)")
            }
            lines.append("")
        }

        if !briefing.deliveries.isEmpty {
            lines.append("## Deliveries")
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d"
            let delivered = briefing.deliveries.filter { $0.state == "delivered" }
            let ordered = briefing.deliveries.filter { $0.state == "ordered" }
            if !delivered.isEmpty {
                lines.append("**Delivered:**")
                for d in delivered {
                    let when = d.dateDelivered.map { dateFormatter.string(from: $0) } ?? "—"
                    lines.append("- \(d.item) — delivered \(when)")
                }
            }
            if !ordered.isEmpty {
                if !delivered.isEmpty { lines.append("") }
                lines.append("**Ordered:**")
                for d in ordered {
                    let when = d.dateOrdered.map { dateFormatter.string(from: $0) } ?? "date unknown"
                    lines.append("- \(d.item) — ordered \(when)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
