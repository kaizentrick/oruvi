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

/// EKEvent/EKCalendar instances never cross the actor boundary. Database work is
/// bounded to 31 days and runs away from the UI actor, without network services.
private actor NotchCalendarReader {
    private let store = EKEventStore()
    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }
    func upcoming(now: Date) -> [NotchCalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 31, to: start) ?? now.addingTimeInterval(2678400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(24).map { event in
                NotchCalendarEvent(id: (event.eventIdentifier ?? "event") + "-" + String(event.startDate.timeIntervalSince1970),
                                   title: event.title?.isEmpty == false ? event.title! : "Sin título",
                                   calendar: event.calendar?.title ?? "Calendario", start: event.startDate,
                                   end: event.endDate, allDay: event.isAllDay,
                                   meetingURL: NotchMeetingDetector.extractURL(url: event.url, location: event.location, notes: event.notes))
            }
    }
}

@MainActor @Observable
final class NotchAgenda {
    private(set) var enabled = LumaEnvironment.preferences.bool(forKey: "notchAgendaEnabled")
    private(set) var events: [NotchCalendarEvent] = []
    private(set) var requesting = false
    private(set) var loading = false
    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    var message = ""
    @ObservationIgnored private let reader = NotchCalendarReader()
    @ObservationIgnored private var active = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    func setActive(_ value: Bool) {
        active = value
        task?.cancel(); generation += 1; loading = false
        refreshTimer?.invalidate(); refreshTimer = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        guard value else { events.removeAll(); return }
        access = EKEventStore.authorizationStatus(for: .event)
        guard enabled, access == .fullAccess else { events.removeAll(); return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 5; refreshTimer = timer; RunLoop.main.add(timer, forMode: .common)
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
        guard access == .fullAccess else { events.removeAll(); setActive(active); return }
        task?.cancel(); generation += 1
        let serial = generation
        loading = true
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self else { return }
            let result = await self.reader.upcoming(now: Date())
            guard !Task.isCancelled, self.active, self.enabled, self.generation == serial else { return }
            self.events = result; self.loading = false; self.task = nil
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
    @State private var monthOffset = 0
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
                    NotchMonthCalendar(events: agenda.events, monthOffset: $monthOffset, selectedDay: $selectedDay)
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
    }
    private var visibleEvents: [NotchCalendarEvent] {
        guard let selectedDay else { return Array(agenda.events.prefix(6)) }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedDay)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        return agenda.events.filter { $0.start < dayEnd && $0.end > dayStart }
    }
    @ViewBuilder private var eventsColumn: some View {
        let items = visibleEvents
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(selectedDay.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? "Próximos eventos")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            if agenda.loading && agenda.events.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedDay == nil ? Date().formatted(.dateTime.weekday(.wide).day().month(.wide)) : "Día libre")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    Text(selectedDay == nil ? "Sin eventos próximos en tu calendario." : "No hay eventos programados para este día.")
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
    @Binding var monthOffset: Int
    @Binding var selectedDay: Date?
    private let calendar: Calendar = {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Lunes
        return cal
    }()
    private let weekdays = ["L", "M", "M", "J", "V", "S", "D"]
    private var displayedMonth: Date {
        let now = Date()
        let comps = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: comps) ?? now
        return calendar.date(byAdding: .month, value: monthOffset, to: start) ?? now
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
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        return events.contains { $0.start < dayEnd && $0.end > dayStart }
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
                Button { monthOffset -= 1 } label: {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .medium)).frame(width: 16, height: 16)
                }.buttonStyle(.plain).help("Mes anterior")
                Button { monthOffset += 1 } label: {
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
                        let isToday = calendar.isDateInToday(date)
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
                    } else {
                        Color.clear.frame(width: 19, height: 18)
                    }
                }
            }
        }
    }
}
