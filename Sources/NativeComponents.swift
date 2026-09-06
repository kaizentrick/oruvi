import AppKit
import SwiftUI
import CoreText

struct ClockDrawingLayout {
    let line: CTLine
    let scale: CGFloat
    let origin: CGPoint
    let inkBounds: CGRect
}

enum ClockGeometry {
    /// Fits the actual glyph outlines plus typographic bounds, including serif overhangs.
    /// Negative tracking and text truncation are deliberately not used.
    static func layout(text: String, maximumSize: CGFloat, bounds: CGRect, centered: Bool, color: NSColor, typeface: AmbientTypeface = .editorial, weight: ClockWeight = .ultraLight) -> ClockDrawingLayout {
        let font = typeface.native(size: maximumSize, weight: weight.native)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let metric = ink.union(CGRect(x: 0, y: -descent, width: CGFloat(advance), height: ascent + descent))
        let padding = min(28, max(12, bounds.width * 0.035))
        let available = bounds.insetBy(dx: padding, dy: 10)
        let scale = max(0.01, min(1, min(available.width / max(1, metric.width), available.height / max(1, metric.height))))
        let left = centered ? available.midX - metric.width * scale / 2 : available.minX
        let origin = CGPoint(x: left - metric.minX * scale, y: available.midY - metric.midY * scale)
        let actual = CGRect(x: origin.x + ink.minX * scale, y: origin.y + ink.minY * scale, width: ink.width * scale, height: ink.height * scale)
        return ClockDrawingLayout(line: line, scale: scale, origin: origin, inkBounds: actual)
    }
}

struct EditorialTime: NSViewRepresentable {
    let text: String
    let maximumSize: CGFloat
    let centered: Bool
    var typeface: AmbientTypeface = .editorial
    var weight: ClockWeight = .ultraLight
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> ClockGlyphView {
        let view = ClockGlyphView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        return view
    }
    func updateNSView(_ view: ClockGlyphView, context: Context) {
        let color = scheme == .dark ? NSColor.white.withAlphaComponent(0.93) : NSColor.black.withAlphaComponent(0.85)
        if view.text != text || view.maximumSize != maximumSize || view.centered != centered || view.color != color || view.typeface != typeface || view.weight != weight {
            view.text = text; view.maximumSize = maximumSize; view.centered = centered; view.color = color; view.typeface = typeface; view.weight = weight
            view.setAccessibilityValue("Hora: " + text); view.needsDisplay = true
        }
    }
}
final class ClockGlyphView: NSView {
    var text = "00:00"
    var maximumSize: CGFloat = 260
    var centered = true
    var color = NSColor.white
    var typeface: AmbientTypeface = .editorial
    var weight: ClockWeight = .ultraLight
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let layout = ClockGeometry.layout(text: text, maximumSize: maximumSize, bounds: bounds, centered: centered, color: color, typeface: typeface, weight: weight)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: layout.origin.x, y: layout.origin.y)
        context.scaleBy(x: layout.scale, y: layout.scale)
        context.textPosition = .zero
        CTLineDraw(layout.line, context)
        context.restoreGState()
    }
}

// Borderless native buttons accept the FIRST click without inheriting a square system bezel.
// All toolbar surfaces are then rendered with one shared SwiftUI Liquid Glass shape.
struct PlainIconControl: NSViewRepresentable {
    let symbol: String
    let label: String
    var identifier = ""
    var selected = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> FirstClickIconButton {
        let button = FirstClickIconButton()
        button.isBordered = false; button.title = ""; button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.target = context.coordinator; button.action = #selector(Coordinator.pressed(_:))
        return button
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FirstClickIconButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 36, height: proposal.height ?? 36)
    }
    func updateNSView(_ button: FirstClickIconButton, context: Context) {
        context.coordinator.action = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: selected ? .semibold : .regular))
        button.contentTintColor = (scheme == .dark ? NSColor.white : .black).withAlphaComponent(selected ? 1 : 0.78)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(selected ? "Seleccionado" : "")
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func pressed(_ sender: NSButton) { action() }
    }
}
final class FirstClickIconButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
struct LayoutSelector: View {
    let model: StandbyModel
    var body: some View {
        HStack(spacing: 2) {
            ForEach(LayoutMode.allCases) { mode in
                PlainIconControl(symbol: mode.symbol, label: mode.displayName, identifier: "display." + mode.rawValue, selected: model.layout == mode) {
                    model.selectLayout(mode)
                }
                .frame(width: 34, height: 34)
                .background(model.layout == mode ? Color.primary.opacity(0.14) : .clear, in: Capsule())
            }
        }
    }
}
struct GlassIconButton: View {
    let model: StandbyModel
    let symbol: String
    let label: String
    var identifier = ""
    let action: () -> Void
    var body: some View {
        PlainIconControl(symbol: symbol, label: label, identifier: identifier, action: action)
            .frame(width: 34, height: 34).padding(3)
            .lumaGlass(model: model, radius: 22)
    }
}
