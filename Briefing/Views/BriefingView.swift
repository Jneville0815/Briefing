//
//  BriefingView.swift
//  Briefing
//

import SwiftUI

struct BriefingView: View {
    @Bindable var store: BriefingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(12)
            }

            content

            Divider()
            VStack(spacing: 0) {
                GmailRow(store: store)
                Divider().padding(.horizontal, 10)
                APIKeyRow(store: store)
            }
        }
        .frame(minWidth: 720, minHeight: 640)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Briefing")
                    .font(.title2.bold())
                if store.isRunning, let step = store.currentStep {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(step)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if let lastRun = store.lastRun {
                    Text("Last run \(lastRun.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not run yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await store.run() }
            } label: {
                if store.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Run", systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.isRunning)
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let briefing = store.briefing {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.isRunning {
                        ProgressBanner(step: store.currentStep ?? "Working…")
                    }
                    TodayCard(today: briefing.today, weather: store.todayWeather)
                    RemindersCard(
                        reminders: store.dailyReminders,
                        onAdd: { store.addDailyReminder($0) },
                        onRemove: { store.removeDailyReminder($0) },
                        onMove: { dragged, before in
                            store.moveDailyReminder(draggedID: dragged, beforeID: before)
                        }
                    )
                    if !briefing.upcomingTrips.isEmpty {
                        TripsCard(trips: briefing.upcomingTrips)
                    }
                    if !briefing.thisWeek.isEmpty {
                        ThisWeekCard(days: briefing.thisWeek)
                    }
                    if !store.recurringTasks.isEmpty {
                        RecurringCard(
                            tasks: store.recurringTasks,
                            events: store.events,
                            markDone: { store.markRecurringDone($0) }
                        )
                    }
                    if !briefing.deliveries.isEmpty {
                        DeliveriesCard(deliveries: briefing.deliveries)
                    }
                    debugSection
                }
                .padding(16)
            }
        } else if store.isRunning {
            VStack(spacing: 18) {
                SpinningSun(size: 64)
                Text("Generating your briefing…")
                    .font(.title3.weight(.semibold))
                Text(store.currentStep ?? "Working…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ContentUnavailableView(
                "Nothing yet",
                systemImage: "sun.max",
                description: Text("Hit Run to generate today's briefing.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var debugSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 20) {
                if let weather = store.todayWeather, !weather.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today's weather (NOAA)")
                            .font(.subheadline.weight(.semibold))
                        Text(weather.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !store.trips.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Trips detected (\(store.trips.count))")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(store.trips.enumerated()), id: \.offset) { _, trip in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(trip.event.title) · \(trip.location)")
                                    .font(.caption.weight(.semibold))
                                if let err = trip.error {
                                    Text(err)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                } else {
                                    Text(trip.summary.isEmpty ? "(no forecast)" : trip.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                if !store.events.isEmpty {
                    DebugList(title: "Events", count: store.events.count) {
                        ForEach(store.events, id: \.id) { event in
                            DebugRow(primary: event.title.isEmpty ? "(No title)" : event.title,
                                     secondary: event.isAllDay ? "All day" : event.startDate.formatted(date: .abbreviated, time: .shortened),
                                     trailing: event.calendarName)
                        }
                    }
                }
                if !store.emails.isEmpty {
                    let sentToClaude = min(store.emails.count, 150)
                    DebugList(title: "Emails (\(sentToClaude) sent to Claude)", count: store.emails.count) {
                        ForEach(store.emails.prefix(150), id: \.id) { email in
                            DebugRow(primary: email.subject.isEmpty ? "(No subject)" : email.subject,
                                     secondary: email.from,
                                     trailing: email.receivedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                if !store.notes.isEmpty {
                    ForEach(store.notes, id: \.path) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Note")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(note.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(note.rawContent)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Debug — raw sources", systemImage: "wrench.and.screwdriver")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Weather helpers

private enum TimeOfDay {
    case sunrise, day, sunset, night

    static func from(date: Date) -> TimeOfDay {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<8: return .sunrise
        case 8..<17: return .day
        case 17..<20: return .sunset
        default: return .night
        }
    }

    var isNight: Bool { self == .night }
}

private enum WeatherClass {
    case clear, cloudy, foggy, rainy, snowy, stormy

    static func from(code: Int) -> WeatherClass {
        switch code {
        case 0, 1: return .clear
        case 2, 3: return .cloudy
        case 45, 48: return .foggy
        case 51...67, 80...82: return .rainy
        case 71...77, 85, 86: return .snowy
        case 95...99: return .stormy
        default: return .cloudy
        }
    }

    func symbolName(timeOfDay: TimeOfDay) -> String {
        switch self {
        case .clear:  return timeOfDay.isNight ? "moon.stars.fill" : "sun.max.fill"
        case .cloudy: return timeOfDay.isNight ? "cloud.moon.fill" : "cloud.sun.fill"
        case .foggy:  return "cloud.fog.fill"
        case .rainy:  return "cloud.rain.fill"
        case .snowy:  return "cloud.snow.fill"
        case .stormy: return "cloud.bolt.rain.fill"
        }
    }

    func label(timeOfDay: TimeOfDay) -> String {
        switch self {
        case .clear:  return timeOfDay.isNight ? "Clear" : "Sunny"
        case .cloudy: return "Cloudy"
        case .foggy:  return "Foggy"
        case .rainy:  return "Rainy"
        case .snowy:  return "Snowy"
        case .stormy: return "Stormy"
        }
    }

    enum SymbolEffectKind { case variableColor, pulse, none }
    var symbolEffectKind: SymbolEffectKind {
        switch self {
        case .clear, .rainy, .snowy, .stormy: return .variableColor
        case .cloudy, .foggy: return .pulse
        }
    }
}

extension WeatherClass {
    /// Soft-tinted gradient pair for the today-card weather chip background.
    func chipGradient(timeOfDay: TimeOfDay) -> [Color] {
        let isNight = timeOfDay.isNight
        switch self {
        case .clear:
            return isNight
                ? [Color(red: 0.18, green: 0.22, blue: 0.45).opacity(0.35),
                   Color(red: 0.06, green: 0.10, blue: 0.30).opacity(0.35)]
                : [Color.orange.opacity(0.30), Color.yellow.opacity(0.22)]
        case .cloudy, .foggy:
            return [Color.gray.opacity(0.28), Color.blue.opacity(0.18)]
        case .rainy, .stormy:
            return [Color.blue.opacity(0.32), Color.indigo.opacity(0.22)]
        case .snowy:
            return [Color(white: 0.85).opacity(0.40), Color.blue.opacity(0.18)]
        }
    }

    /// Foreground tint(s) for the SF Symbol (hierarchical rendering uses up to 3).
    var iconForegroundStyles: (Color, Color) {
        switch self {
        case .clear:  return (.yellow, .orange)
        case .cloudy, .foggy: return (.white, .gray)
        case .rainy, .stormy: return (.cyan, .blue)
        case .snowy:  return (.white, .cyan)
        }
    }
}

// MARK: - Loading

private struct SpinningSun: View {
    let size: CGFloat
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: "sun.max.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(.orange, .yellow)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

private struct ProgressBanner: View {
    let step: String

    var body: some View {
        HStack(spacing: 12) {
            SpinningSun(size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Updating briefing…")
                    .font(.callout.weight(.semibold))
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            ProgressView()
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.tint.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Cards

private struct CardContainer<Content: View>: View {
    let title: String
    let systemImage: String
    let trailing: AnyView?
    @ViewBuilder var content: () -> Content

    init(title: String, systemImage: String, trailing: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct TodayCard: View {
    let today: Briefing.Today
    let weather: TodayWeather?

    var body: some View {
        let weatherChip: AnyView? = today.weather.isEmpty ? nil : AnyView(
            WeatherChip(weatherText: today.weather, weather: weather)
        )

        return CardContainer(title: dateTitle, systemImage: "sun.max.fill", trailing: weatherChip) {
            VStack(alignment: .leading, spacing: 10) {
                Text(today.summary)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                if !today.items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(today.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundStyle(.tint)
                                    .padding(.top, 8)
                                Text(item)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private var dateTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }
}

/// Compact weather chip used as the trailing accessory on TodayCard. When structured
/// `weather` is available, the icon and tint are picked from the weather code; otherwise
/// it falls back to a generic cloud-sun icon.
private struct WeatherChip: View {
    let weatherText: String
    let weather: TodayWeather?

    var body: some View {
        let timeOfDay = TimeOfDay.from(date: Date())
        let weatherClass = weather.map { WeatherClass.from(code: $0.weatherCode) } ?? .clear

        HStack(spacing: 6) {
            iconView(weatherClass: weatherClass, timeOfDay: timeOfDay)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(weatherClass.iconForegroundStyles.0, weatherClass.iconForegroundStyles.1)
            Text(weatherText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            LinearGradient(
                colors: weatherClass.chipGradient(timeOfDay: timeOfDay),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        )
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }

    @ViewBuilder
    private func iconView(weatherClass: WeatherClass, timeOfDay: TimeOfDay) -> some View {
        let symbol = weatherClass.symbolName(timeOfDay: timeOfDay)
        let icon = Image(systemName: symbol)
        switch weatherClass.symbolEffectKind {
        case .variableColor:
            icon.symbolEffect(.variableColor.iterative.reversing, options: .repeating)
        case .pulse:
            icon.symbolEffect(.pulse, options: .repeating)
        case .none:
            icon
        }
    }
}

private struct RemindersCard: View {
    let reminders: [DailyReminder]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    let onMove: (String, String?) -> Void

    @State private var newText: String = ""
    @State private var hoveredTargetID: String?

    var body: some View {
        CardContainer(title: "Reminders", systemImage: "lightbulb.fill") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(reminders) { reminder in
                    reminderRow(for: reminder)
                }

                // Trailing drop zone — dropping here moves the dragged reminder to the end.
                Color.clear
                    .frame(height: 6)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let draggedID = ids.first else { return false }
                        onMove(draggedID, nil)
                        return true
                    }

                HStack(spacing: 8) {
                    TextField("Add a reminder…", text: $newText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                    Button("Add", action: submit)
                        .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func reminderRow(for reminder: DailyReminder) -> some View {
        let isTargeted = hoveredTargetID == reminder.id
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.6))
                .padding(.top, 4)
            Image(systemName: "sparkle")
                .font(.caption)
                .foregroundStyle(.yellow)
                .padding(.top, 4)
            Text(reminder.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: { onRemove(reminder.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove reminder")
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .draggable(reminder.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let draggedID = ids.first, draggedID != reminder.id else { return false }
            onMove(draggedID, reminder.id)
            return true
        } isTargeted: { hovering in
            hoveredTargetID = hovering ? reminder.id : (hoveredTargetID == reminder.id ? nil : hoveredTargetID)
        }
    }

    private func submit() {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        newText = ""
    }
}

private struct ThisWeekCard: View {
    let days: [Briefing.WeekDay]

    private static let dayNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    var body: some View {
        CardContainer(title: "This Week", systemImage: "calendar") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(days) { day in
                    let date = Calendar.current.date(
                        byAdding: .day,
                        value: day.dayOffset,
                        to: Calendar.current.startOfDay(for: Date())
                    ) ?? Date()
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Self.dayNameFormatter.string(from: date))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(Self.dateFormatter.string(from: date))
                                .font(.callout.weight(.semibold))
                        }
                        .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            if day.items.isEmpty {
                                Text("—")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(day.items.enumerated()), id: \.offset) { _, item in
                                    Text(item)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}

private struct TripsCard: View {
    let trips: [Briefing.Trip]

    var body: some View {
        CardContainer(title: "Upcoming Trips", systemImage: "airplane") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(trips) { trip in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(trip.title)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text(trip.dates)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(trip.destination)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(trip.weather)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .padding(.top, 2)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct RecurringCard: View {
    let tasks: [RecurringTask]
    let events: [CalendarEvent]
    let markDone: (String) -> Void

    @State private var recentlyMarked: Set<String> = []

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    var body: some View {
        let sorted = tasks.enumerated().sorted { (a, b) in
            Self.sortKey(for: a.element, events: events, originalIndex: a.offset)
                < Self.sortKey(for: b.element, events: events, originalIndex: b.offset)
        }.map(\.element)

        return CardContainer(title: "Recurring", systemImage: "repeat.circle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sorted) { task in
                    RecurringRow(
                        task: task,
                        events: events,
                        flashing: recentlyMarked.contains(task.id),
                        onMarkDone: { markAndFlash(task.id) }
                    )
                }
            }
        }
    }

    /// Sort order: NO RECORD → OVERDUE → DUE → SCHEDULED → OK.
    /// Within each bucket, secondary key orders by urgency:
    ///   - overdue: most overdue first
    ///   - scheduled: soonest first
    ///   - ok: soonest due first (so freshly-marked items naturally sink to the bottom
    ///     since they have the most days remaining)
    /// originalIndex is the final tie-breaker for stable ordering.
    private static func sortKey(
        for task: RecurringTask,
        events: [CalendarEvent],
        originalIndex: Int
    ) -> (Int, Int, Int) {
        switch task.status(events: events) {
        case .noRecord:                  return (0, 0, originalIndex)
        case .overdue(let days):         return (1, -days, originalIndex)
        case .due(let days):             return (2, -days, originalIndex)
        case .scheduled(_, let days):    return (3, days, originalIndex)
        case .ok(let days):              return (4, days, originalIndex)
        }
    }

    private func markAndFlash(_ id: String) {
        markDone(id)
        recentlyMarked.insert(id)
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            await MainActor.run {
                recentlyMarked.remove(id)
            }
        }
    }
}

private struct RecurringRow: View {
    let task: RecurringTask
    let events: [CalendarEvent]
    let flashing: Bool
    let onMarkDone: () -> Void

    @Environment(\.openURL) private var openURL

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    var body: some View {
        let info = statusInfo()
        let lastDate = task.effectiveLastCompleted(events: events)
        let lastRelative = lastDate.map { Self.relative(from: $0) }

        HStack(alignment: .center, spacing: 10) {
            StatusBadge(label: info.label, color: info.color)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.label)
                        .font(.callout.weight(.semibold))
                    if lastDate != nil {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                if let lastRelative {
                    Text("Last logged \(lastRelative) · \(info.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(info.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Each action button reserves a fixed-width column so rows stay aligned
            // even when a slot is empty for a given task.
            Group {
                if let urlString = task.bookingURL,
                   let url = URL(string: urlString),
                   shouldShowNotifyButton {
                    Button(action: { openURL(url) }) {
                        Image(systemName: "safari.fill")
                            .imageScale(.large)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(urlString)")
                }
            }
            .frame(width: 22)

            Group {
                if let contact = task.notifyContact, shouldShowNotifyButton {
                    Button(action: { sendText(to: contact) }) {
                        Image(systemName: "message.fill")
                            .imageScale(.large)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Text \(contact.name): \(contact.messageTemplate)")
                }
            }
            .frame(width: 22)

            Group {
                if task.requiresManualLog {
                    Button(action: onMarkDone) {
                        Image(systemName: "checkmark.circle")
                            .imageScale(.large)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .help("Mark \(task.label) done today")
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .help("Auto-tracked from email/calendar")
                }
            }
            .frame(width: 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(flashing ? Color.green.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.25), value: flashing)
    }

    /// True when the task is in a state where a notification text would actually be useful —
    /// no record, due, or overdue. Hidden when ok or already scheduled.
    private var shouldShowNotifyButton: Bool {
        // TEMP: forced on for testing — flip back to the status switch below when done.
        return true
        // switch task.status(events: events) {
        // case .noRecord, .due, .overdue: return true
        // case .ok, .scheduled: return false
        // }
    }

    private func sendText(to contact: NotifyContact) {
        let encoded = contact.messageTemplate.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "sms:\(contact.phone)&body=\(encoded)") else {
            Logger.shared.error("Failed to build sms: URL for \(contact.name)")
            return
        }
        Logger.shared.info("Opening Messages.app for \(contact.name) (\(task.id))")
        openURL(url)
    }

    private func statusInfo() -> (label: String, color: Color, detail: String) {
        switch task.status(events: events) {
        case .noRecord:
            return ("NO REC", .gray, "no record yet")
        case .ok(let daysUntilDue):
            return ("OK", .green, "due in \(daysUntilDue)d")
        case .due(let daysSince):
            return ("DUE", .orange, "\(daysSince)d since")
        case .overdue(let daysOverdue):
            return ("OVERDUE", .red, "\(daysOverdue)d overdue")
        case .scheduled(let date, let daysUntil):
            let when: String
            switch daysUntil {
            case 0: when = "today"
            case 1: when = "tomorrow"
            default: when = Self.dayFormatter.string(from: date)
            }
            return ("SCHEDULED", .blue, "for \(when)")
        }
    }

    private static func relative(from date: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let logDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: logDay, to: today).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case 2...6: return "\(days) days ago"
        default: return dayFormatter.string(from: date)
        }
    }
}

private struct DeliveriesCard: View {
    let deliveries: [Briefing.Delivery]

    var body: some View {
        let delivered = deliveries.filter { $0.state == "delivered" }
        let ordered = deliveries.filter { $0.state == "ordered" }

        return CardContainer(title: "Deliveries", systemImage: "shippingbox.fill") {
            VStack(alignment: .leading, spacing: 14) {
                if !delivered.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(text: "Delivered", color: .green)
                        ForEach(delivered) { d in DeliveryRow(delivery: d) }
                    }
                }
                if !ordered.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(text: "Ordered", color: .blue)
                        ForEach(ordered) { d in DeliveryRow(delivery: d) }
                    }
                }
            }
        }
    }
}

private struct SectionHeader: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

private struct DeliveryRow: View {
    let delivery: Briefing.Delivery

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(delivery.item)
                    .font(.callout.weight(.semibold))
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var detailLine: String {
        let orderedStr: String
        if let d = delivery.dateOrdered {
            orderedStr = "Ordered \(Self.dateFormatter.string(from: d))"
        } else {
            orderedStr = "Order date unknown"
        }
        if delivery.state == "delivered", let dd = delivery.dateDelivered {
            return "\(orderedStr) · Delivered \(Self.dateFormatter.string(from: dd))"
        }
        return orderedStr
    }

    private var icon: String {
        delivery.state == "delivered" ? "checkmark.circle.fill" : "shippingbox.fill"
    }

    private var iconColor: Color {
        delivery.state == "delivered" ? .green : .blue
    }
}

private struct StatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color)
            .clipShape(Capsule())
            .frame(width: 84, alignment: .center)
    }
}

// MARK: - Debug helpers

private struct DebugList<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                content()
            }
            .padding(.vertical, 2)
        }
    }
}

private struct DebugRow: View {
    let primary: String
    let secondary: String
    let trailing: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(.callout)
                    .lineLimit(1)
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(trailing)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Bottom rows (Gmail + API key)

private struct GmailRow: View {
    @Bindable var store: BriefingStore
    @State private var isWorking = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.gmailConnected ? "envelope.fill" : "envelope")
                .foregroundStyle(store.gmailConnected ? .green : .secondary)

            Text(store.gmailConnected ? "Gmail connected" : "Gmail not connected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if isWorking {
                ProgressView().controlSize(.small)
            }

            if store.gmailConnected {
                Button("Disconnect") {
                    Task {
                        isWorking = true
                        await store.disconnectGmail()
                        isWorking = false
                    }
                }
            } else {
                Button("Connect") {
                    Task {
                        isWorking = true
                        await store.connectGmail()
                        isWorking = false
                    }
                }
                .disabled(isWorking)
            }
        }
        .padding(10)
    }
}

private struct APIKeyRow: View {
    @Bindable var store: BriefingStore
    @State private var input = ""
    @State private var justSaved = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.hasAPIKey ? "key.fill" : "key")
                .foregroundStyle(store.hasAPIKey ? .green : .secondary)

            Text(store.hasAPIKey ? "API key set" : "No API key")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField(
                store.hasAPIKey ? "Enter a new key to replace" : "sk-ant-…",
                text: $input
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(save)

            Button(justSaved ? "Saved" : "Save") {
                save()
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    private func save() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.setAPIKey(trimmed)
        input = ""
        justSaved = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            justSaved = false
        }
    }
}
