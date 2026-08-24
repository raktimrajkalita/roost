// Generates Roost's app iconset with CoreGraphics (no Xcode / no NSApplication needed).
// Usage: swift icon/make-icon.swift icon/Roost.iconset
import CoreGraphics
import ImageIO
import Foundation

func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// The Roost panel silhouette: flat top, concave flared shoulders, rounded bottom (y-down).
func panelPath(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
               flareW: CGFloat, flareH: CGFloat, bottomR: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let bx0 = x + flareW, bx1 = x + w - flareW
    let br = min(bottomR, (bx1 - bx0) / 2, h / 2)
    p.move(to: CGPoint(x: x, y: y))
    p.addLine(to: CGPoint(x: x + w, y: y))
    p.addQuadCurve(to: CGPoint(x: bx1, y: y + flareH), control: CGPoint(x: bx1, y: y))
    p.addLine(to: CGPoint(x: bx1, y: y + h - br))
    p.addArc(tangent1End: CGPoint(x: bx1, y: y + h), tangent2End: CGPoint(x: bx1 - br, y: y + h), radius: br)
    p.addLine(to: CGPoint(x: bx0 + br, y: y + h))
    p.addArc(tangent1End: CGPoint(x: bx0, y: y + h), tangent2End: CGPoint(x: bx0, y: y + h - br), radius: br)
    p.addLine(to: CGPoint(x: bx0, y: y + flareH))
    p.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: bx0, y: y))
    p.closeSubpath()
    return p
}

func render(_ s: CGFloat) -> CGImage {
    let px = Int(s)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: 1, y: -1)     // top-left origin, y-down
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    let pad = s * 0.086
    let art = CGRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let radius = art.width * 0.2235

    // dark squircle + vertical gradient + top sheen
    ctx.saveGState()
    ctx.addPath(rr(art, radius)); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1),
        CGColor(srgbRed: 0.035, green: 0.035, blue: 0.045, alpha: 1)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: art.midX, y: art.minY),
                           end: CGPoint(x: art.midX, y: art.maxY), options: [])
    let sheen = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: art.midX, y: art.minY),
                           end: CGPoint(x: art.midX, y: art.minY + art.height * 0.5), options: [])
    ctx.restoreGState()

    // the notch panel silhouette
    let PW = art.width * 0.56
    let panelX = art.midX - PW / 2
    let panelTop = art.minY + art.height * 0.185
    let panelH = art.height * 0.47
    let panel = panelPath(x: panelX, y: panelTop, w: PW, h: panelH,
                          flareW: PW * 0.085, flareH: PW * 0.05, bottomR: PW * 0.17)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.03,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
    ctx.addPath(panel); ctx.setFillColor(CGColor(srgbRed: 0.015, green: 0.015, blue: 0.02, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(panel); ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.11))
    ctx.setLineWidth(max(s * 0.004, 0.75)); ctx.strokePath()
    ctx.restoreGState()

    // status dots: waiting amber / thinking blue / done green
    let dots = [
        CGColor(srgbRed: 1.0, green: 0.69, blue: 0.13, alpha: 1),
        CGColor(srgbRed: 0.48, green: 0.64, blue: 1.0, alpha: 1),
        CGColor(srgbRed: 0.23, green: 0.82, blue: 0.50, alpha: 1)
    ]
    let dotR = PW * 0.05, gap = PW * 0.17
    let firstY = panelTop + panelH * 0.40
    for (i, c) in dots.enumerated() {
        let cy = firstY + CGFloat(i) * gap
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s * 0.02, color: c.copy(alpha: 0.9)!)
        ctx.setFillColor(c)
        ctx.addEllipse(in: CGRect(x: art.midX - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
        ctx.fillPath()
        ctx.restoreGState()
    }

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./Roost.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, s) in sizes { writePNG(render(s), "\(outDir)/\(name).png") }
print("wrote iconset → \(outDir)")
