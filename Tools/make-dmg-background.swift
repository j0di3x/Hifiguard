// Renders the DMG window background (660×400 pt, 1x and 2x PNGs).
// Run: swift Tools/make-dmg-background.swift <output dir>
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 660.0, height = 400.0
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconURL = URL(fileURLWithPath: "Hifiguard/Assets.xcassets/AppIcon.appiconset/icon_256.png")

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let ink = color(0.16, 0.14, 0.38)
let accent = color(0.38, 0.33, 0.85)

/// Draws text with its baseline-left at (x, yFromTop); `centered` centres it on x.
func drawText(_ ctx: CGContext, _ text: String, size: Double, bold: Bool, color: CGColor,
              x: Double, yFromTop: Double, centered: Bool = false) {
    let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
    let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font,
                                                .init(kCTForegroundColorAttributeName as String): color]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: centered ? x - lineWidth / 2 : x, y: height - yFromTop)
    CTLineDraw(line, ctx)
}

func render(scale: Double) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)

    // Soft teal → lavender wash, echoing the app icon.
    let gradient = CGGradient(colorsSpace: srgb,
                              colors: [color(0.82, 0.95, 0.94), color(0.86, 0.84, 0.99)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])

    // Header: small icon + name.
    if let source = CGImageSourceCreateWithURL(iconURL as CFURL, nil),
       let icon = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        ctx.draw(icon, in: CGRect(x: 14, y: height - 18 - 40, width: 40, height: 40))
    }
    drawText(ctx, "Hifiguard", size: 20, bold: true, color: ink, x: 56, yFromTop: 45)

    // Tagline.
    drawText(ctx, "Your music stays hi-fi.", size: 24, bold: true, color: ink, x: width / 2, yFromTop: 102, centered: true)
    drawText(ctx, "Even when an app grabs the mic.", size: 15, bold: false, color: ink.copy(alpha: 0.7)!,
             x: width / 2, yFromTop: 126, centered: true)

    // Dashed arrow from the app towards Applications (icons sit at y = 230 from top).
    func p(_ x: Double, _ yFromTop: Double) -> CGPoint { CGPoint(x: x, y: height - yFromTop) }
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [7, 6])
    ctx.move(to: p(262, 300))
    ctx.addCurve(to: p(398, 282), control1: p(290, 352), control2: p(370, 352))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.move(to: p(384, 284))
    ctx.addLine(to: p(399, 280))
    ctx.addLine(to: p(400, 296))
    ctx.strokePath()

    drawText(ctx, "Drag to Applications to install", size: 12, bold: false, color: ink.copy(alpha: 0.55)!,
             x: width / 2, yFromTop: 378, centered: true)
    return ctx.makeImage()!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(scale: scale), [kCGImagePropertyDPIWidth: 72 * scale,
                                                            kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    CGImageDestinationFinalize(dest)
}
print("Wrote DMG background to \(outDir.path)")
