import AppKit
import SwiftUI

/// Uses Apple's system font APIs; never bundles, extracts or downloads Apple font files.
/// Existing raw values are preserved so a 0.5 preference continues to resolve correctly.
enum AmbientTypeface: String, CaseIterable, Identifiable {
    case editorial, modern, rounded, monospaced, condensed, expanded
    case didot, bodoni, avenir, baskerville, georgia, helvetica
    var id: String { rawValue }
    var isAppleSystem: Bool { [.editorial, .modern, .rounded, .monospaced, .condensed, .expanded].contains(self) }
    var name: String {
        switch self {
        case .editorial: return "New York · serif"
        case .modern: return "SF Pro"
        case .rounded: return "SF Pro Rounded"
        case .monospaced: return "SF Mono"
        case .condensed: return "SF Pro · condensada"
        case .expanded: return "SF Pro · expandida"
        case .didot: return "Didot"
        case .bodoni: return "Bodoni 72"
        case .avenir: return "Avenir Next"
        case .baskerville: return "Baskerville"
        case .georgia: return "Georgia"
        case .helvetica: return "Helvetica Neue"
        }
    }
    private var postScriptName: String? {
        switch self {
        case .didot: return "Didot"
        case .bodoni: return "BodoniSvtyTwoITCTT-Book"
        case .avenir: return "AvenirNext-Regular"
        case .baskerville: return "Baskerville"
        case .georgia: return "Georgia"
        case .helvetica: return "HelveticaNeue"
        default: return nil
        }
    }
    var installed: Bool { postScriptName.map { NSFont(name: $0, size: 14) != nil } ?? true }
    func native(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let postScriptName, let font = NSFont(name: postScriptName, size: size) {
            return weight.rawValue >= NSFont.Weight.semibold.rawValue ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
        }
        let design: NSFontDescriptor.SystemDesign
        switch self { case .editorial: design = .serif; case .rounded: design = .rounded; case .monospaced: design = .monospaced; default: design = .default }
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        var descriptor = system.fontDescriptor.withDesign(design) ?? system.fontDescriptor
        if self == .condensed { descriptor = descriptor.withSymbolicTraits(.condensed) }
        if self == .expanded { descriptor = descriptor.withSymbolicTraits(.expanded) }
        return NSFont(descriptor: descriptor, size: size) ?? system
    }
    func font(size: CGFloat, emphasized: Bool = false) -> Font {
        Font(native(size: size, weight: emphasized ? .semibold : .regular))
    }
}

enum ClockWeight: String, CaseIterable, Identifiable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    var id: String { rawValue }
    var name: String {
        switch self {
        case .ultraLight: return "Ultraligera"
        case .thin: return "Fina"
        case .light: return "Ligera"
        case .regular: return "Regular"
        case .medium: return "Media"
        case .semibold: return "Seminegrita"
        case .bold: return "Negrita"
        case .heavy: return "Gruesa"
        case .black: return "Muy gruesa"
        }
    }
    var native: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

/// Geometry is independent of the lyrics switch. Only positions and opacities animate.
/// No text, cover or control is resized halfway through opening the lyric pane.
struct MusicLayoutMetrics {
    let split: Bool
    let supportsSidebar: Bool
    let compact: Bool
    let cover: CGFloat
    let playerWidth: CGFloat
    let lyricsWidth: CGFloat
    let gap: CGFloat
    let spacing: CGFloat
    var playerShift: CGFloat { -(lyricsWidth + gap) / 2 }
    var lyricsShift: CGFloat { (playerWidth + gap) / 2 }
    init(size: CGSize, lyrics: Bool) {
        let width = size.width.isFinite ? max(0, size.width) : 0
        let height = size.height.isFinite ? max(0, size.height) : 0
        compact = height < 650
        supportsSidebar = width >= 940 && height >= 420
        split = lyrics && supportsSidebar
        spacing = compact ? 14 : 22
        let budget: CGFloat = compact ? 188 : 218
        let maximum = max(0, supportsSidebar ? min(560, width * 0.45) : min(560, width - 24))
        cover = max(0, min(maximum, height - budget))
        playerWidth = min(maximum, max(260, cover))
        gap = supportsSidebar ? min(72, width * 0.05) : 0
        lyricsWidth = supportsSidebar ? max(0, min(490, width - playerWidth - gap)) : playerWidth
    }
}
