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
}

/// EKEvent/EKCalendar instances never cross the actor boundary. Database work is
/// bounded to seven days and runs away from the UI actor, without network services.
private actor NotchCalendarReader {
    private let store = EKEventStore()
    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }
    func upcoming(now: Date) -> [NotchCalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? now.addingTimeInterval(604800)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6).map { event in
                NotchCalendarEvent(id: (event.eventIdentifier ?? "event") + "-" + String(event.startDate.timeIntervalSince1970),
                                   title: event.title?.isEmpty == false ? event.title! : "Sin título",
                                   calendar: event.calendar?.title ?? "Calendario", start: event.startDate,
                                   end: event.endDate, allDay: event.isAllDay)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                if agenda.loading && agenda.events.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if agenda.events.isEmpty {
                    Text("Sin eventos en los próximos 7 días.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(agenda.events) { event in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(event.start, format: .dateTime.day().month(.abbreviated))
                                        if event.allDay { Text("Todo el día") }
                                        else { Text(event.start, style: .time) }
                                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                        Text(event.calendar).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                HStack {
                    Button("Abrir Calendario") { agenda.openApp("com.apple.iCal"); controller.collapse() }
                    Spacer()
                    Button("Desconectar") { agenda.disconnect() }.foregroundStyle(.secondary)
                }.buttonStyle(.plain).font(.system(size: 11))
            }
            if !agenda.message.isEmpty {
                Text(agenda.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
