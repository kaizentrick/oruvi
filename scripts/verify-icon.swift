import AppKit
import Foundation
import ImageIO

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("ICON DECODE FAILED: " + message + "\n").utf8))
        exit(1)
    }
}

func decode(_ url: URL, pixels: Int) -> [UInt8] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetStatus(source) == .statusComplete,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        require(false, "Cannot completely decode " + url.lastPathComponent)
        return []
    }
    require(image.width == pixels && image.height == pixels, "Wrong dimensions: " + url.lastPathComponent)
    var rgba = [UInt8](repeating: 0, count: pixels * pixels * 4)
    let rendered = rgba.withUnsafeMutableBytes { storage -> Bool in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: storage.baseAddress, width: pixels, height: pixels,
                                      bitsPerComponent: 8, bytesPerRow: pixels * 4, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return true
    }
    require(rendered, "Cannot render decoded bitmap")
    for (x, y) in [(0, 0), (pixels - 1, 0), (0, pixels - 1), (pixels - 1, pixels - 1)] {
        require(rgba[(y * pixels + x) * 4 + 3] == 0, "Background corner is not transparent: " + url.lastPathComponent)
    }
    let middle = ((pixels / 2) * pixels + pixels / 2) * 4
    require(rgba[middle + 3] >= 250, "The icon interior must be opaque")
    require(Int(rgba[middle]) + Int(rgba[middle + 1]) + Int(rgba[middle + 2]) > 120, "Missing frosted-window artwork")
    return rgba
}

@main
enum VerifyApplicationIcon {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        require(arguments.count == 4 || arguments.count == 5, "Usage: verify-icon MASTER.png ICON.icns ICONSET [APP]")
        let masterURL = URL(fileURLWithPath: arguments[1])
        let iconURL = URL(fileURLWithPath: arguments[2])
        let iconset = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let master = decode(masterURL, pixels: 1024)
        require(NSImage(contentsOf: iconURL)?.isValid == true, "AppKit cannot load the ICNS")
        var verified = 0
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let url = iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                let rendered = decode(url, pixels: size * scale)
                if size * scale == 1024 {
                    require(rendered == master, "The largest ICNS representation is not the approved PNG")
                }
                verified += 1
            }
        }
        if arguments.count == 5 {
            guard let bundle = Bundle(url: URL(fileURLWithPath: arguments[4], isDirectory: true)) else {
                require(false, "Cannot open the installed application bundle")
                exit(1)
            }
            require(ApplicationIcon.image(in: bundle)?.isValid == true, "The application runtime cannot resolve its packaged icon")
            print("Packaged runtime icon loader: verified directly from bundle resources.")
        }
        print("Native icon decoding passed: \(verified) PNG representations, 16–1024px, transparent exterior, opaque interior; master pixels match.")
    }
}
