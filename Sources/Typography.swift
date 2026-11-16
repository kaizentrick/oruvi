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

    private static let namedFaces: [Self: [ClockWeight: String]] = Dictionary(uniqueKeysWithValues: allCases.compactMap { typeface in
        guard let name = typeface.postScriptName, let base = NSFont(name: name, size: 14),
              let family = base.familyName else { return nil }
        var faces: [ClockWeight: String] = [.regular: name]
        for member in NSFontManager.shared.availableMembers(ofFontFamily: family) ?? [] {
            guard member.count >= 4, let faceName = member[0] as? String, let rawTraits = member[3] as? UInt,
                  NSFontTraitMask(rawValue: rawTraits).intersection([.italicFontMask, .condensedFontMask, .expandedFontMask]).isEmpty,
                  let font = NSFont(name: faceName, size: 14),
                  let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
                  let weight = traits[.weight] as? NSNumber else { continue }
            let closest = ClockWeight.closest(to: weight.doubleValue, among: ClockWeight.allCases)
            if faces[closest] == nil { faces[closest] = faceName }
        }
        return (typeface, faces)
    })

    var clockWeights: [ClockWeight] {
        guard postScriptName != nil, let faces = Self.namedFaces[self] else { return ClockWeight.allCases }
        return ClockWeight.allCases.filter { faces[$0] != nil }
    }

    func displayedClockWeight(_ requested: ClockWeight) -> ClockWeight {
        ClockWeight.closest(to: Double(requested.native.rawValue), among: clockWeights)
    }

    func native(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if postScriptName != nil, let faces = Self.namedFaces[self],
           let name = faces[ClockWeight.closest(to: Double(weight.rawValue), among: clockWeights)],
           let font = NSFont(name: name, size: size) {
            return font
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
    static func closest(to desired: Double, among choices: [Self]) -> Self {
        choices.min { abs(Double($0.native.rawValue) - desired) < abs(Double($1.native.rawValue) - desired) } ?? .regular
    }
}

enum LyricTypography {
    static let sizeRange = 75.0...135.0
    static let defaultSize = 100.0

    static func font(_ typeface: AmbientTypeface, baseSize: CGFloat, sizePercent: Double, emphasized: Bool = false) -> Font {
        typeface.font(size: baseSize * sizePercent / 100, emphasized: emphasized)
    }
}

/// The active line gets first use of the height when lyrics replace artwork.
struct LyricsStageMetrics {
    let spacing: CGFloat
    let previous: CGFloat
    let active: CGFloat
    let next: CGFloat
    let loading: CGFloat
    var activeLineLimit: Int { active < 64 ? 2 : 4 }

    init(compact: Bool, heightBudget: CGFloat? = nil) {
        let budget = max(0, heightBudget ?? .infinity)
        spacing = compact ? 12 : 19
        let preferredActive: CGFloat = compact ? 100 : 144
        let preferredNext: CGFloat = compact ? 50 : 55
        let twoLines = preferredActive + spacing + preferredNext
        previous = !compact && budget >= twoLines + spacing + 45 ? 45 : 0
        next = budget >= twoLines ? preferredNext : 0
        active = min(budget, preferredActive)
        loading = min(budget, compact ? 180 : 230)
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

struct EditorialLayoutMetrics {
    let width: CGFloat
    let clockWidth: CGFloat
    let musicWidth: CGFloat
    let gap: CGFloat

    init(windowWidth: CGFloat, inset: CGFloat) {
        let fullWidth = windowWidth.isFinite ? max(0, windowWidth) : 0
        let margin = inset.isFinite ? max(0, inset) : 0
        width = min(1240, max(0, fullWidth - margin * 2))
        gap = min(70, fullWidth * 0.05, width * 0.1)
        clockWidth = width * 0.43
        musicWidth = width - clockWidth - gap
    }
}
