//
//  Briefing.swift
//  Briefing
//

import Foundation

struct Briefing: Codable, Sendable {
    var today: Today
    let reminders: [String]
    let thisWeek: [WeekDay]
    let upcomingTrips: [Trip]
    var deliveries: [Delivery]

    struct Today: Codable, Sendable {
        let summary: String
        var weather: String      // app-managed; overridden after parse
        let items: [String]
    }

    struct WeekDay: Codable, Sendable, Identifiable {
        var id: Int { dayOffset }
        let dayOffset: Int       // 0 = today, 1 = tomorrow, … 6 = six days from now
        let items: [String]
    }

    struct Trip: Codable, Sendable, Identifiable {
        var id: String { "\(title)-\(dates)" }
        let title: String        // "Family beach trip"
        let destination: String  // "Outer Banks, NC"
        let dates: String        // "May 2-5"
        let weather: String      // forecast summary
    }

    struct Delivery: Codable, Sendable, Identifiable {
        var id: String           // stable UUID assigned on first detection; persists across runs
        let state: String        // "ordered" or "delivered"
        let item: String         // "Ray-Ban sunglasses"
        var dateOrdered: Date?   // nil if Claude couldn't determine the real order date
        var dateDelivered: Date? // set when state transitions to "delivered"

        // Custom decoder to gracefully load older state files that used `details` + `deliveredAt`.
        private enum CodingKeys: String, CodingKey {
            case id, state, item, dateOrdered, dateDelivered
            case deliveredAt   // legacy
        }

        init(
            id: String = UUID().uuidString,
            state: String,
            item: String,
            dateOrdered: Date?,
            dateDelivered: Date? = nil
        ) {
            self.id = id
            self.state = state
            self.item = item
            self.dateOrdered = dateOrdered
            self.dateDelivered = dateDelivered
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Generate an ID if loading legacy state without one or if Claude returns "".
            let rawID = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            self.id = rawID.isEmpty ? UUID().uuidString : rawID
            self.state = try c.decode(String.self, forKey: .state)
            self.item = try c.decode(String.self, forKey: .item)
            self.dateOrdered = Self.decodeDate(from: c, key: .dateOrdered)
            // dateDelivered: prefer the new field, fall back to the legacy `deliveredAt`.
            self.dateDelivered = Self.decodeDate(from: c, key: .dateDelivered)
                ?? Self.decodeDate(from: c, key: .deliveredAt)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(state, forKey: .state)
            try c.encode(item, forKey: .item)
            if let d = dateOrdered {
                try c.encode(Self.dateFormatter.string(from: d), forKey: .dateOrdered)
            }
            if let dd = dateDelivered {
                try c.encode(Self.dateFormatter.string(from: dd), forKey: .dateDelivered)
            }
        }

        /// Accept dates as either `yyyy-MM-dd` strings (Claude's output, our preferred storage)
        /// or raw `Date` (legacy state files written before the string format).
        private static func decodeDate(
            from c: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Date? {
            if let str = try? c.decodeIfPresent(String.self, forKey: key),
               !str.isEmpty,
               let parsed = dateFormatter.date(from: str) {
                return parsed
            }
            if let date = try? c.decodeIfPresent(Date.self, forKey: key) {
                return date
            }
            return nil
        }

        static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            return f
        }()
    }
}
