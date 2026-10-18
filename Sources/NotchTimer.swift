import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class NotchCountdown {
    private(set) var state = NotchTimerState()
    var sound = LumaEnvironment.preferences.bool(forKey: "notchTimerSound") {
        didSet { LumaEnvironment.preferences.set(sound, forKey: "notchTimerSound") }
    }
    @ObservationIgnored private var task: Task<Void, Never>?
    func configure(minutes: Int) { task?.cancel(); task = nil; state.configure(seconds: minutes * 60) }
    func adjust(minutesDelta: Int) {
        guard !state.running else { return }
        task?.cancel(); task = nil; state.adjust(secondsDelta: minutesDelta * 60)
    }
    func toggle() {
        task?.cancel(); task = nil
        if state.running { state.pause(); return }
        state.start()
        guard let deadline = state.deadline else { return }
        // One deadline, not a repeating background timer. The one-second visual
        // updates belong exclusively to the expanded SwiftUI timer view.
        task = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled, let self, self.state.deadline == deadline else { return }
            self.state.finish(); self.task = nil
            if self.sound { NSSound.beep() }
        }
    }
    func reset() { task?.cancel(); task = nil; state.reset() }
    func stop() { reset() }
    var text: String {
        let value = state.seconds()
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

struct NotchTimerView: View {
    let countdown: NotchCountdown
    var body: some View {
        VStack(spacing: 10) {
            if countdown.state.running {
                TimelineView(.periodic(from: .now, by: 1)) { _ in readout }
            } else { readout }
            HStack(spacing: 6) {
                Button("−1m") { countdown.adjust(minutesDelta: -1) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(countdown.state.running || countdown.state.seconds() <= 60)
                    .accessibilityLabel("Restar un minuto")
                ForEach([5, 10, 15, 25, 45], id: \.self) { minutes in
                    Button("\(minutes)m") { countdown.configure(minutes: minutes) }
                        .buttonStyle(.bordered).controlSize(.small).disabled(countdown.state.running)
                        .accessibilityLabel("\(minutes) minutos")
                }
                Button("+1m") { countdown.adjust(minutesDelta: 1) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(countdown.state.running || countdown.state.seconds() >= 10800)
                    .accessibilityLabel("Sumar un minuto")
            }
            HStack(spacing: 14) {
                Button(countdown.state.running ? "Pausar" : (countdown.state.completed ? "Repetir" : "Iniciar")) { countdown.toggle() }
                    .buttonStyle(.borderedProminent).tint(.white.opacity(0.18)).controlSize(.small)
                Button("Reiniciar") { countdown.reset() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Toggle("Sonido", isOn: Binding(get: { countdown.sound }, set: { countdown.sound = $0 }))
                    .toggleStyle(.checkbox).help("Emitir un sonido al terminar; se guarda tu preferencia")
            }.font(.system(size: 11))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var readout: some View {
        VStack(spacing: 2) {
            Text(countdown.text).font(.system(size: 38, weight: .light, design: .rounded)).monospacedDigit()
                .accessibilityLabel("Tiempo restante: \(countdown.text)")
            Text(countdown.state.completed ? "Tiempo cumplido" : (countdown.state.running ? "En curso" : "Tu siguiente pausa"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
