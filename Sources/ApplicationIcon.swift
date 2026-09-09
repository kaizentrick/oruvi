import AppKit

/// Load the signed bundle resource directly instead of resolving a cached workspace icon.
/// Reading this resource never modifies the installed bundle or system icon caches.
enum ApplicationIcon {
    static func image(in bundle: Bundle = .main) -> NSImage? {
        guard let filename = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              filename == "OruviIcon.icns",
              let url = bundle.resourceURL?.appendingPathComponent(filename),
              let image = NSImage(contentsOf: url), image.isValid else { return nil }
        image.isTemplate = false
        return image
    }
}
