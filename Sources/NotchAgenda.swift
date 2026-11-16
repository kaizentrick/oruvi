import AppKit
import SwiftUI
import EventKit
import Observation

struct NotchCalendarEvent: Identifiable, Sendable {
    let id: String
    let title: String
    let calendar: String
    let start: Date
    let end: Date
    let allDay: Bool
    let meetingURL: URL?
}

/// EKEvent/EKCalendar instances stay on this actor. Each query covers at most
/// 31 days and runs off the UI thread.
private actor NotchCalendarReader {
    private let store = EKEventStore()
    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }
    func read(now: Date, dates: NotchAgendaDates) -> (upcoming: [NotchCalendarEvent], month: [NotchCalendarEvent]) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return ([], []) }
        let upcoming = events(in: dates.upcoming, after: now)
        let month = dates.needsSeparateMonthQuery ? events(in: dates.month, after: now) : upcoming.filter {
            NotchAgendaDates.overlaps(start: $0.startDate, end: $0.endDate, range: dates.month)
        }
        return (upcoming.prefix(6).map(eventSummary), month.map(eventSummary))
    }
    private func events(in range: DateInterval, after now: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        return store.events(matching: predicate).filter { $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
    }
    private func eventSummary(_ event: EKEvent) -> NotchCalendarEvent {
        NotchCalendarEvent(id: (event.eventIdentifier ?? "event") + "-" + String(event.startDate.timeIntervalSince1970),
                           title: event.title?.isEmpty == false ? event.title! : "Sin título",
                           calendar: event.calendar?.title ?? "Calendario", start: event.startDate,
                           end: event.endDate, allDay: event.isAllDay,
                           meetingURL: NotchMeetingDetector.extractURL(url: event.url, location: event.location, notes: event.notes))
    }
}

@MainActor @Observable
final class NotchAgenda {
    private(set) var enabled = LumaEnvironment.preferences.bool(forKey: "notchAgendaEnabled")
    private(set) var events: [NotchCalendarEvent] = []
    private(set) var monthEvents: [NotchCalendarEvent] = []
    private(set) var monthOffset = 0
    private(set) var today = Calendar.current.startOfDay(for: Date())
    private(set) var requesting = false
    private(set) var loading = false
    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    var message = ""
    @ObservationIgnored private let reader = NotchCalendarReader()
    @ObservationIgnored private var active = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func setActive(_ value: Bool) {
        active = value
        task?.cancel(); generation += 1; loading = false
        refreshTimer?.invalidate(); refreshTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard value else { events.removeAll(); monthEvents.removeAll(); monthOffset = 0; return }
        access = EKEventStore.authorizationStatus(for: .event)
        guard enabled else { events.removeAll(); monthEvents.removeAll(); return }
        for name in [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged, .NSSystemClockDidChange,
                     .NSSystemTimeZoneDidChange, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 5; refreshTimer = timer; RunLoop.main.add(timer, forMode: .common)
        refresh()
    }
    func showMonth(_ offset: Int) {
        guard monthOffset != offset, offset >= 0 else { return }
        monthOffset = offset; monthEvents.removeAll()
        refresh()
    }
    func connect(controller: NotchController) {
        guard !requesting else { return }
        requesting = true; message = ""; controller.beginInteraction()
        Task { [weak self, weak controller] in
            guard let self else { controller?.endInteraction(); return }
            defer { self.requesting = false; controller?.endInteraction() }
            do {
                let granted = try await self.reader.requestAccess()
                self.enabled = granted
                LumaEnvironment.preferences.set(granted, forKey: "notchAgendaEnabled")
                self.access = EKEventStore.authorizationStatus(for: .event)
                if !granted { self.message = "Activa Calendarios en Ajustes del Sistema → Privacidad y seguridad." }
                self.setActive(self.active)
            } catch {
                self.access = EKEventStore.authorizationStatus(for: .event)
                self.message = "No se pudo conectar Calendario. Revisa el permiso en Ajustes del Sistema."
            }
        }
    }
    func disconnect() {
        enabled = false; LumaEnvironment.preferences.set(false, forKey: "notchAgendaEnabled")
        events.removeAll(); message = ""; setActive(active)
    }
    func refresh() {
        guard active, enabled else { return }
        access = EKEventStore.authorizationStatus(for: .event)
        task?.cancel(); task = nil; generation += 1
        guard access == .fullAccess else {
            events.removeAll(); monthEvents.removeAll(); loading = false; return
        }
        let calendar = Calendar.current, now = Date()
        today = calendar.startOfDay(for: now)
        guard let dates = NotchAgendaDates(now: now, monthOffset: monthOffset, calendar: calendar) else {
            events.removeAll(); monthEvents.removeAll(); loading = false; return
        }
        let serial = generation
        loading = true
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self else { return }
            let result = await self.reader.read(now: now, dates: dates)
            guard !Task.isCancelled, self.active, self.enabled, self.generation == serial else { return }
            self.access = EKEventStore.authorizationStatus(for: .event)
            self.events = self.access == .fullAccess ? result.upcoming : []
            self.monthEvents = self.access == .fullAccess ? result.month : []
            self.loading = false; self.task = nil
        }
    }
    func stop() { setActive(false) }
    func openMeeting(_ url: URL) {
        guard NotchMeetingDetector.isAllowedMeetingURL(url) else { return }
        NSWorkspace.shared.open(url)
    }
    func openApp(_ bundle: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            message = "La aplicación no está disponible en este Mac."; return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct NotchAgendaView: View {
    let agenda: NotchAgenda
    let controller: NotchController
    @State private var selectedDay: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !agenda.enabled || agenda.access != .fullAccess {
                VStack(spacing: 8) {
                    Image(systemName: "calendar").font(.system(size: 25, weight: .light))
                    Text("Tus próximos eventos").font(.system(size: 13, weight: .semibold))
                    Text("macOS solicita acceso completo. Oruvi solo lee los próximos eventos; no modifica calendarios.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if agenda.access == .denied || agenda.access == .restricted {
                        Button("Abrir Ajustes del Sistema") { agenda.openApp("com.apple.systempreferences") }
                            .buttonStyle(.bordered).controlSize(.small)
                        Text("Privacidad y seguridad → Calendarios").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Button(agenda.requesting ? "Conectando…" : "Conectar Calendario") { agenda.connect(controller: controller) }
                            .buttonStyle(.bordered).controlSize(.small).disabled(agenda.requesting)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    NotchMonthCalendar(events: agenda.monthEvents, today: agenda.today,
                                       monthOffset: Binding(get: { agenda.monthOffset }, set: { agenda.showMonth($0) }),
                                       selectedDay: $selectedDay)
                        .frame(width: 146)
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1).padding(.vertical, 2)
                    eventsColumn.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Button("Abrir Calendario") { agenda.openApp("com.apple.iCal"); controller.collapse() }
                    Spacer()
                    if selectedDay != nil {
                        Button("Ver todos") { selectedDay = nil }.foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.secondary)
                    }
                    Button("Desconectar") { agenda.disconnect() }.foregroundStyle(.secondary)
                }.buttonStyle(.plain).font(.system(size: 10))
            }
            if !agenda.message.isEmpty {
                Text(agenda.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .onChange(of: agenda.today) { oldDay, newDay in
            if let selectedDay, selectedDay < newDay || !Calendar.current.isDate(oldDay, equalTo: newDay, toGranularity: .month) {
                self.selectedDay = nil
            }
        }
    }
    private var visibleEvents: [NotchCalendarEvent] {
        guard let selectedDay else { return agenda.events }
        let cal = Calendar.current
        guard let range = cal.dateInterval(of: .day, for: selectedDay), range.start >= agenda.today else { return [] }
        return agenda.monthEvents.filter { NotchAgendaDates.overlaps(start: $0.start, end: $0.end, range: range) }
    }
    @ViewBuilder private var eventsColumn: some View {
        let items = visibleEvents
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(selectedDay.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? "Próximos eventos")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            if agenda.loading && items.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedDay == nil ? agenda.today.formatted(.dateTime.weekday(.wide).day().month(.wide)) : "Sin eventos por delante")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    Text(selectedDay == nil ? "Sin eventos próximos en tu calendario." : "No quedan eventos programados para este día.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(items) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(event.start, format: .dateTime.day().month(.abbreviated))
                                    Text("·")
                                    if event.allDay { Text("Todo el día") }
                                    else { Text(event.start, style: .time) }
                                    Spacer(minLength: 2)
                                    if let meetingURL = event.meetingURL {
                                        Button {
                                            agenda.openMeeting(meetingURL)
                                            controller.collapse()
                                        } label: {
                                            Label("Unirse", systemImage: "video.fill").font(.system(size: 9, weight: .medium))
                                        }
                                        .buttonStyle(.borderedProminent).tint(.white.opacity(0.18)).controlSize(.mini)
                                        .help("Abrir enlace de videollamada")
                                    }
                                }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                                Text(event.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(event.calendar).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            }.accessibilityElement(children: .contain)
                        }
                    }
                }
            }
        }
    }
}

private struct NotchMonthCalendar: View {
    let events: [NotchCalendarEvent]
    let today: Date
    @Binding var monthOffset: Int
    @Binding var selectedDay: Date?
    private var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Lunes
        return cal
    }
    private let weekdays = ["L", "M", "M", "J", "V", "S", "D"]
    private var displayedMonth: Date {
        let start = calendar.dateInterval(of: .month, for: today)?.start ?? today
        return calendar.date(byAdding: .month, value: monthOffset, to: start) ?? today
    }
    private var monthTitle: String {
        displayedMonth.formatted(.dateTime.month(.wide).year()).capitalized
    }
    private var daysGrid: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) else { return [] }
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leadingEmpty = (weekday - calendar.firstWeekday + 7) % 7
        var result: [Date?] = Array(repeating: nil, count: leadingEmpty)
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                result.append(date)
            }
        }
        return result
    }
    private func hasEvents(on date: Date) -> Bool {
        guard let range = calendar.dateInterval(of: .day, for: date) else { return false }
        return events.contains { NotchAgendaDates.overlaps(start: $0.start, end: $0.end, range: range) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Button {
                    monthOffset = 0; selectedDay = nil
                } label: {
                    Text(monthTitle).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                }.buttonStyle(.plain).help("Volver al mes actual")
                Spacer(minLength: 2)
                Button { monthOffset -= 1; selectedDay = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .medium)).frame(width: 16, height: 16)
                }.buttonStyle(.plain).help("Mes anterior").disabled(monthOffset == 0)
                Button { monthOffset += 1; selectedDay = nil } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).frame(width: 16, height: 16)
                }.buttonStyle(.plain).help("Mes siguiente")
            }
            HStack(spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(maxWidth: .infinity)
                }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(daysGrid.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let isToday = calendar.isDate(date, inSameDayAs: today)
                        let isPast = date < today
                        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: date) } ?? false
                        let marked = hasEvents(on: date)
                        Button {
                            if isSelected { selectedDay = nil } else { selectedDay = date }
                        } label: {
                            VStack(spacing: 1) {
                                Text("\(calendar.component(.day, from: date))")
                                    .font(.system(size: 9, weight: isToday || isSelected ? .bold : .regular))
                                    .foregroundStyle(isToday ? .black : .white.opacity(isSelected ? 1 : 0.86))
                                Circle()
                                    .fill(isToday ? Color.black.opacity(0.75) : Color.white.opacity(marked ? 0.75 : 0))
                                    .frame(width: 3, height: 3)
                            }
                            .frame(width: 19, height: 18)
                            .background {
                                if isToday {
                                    RoundedRectangle(cornerRadius: 5).fill(.white)
                                } else if isSelected {
                                    RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.65), lineWidth: 1)
                                }
                            }
                        }.buttonStyle(.plain)
                            .disabled(isPast).opacity(isPast ? 0.42 : 1)
                            .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .accessibilityValue(marked ? "Con eventos" : "")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                    } else {
                        Color.clear.frame(width: 19, height: 18)
                    }
                }
            }
        }
    }
}
