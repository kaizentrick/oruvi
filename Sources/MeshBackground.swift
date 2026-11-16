import SwiftUI

extension RGB {
    static let aurora = [RGB(r: 0.055, g: 0.13, b: 0.25), RGB(r: 0.08, g: 0.38, b: 0.43), RGB(r: 0.30, g: 0.39, b: 0.72), RGB(r: 0.18, g: 0.16, b: 0.35)]
}
enum MeshTheme: String, CaseIterable, Identifiable {
    case aurora, dusk, midnight
    var id: String { rawValue }
    var name: String { self == .aurora ? "Aurora" : self == .dusk ? "Atardecer" : "Medianoche" }
    var palette: [RGB] {
        switch self {
        case .aurora: return RGB.aurora
        case .dusk: return RGB.dusk
        case .midnight: return [RGB(r: 0.06, g: 0.08, b: 0.15), RGB(r: 0.14, g: 0.19, b: 0.32), RGB(r: 0.22, g: 0.25, b: 0.40), RGB(r: 0.10, g: 0.13, b: 0.24)]
        }
    }
}

/// Explicit 12-component interpolation fixes instant palette jumps. Animation is scoped
/// to this GPU-backed mesh, and does not animate layout, glyphs, or the audio clock.
struct PaletteVector: VectorArithmetic {
    var values: [Double]
    init(_ palette: [RGB]) { values = (palette.count == 4 ? palette : RGB.aurora).flatMap { [$0.r, $0.g, $0.b] } }
    private init(values: [Double]) { self.values = values }
    static var zero: Self { Self(values: [Double](repeating: 0, count: 12)) }
    static func + (a: Self, b: Self) -> Self { Self(values: zip(a.values, b.values).map(+)) }
    static func - (a: Self, b: Self) -> Self { Self(values: zip(a.values, b.values).map(-)) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
    var colors: [Color] {
        stride(from: 0, to: 12, by: 3).map { i in
            Color(red: min(1, max(0, values[i])), green: min(1, max(0, values[i + 1])), blue: min(1, max(0, values[i + 2])))
        }
    }
}
struct SmoothMesh: View, Animatable {
    var vector: PaletteVector
    var framesPerSecond: Double
    var light: Bool
    var animatableData: PaletteVector { get { vector } set { vector = newValue } }
    init(palette: [RGB], framesPerSecond: Double, light: Bool) {
        vector = PaletteVector(palette); self.framesPerSecond = framesPerSecond; self.light = light
    }
    var body: some View {
        let colors = vector.colors
        let stops = [colors[0], colors[1], colors[0], colors[3], colors[2], colors[1], colors[0], colors[3], colors[0]]
        Group {
            if framesPerSecond > 0 {
                TimelineView(.animation(minimumInterval: 1 / framesPerSecond)) { _ in
                    let phase = ProcessInfo.processInfo.systemUptime * 0.085
                    let points = Self.points(leftY: Float(0.51 + 0.12 * sin(phase * 0.67)),
                                             center: [Float(0.5 + 0.16 * sin(phase * 0.81)), Float(0.52 + 0.15 * cos(phase * 0.59))],
                                             rightY: Float(0.50 + 0.13 * sin(phase * 0.79)))
                    MeshGradient(width: 3, height: 3, points: points, colors: stops)
                }
            } else {
                MeshGradient(width: 3, height: 3, points: Self.staticPoints, colors: stops)
            }
        }
        .overlay(light ? Color.white.opacity(0.74) : Color.black.opacity(0.38))
        .overlay(LinearGradient(colors: [.clear, .black.opacity(light ? 0.015 : 0.25)], startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea().accessibilityHidden(true).allowsHitTesting(false)
    }

    private static let staticPoints = points(leftY: 0.51, center: [0.5, 0.52], rightY: 0.50)

    private static func points(leftY: Float, center: SIMD2<Float>, rightY: Float) -> [SIMD2<Float>] {
        [[0, 0], [0.5, 0], [1, 0], [0, leftY], center, [1, rightY], [0, 1], [0.5, 1], [1, 1]]
    }
}
