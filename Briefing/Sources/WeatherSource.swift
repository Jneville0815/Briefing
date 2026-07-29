//
//  WeatherSource.swift
//  Briefing
//
//  Open-Meteo–backed forecasts. Free, no API key, global coverage, 16-day window.
//

import Foundation
import CoreLocation

/// Structured today-forecast value used by both the prompt (.summary string) and the
/// hero header (icon + theming inputs).
struct TodayWeather: Sendable {
    let summary: String
    let weatherCode: Int
    let high: Int
    let low: Int
    let precipChance: Int
    let rainWindow: String?
}

actor WeatherSource {
    private let geocoder = CLGeocoder()

    /// Today's forecast for a single location. Returns structured weather plus a
    /// single-line summary string like "Partly cloudy, 72°/58°F, 60% chance of rain
    /// — rain likely 2pm–6pm."
    func fetchTodayForecast(for location: String) async throws -> TodayWeather {
        let coord = try await geocode(location)
        let url = makeForecastURL(coord: coord, days: 1, hourly: true)
        let resp: OpenMeteoForecast = try await fetchJSON(url)
        guard let day = resp.firstDay() else {
            throw WeatherError.openMeteoError("No forecast returned for \(location)")
        }
        var summary = formatDay(day, includeDate: false)
        let rainWindow = resp.rainWindow(forDate: day.date)
        if let rainWindow {
            summary += " — \(rainWindow)"
        }
        return TodayWeather(
            summary: summary,
            weatherCode: day.weatherCode,
            high: Int(day.high.rounded()),
            low: Int(day.low.rounded()),
            precipChance: day.precipChance ?? 0,
            rainWindow: rainWindow
        )
    }

    /// Trip forecast across a date range. Returns one line per day in the range
    /// (whichever days fall inside Open-Meteo's 16-day window).
    func fetchTripForecast(for location: String, dates: ClosedRange<Date>) async throws -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let endDay = calendar.startOfDay(for: dates.upperBound)
        let daysOut = (calendar.dateComponents([.day], from: today, to: endDay).day ?? 0) + 1
        let forecastDays = min(max(daysOut, 1), 16)

        let coord = try await geocode(location)
        let url = makeForecastURL(coord: coord, days: forecastDays, hourly: false)
        let resp: OpenMeteoForecast = try await fetchJSON(url)

        let startDay = calendar.startOfDay(for: dates.lowerBound)
        let days = resp.allDays().filter { day in
            let s = calendar.startOfDay(for: day.date)
            return s >= startDay && s <= endDay
        }
        if days.isEmpty {
            return "Forecast unavailable — outside Open-Meteo's 16-day window. Will fill in as the trip approaches."
        }
        return days.map { formatDay($0, includeDate: true) }.joined(separator: " · ")
    }

    private func makeForecastURL(coord: CLLocationCoordinate2D, days: Int, hourly: Bool) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "latitude", value: String(coord.latitude)),
            URLQueryItem(name: "longitude", value: String(coord.longitude)),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weathercode,precipitation_probability_max"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(days)),
        ]
        if hourly {
            items.append(URLQueryItem(name: "hourly", value: "precipitation_probability"))
        }
        components.queryItems = items
        return components.url!
    }

    private func geocode(_ location: String) async throws -> CLLocationCoordinate2D {
        let placemarks = try await geocoder.geocodeAddressString(location)
        guard let coord = placemarks.first?.location?.coordinate else {
            throw WeatherError.geocodingFailed(location)
        }
        return coord
    }

    private func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw WeatherError.openMeteoError("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let preview = String(data: data, encoding: .utf8)?.prefix(200).description ?? "<no body>"
            throw WeatherError.openMeteoError("HTTP \(http.statusCode): \(preview)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func formatDay(_ day: OpenMeteoForecast.Day, includeDate: Bool) -> String {
        let high = Int(day.high.rounded())
        let low = Int(day.low.rounded())
        let condition = wmoDescription(day.weatherCode)
        let precip = day.precipChance ?? 0
        var s = "\(condition), \(high)°/\(low)°F, \(precip)% chance of rain"
        if includeDate {
            let f = DateFormatter()
            f.dateFormat = "EEE MMM d"
            s = "\(f.string(from: day.date)): \(s)"
        }
        return s
    }

    private func wmoDescription(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Foggy"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75: return "Snow"
        case 77: return "Snow grains"
        case 80, 81, 82: return "Rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unknown"
        }
    }
}

enum WeatherError: LocalizedError {
    case geocodingFailed(String)
    case openMeteoError(String)

    var errorDescription: String? {
        switch self {
        case .geocodingFailed(let loc): return "Could not geocode location: \(loc)"
        case .openMeteoError(let detail): return "Open-Meteo error: \(detail)"
        }
    }
}

private struct OpenMeteoForecast: Decodable {
    let daily: Daily
    let hourly: Hourly?

    struct Daily: Decodable {
        let time: [String]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let weathercode: [Int]
        let precipitation_probability_max: [Int?]
    }

    struct Hourly: Decodable {
        let time: [String]
        let precipitation_probability: [Int?]
    }

    struct Day {
        let date: Date
        let high: Double
        let low: Double
        let weatherCode: Int
        let precipChance: Int?
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static let displayHourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "ha"     // 2pm, 11am
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    func allDays() -> [Day] {
        var out: [Day] = []
        for (i, t) in daily.time.enumerated() {
            guard let d = Self.dayFormatter.date(from: t) else { continue }
            out.append(Day(
                date: d,
                high: daily.temperature_2m_max[i],
                low: daily.temperature_2m_min[i],
                weatherCode: daily.weathercode[i],
                precipChance: i < daily.precipitation_probability_max.count
                    ? daily.precipitation_probability_max[i]
                    : nil
            ))
        }
        return out
    }

    func firstDay() -> Day? { allDays().first }

    /// Returns a phrase like "rain likely 2pm–6pm" if the hourly forecast shows
    /// contiguous high-probability rain hours on the given date. Returns nil if
    /// no hourly data, no rain hours, or the chance never crosses the threshold.
    func rainWindow(forDate date: Date) -> String? {
        guard let hourly else { return nil }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // Pair each hourly timestamp with its probability, filter to today, and find
        // the longest contiguous run with chance >= threshold.
        let threshold = 40
        var hours: [(date: Date, chance: Int)] = []
        for (i, t) in hourly.time.enumerated() {
            guard i < hourly.precipitation_probability.count,
                  let chance = hourly.precipitation_probability[i],
                  let h = Self.hourFormatter.date(from: t),
                  h >= dayStart, h < dayEnd else { continue }
            hours.append((h, chance))
        }
        guard !hours.isEmpty else { return nil }

        // Find the longest contiguous run of hours with chance >= threshold.
        var bestStart: Date?
        var bestEnd: Date?
        var bestLen = 0
        var curStart: Date?
        var curLen = 0
        for h in hours {
            if h.chance >= threshold {
                if curStart == nil { curStart = h.date }
                curLen += 1
                if curLen > bestLen {
                    bestLen = curLen
                    bestStart = curStart
                    bestEnd = h.date
                }
            } else {
                curStart = nil
                curLen = 0
            }
        }
        guard let s = bestStart, let e = bestEnd else { return nil }
        let endHour = calendar.date(byAdding: .hour, value: 1, to: e) ?? e
        let startStr = Self.displayHourFormatter.string(from: s).lowercased()
        let endStr = Self.displayHourFormatter.string(from: endHour).lowercased()
        return "rain likely \(startStr)–\(endStr)"
    }
}
