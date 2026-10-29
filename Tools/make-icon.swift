// Renders Hifiguard's app icon PNGs. Run: swift Tools/make-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: "Hifiguard/Assets.xcassets/AppIcon.appiconset")

func render(_ px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Background: rounded square, teal-to-indigo gradient.
    let bg = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                    cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(bg)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(srgbRed: 0.09, green: 0.62, blue: 0.62, alpha: 1),
                                       CGColor(srgbRed: 0.18, green: 0.16, blue: 0.47, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    ctx.setStrokeColor(white)
    ctx.setFillColor(white)
    ctx.setLineCap(.round)

    // Headband.
    ctx.setLineWidth(56)
    ctx.addArc(center: CGPoint(x: 512, y: 470), radius: 250, startAngle: .pi * 0.05, endAngle: .pi * 0.95, clockwise: false)
    ctx.strokePath()

    // Ear cups.
    for x in [262.0, 682.0] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 300, width: 80, height: 210),
                           cornerWidth: 40, cornerHeight: 40, transform: nil))
        ctx.fillPath()
    }

    // Steady waveform between the cups: the sound that stays hi-fi.
    ctx.setLineWidth(34)
    let bars: [CGFloat] = [70, 150, 220, 150, 70]
    for (i, h) in bars.enumerated() {
        let x = 412 + CGFloat(i) * 50
        ctx.move(to: CGPoint(x: x, y: 405 - h / 2))
        ctx.addLine(to: CGPoint(x: x, y: 405 + h / 2))
    }
    ctx.strokePath()
    return ctx.makeImage()!
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    let url = out.appendingPathComponent("icon_\(px).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(px), nil)
    CGImageDestinationFinalize(dest)
}
print("Wrote icons to \(out.path)")
