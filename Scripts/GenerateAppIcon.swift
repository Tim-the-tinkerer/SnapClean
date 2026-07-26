#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func renderIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let margin = s * 0.06
    let corner = s * 0.22
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Teal → deep cyan gradient (snapshot / disk utility feel)
    let colors = [
        CGColor(srgbRed: 0.05, green: 0.42, blue: 0.48, alpha: 1),
        CGColor(srgbRed: 0.08, green: 0.55, blue: 0.58, alpha: 1),
        CGColor(srgbRed: 0.12, green: 0.68, blue: 0.62, alpha: 1),
        CGColor(srgbRed: 0.06, green: 0.38, blue: 0.45, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.35, 0.7, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // Top sheen
    if let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            highlight,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.midY),
            options: []
        )
    }

    ctx.restoreGState()

    // Border
    ctx.setStrokeColor(CGColor(srgbRed: 0.70, green: 0.95, blue: 0.92, alpha: 0.45))
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.addPath(path)
    ctx.strokePath()

    drawAperture(in: ctx, size: s, bounds: rect)
    return ctx.makeImage()
}

func drawAperture(in ctx: CGContext, size s: CGFloat, bounds: CGRect) {
    let center = CGPoint(x: bounds.midX, y: bounds.midY + s * 0.01)
    let outerR = s * 0.28
    let innerR = s * 0.10
    let cream = CGColor(srgbRed: 0.94, green: 0.98, blue: 0.97, alpha: 0.95)

    // Outer ring
    ctx.setStrokeColor(cream)
    ctx.setLineWidth(max(2.0, s * 0.035))
    ctx.addEllipse(in: CGRect(
        x: center.x - outerR,
        y: center.y - outerR,
        width: outerR * 2,
        height: outerR * 2
    ))
    ctx.strokePath()

    // Aperture blades (6 wedges)
    let bladeCount = 6
    ctx.setFillColor(CGColor(srgbRed: 0.90, green: 0.97, blue: 0.96, alpha: 0.88))
    for i in 0..<bladeCount {
        let a0 = CGFloat(i) / CGFloat(bladeCount) * .pi * 2 - .pi / 2
        let a1 = CGFloat(i + 1) / CGFloat(bladeCount) * .pi * 2 - .pi / 2
        let mid = (a0 + a1) / 2

        let pOuter1 = CGPoint(x: center.x + cos(a0) * outerR * 0.82, y: center.y + sin(a0) * outerR * 0.82)
        let pOuter2 = CGPoint(x: center.x + cos(a1) * outerR * 0.82, y: center.y + sin(a1) * outerR * 0.82)
        let pInner = CGPoint(x: center.x + cos(mid) * innerR, y: center.y + sin(mid) * innerR)

        ctx.move(to: pOuter1)
        ctx.addLine(to: pOuter2)
        ctx.addLine(to: pInner)
        ctx.closePath()
        ctx.fillPath()
    }

    // Center hole
    ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.22, blue: 0.28, alpha: 0.95))
    ctx.fillEllipse(in: CGRect(
        x: center.x - innerR * 0.85,
        y: center.y - innerR * 0.85,
        width: innerR * 1.7,
        height: innerR * 1.7
    ))

    // Small clock hand hint (time / snapshots)
    ctx.setStrokeColor(CGColor(srgbRed: 0.75, green: 0.95, blue: 0.92, alpha: 0.9))
    ctx.setLineWidth(max(1.2, s * 0.02))
    ctx.setLineCap(.round)
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x, y: center.y + innerR * 0.55))
    ctx.strokePath()
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x + innerR * 0.4, y: center.y))
    ctx.strokePath()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not create image destination for \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Could not write PNG \(url.path)")
    }
}

// --- main ---

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
let iconset = assets.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("diana.k@example.org", 32),
    ("icon_32x32.png", 32),
    ("ivan.p@example.net", 64),
    ("icon_128x128.png", 128),
    ("wendy.h@example.net", 256),
    ("icon_256x256.png", 256),
    ("wendy.h@example.net", 512),
    ("icon_512x512.png", 512),
    ("walt.e@example.net", 1024),
]

for entry in sizes {
    guard let img = renderIcon(size: entry.px) else {
        fatalError("Failed to render icon size \(entry.px)")
    }
    writePNG(img, to: iconset.appendingPathComponent(entry.name))
}

if let master = renderIcon(size: 1024) {
    writePNG(master, to: assets.appendingPathComponent("AppIcon-1024.png"))
}

let icnsURL = assets.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}

print("Wrote \(icnsURL.path)")
