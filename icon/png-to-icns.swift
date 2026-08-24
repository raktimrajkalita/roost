// Turns a square PNG into a native macOS iconset (full-bleed, squircle-rounded corners).
// Usage: swift icon/png-to-icns.swift <input.png> [outDir]
import CoreGraphics
import ImageIO
import Foundation

func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("cannot load \(path)\n".data(using: .utf8)!); exit(1)
    }
    return img
}

func render(_ src: CGImage, _ s: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(s), height: Int(s), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: s * 0.2235, cornerHeight: s * 0.2235, transform: nil))
    ctx.clip()
    ctx.draw(src, in: rect)                 // source is square -> fills the tile
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
let input = args.count > 1 ? args[1] : "\(NSHomeDirectory())/Desktop/Roost.png"
let outDir = args.count > 2 ? args[2] : "./Roost.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let src = loadImage(input)
let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, s) in sizes { writePNG(render(src, s), "\(outDir)/\(name).png") }
print("wrote iconset from \(input) -> \(outDir)")
