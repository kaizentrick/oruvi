// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation

struct CodexUsageWindow: Decodable, Equatable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remainingPercent: Int { Int(max(0, min(100, 100 - usedPercent)).rounded(.down)) }
    var title: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "Límite" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) días" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes) min"
    }
    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }
    func isCurrent(at now: Date) -> Bool { resetDate.map { $0 > now } ?? true }
    var isValid: Bool {
        usedPercent.isFinite && usedPercent >= 0 &&
        (windowDurationMins.map { $0 > 0 } ?? true) &&
        (resetsAt.map { $0.isFinite && $0 > 0 } ?? true)
    }
}

struct CodexUsageBucket: Decodable, Equatable, Sendable, Identifiable {
    var limitId: String?
    let limitName: String?
    let primary: CodexUsageWindow?
    let secondary: CodexUsageWindow?
    var id: String { limitId ?? "codex" }
    var title: String { limitName?.isEmpty == false ? String(limitName!.prefix(80)) : (id == "codex" ? "Codex" : String(id.prefix(80))) }
    var windows: [CodexUsageWindow] { [primary, secondary].compactMap { $0 } }
    func limitingWindow(at now: Date) -> CodexUsageWindow? {
        windows.filter { $0.isCurrent(at: now) }.min { $0.remainingPercent < $1.remainingPercent }
    }
}

struct CodexUsageSnapshot: Equatable, Sendable {
    let fetchedAt: Date
    let buckets: [CodexUsageBucket]
    let ordinaryUsageAllowed: Bool?
    static let maximumAge: TimeInterval = 180
    func isFresh(at now: Date) -> Bool { (0...Self.maximumAge).contains(now.timeIntervalSince(fetchedAt)) }
    static func decode(_ data: Data, at now: Date = Date()) throws -> Self {
        struct Response: Decodable {
            let rateLimits: CodexUsageBucket?
            let rateLimitsByLimitId: [String: CodexUsageBucket?]?
            let ordinaryUsageAllowed: Bool?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let buckets: [CodexUsageBucket]
        if let map = response.rateLimitsByLimitId, !map.isEmpty {
            buckets = map.keys.sorted().compactMap { key in
                guard var value = map[key] ?? nil else { return nil }
                value.limitId = key; return value
            }
        } else { buckets = response.rateLimits.map { [$0] } ?? [] }
        guard buckets.count <= 64, buckets.allSatisfy({ $0.windows.allSatisfy(\.isValid) }) else {
            throw CodexUsageError.invalidResponse
        }
        return Self(fetchedAt: now, buckets: buckets, ordinaryUsageAllowed: response.ordinaryUsageAllowed)
    }
}

enum CodexUsageError: Error, Equatable {
    case missingCLI, timeout, unavailable, signInRequired, invalidResponse, cancelled
    var message: String {
        switch self {
        case .missingCLI: return "Instala Codex o su CLI en esta Mac e inicia sesión."
        case .timeout: return "Codex tardó en responder. Se reintentará automáticamente."
        case .signInRequired: return "Inicia sesión con ChatGPT en Codex y vuelve a conectar."
        case .invalidResponse: return "Esta versión de Codex no devolvió límites compatibles. Actualiza Codex."
        case .unavailable: return "No se pudo consultar el uso. Revisa la conexión y tu sesión en Codex."
        case .cancelled: return "Consulta detenida."
        }
    }
}

/// NDJSON framing is bounded before decoding, including a child that never
/// finishes a line. No output, account identifier or credentials are persisted.
struct CodexUsageFrames {
    static let maximumBytes = 1_048_576
    private var data = Data()
    private var received = 0
    mutating func append(_ bytes: Data) throws -> [Data] {
        received += bytes.count
        guard received <= Self.maximumBytes else { throw CodexUsageError.invalidResponse }
        data.append(bytes)
        var lines: [Data] = []
        while let end = data.firstIndex(of: 10) {
            let line = Data(data[..<end]); data.removeSubrange(...end)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
