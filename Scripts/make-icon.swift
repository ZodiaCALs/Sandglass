#!/usr/bin/env swift
//
// Generates Sandglass.icns — a Liquid Glass hourglass app icon.
//
// Drawn programmatically with Core Graphics so the icon is reproducible and
// version-controlled as code rather than a binary blob. Run via
// `Scripts/make-icon.sh`, which drops the .icns into Resources/.
//
// Usage: swift Scripts/make-icon.swift <output.icns> [staging-dir]
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Canvas

/// Apple's icon grid leaves a margin around the squircle.
let canvas: CGFloat = 1024
let tileInset: CGFloat = 88
let tileRect = CGRect(
    x: tileInset,
    y: tileInset,
    width: canvas - tileInset * 2,
    height: canvas - tileInset * 2
).integral

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Standard macOS "squircle" — a superellipse, not a plain rounded rectangle.
func squirclePath(in rect: CGRect) -> CGPath {
    let a = rect.width / 2
    let b = rect.height / 2
    let n = 5.0
    let steps = 720
    let path = CGMutablePath()

    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * Double.pi
        let cosT = cos(t), sinT = sin(t)
        let x = pow(abs(cosT), 2 / n) * a * (cosT < 0 ? -1 : 1)
        let y = pow(abs(sinT), 2 / n) * b * (sinT < 0 ? -1 : 1)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// The hourglass silhouette: two bulbs pinched at the waist.
func hourglassPath(in rect: CGRect, waist: CGFloat) -> CGPath {
    let left = rect.minX
    let right = rect.maxX
    let top = rect.maxY
    let bottom = rect.minY
    let midY = rect.midY
    let radius: CGFloat = 30

    let path = CGMutablePath()
    // Rounded top-left corner, then the top rail.
    path.move(to: CGPoint(x: left, y: top - radius))
    path.addQuadCurve(to: CGPoint(x: left + radius, y: top), control: CGPoint(x: left, y: top))
    path.addLine(to: CGPoint(x: right - radius, y: top))
    path.addQuadCurve(to: CGPoint(x: right, y: top - radius), control: CGPoint(x: right, y: top))
    // Right rail sweeping down to the waist, then back out to the base.
    path.addCurve(
        to: CGPoint(x: rect.midX + waist, y: midY),
        control1: CGPoint(x: right, y: top - rect.height * 0.34),
        control2: CGPoint(x: rect.midX + waist + rect.width * 0.26, y: midY + rect.height * 0.14)
    )
    path.addCurve(
        to: CGPoint(x: right, y: bottom + radius),
        control1: CGPoint(x: rect.midX + waist + rect.width * 0.26, y: midY - rect.height * 0.14),
        control2: CGPoint(x: right, y: bottom + rect.height * 0.34)
    )
    path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right, y: bottom))
    path.addLine(to: CGPoint(x: left + radius, y: bottom))
    path.addQuadCurve(to: CGPoint(x: left, y: bottom + radius), control: CGPoint(x: left, y: bottom))
    // Left rail back up to the start.
    path.addCurve(
        to: CGPoint(x: rect.midX - waist, y: midY),
        control1: CGPoint(x: left, y: bottom + rect.height * 0.34),
        control2: CGPoint(x: rect.midX - waist - rect.width * 0.26, y: midY - rect.height * 0.14)
    )
    path.addCurve(
        to: CGPoint(x: left, y: top - radius),
        control1: CGPoint(x: rect.midX - waist - rect.width * 0.26, y: midY + rect.height * 0.14),
        control2: CGPoint(x: left, y: top - rect.height * 0.34)
    )
    path.closeSubpath()
    return path
}

/// Curved top surface of the sand piled in the lower bulb.
func lowerSandPath(in rect: CGRect, fill: CGFloat) -> CGPath {
    let bottom = rect.minY
    let level = rect.minY + rect.height * fill
    let bowl = rect.width * 0.5
    let path = CGMutablePath()
    let left = rect.minX + 10
    let right = rect.maxX - 10

    path.move(to: CGPoint(x: left, y: bottom + 4))
    path.addLine(to: CGPoint(x: right, y: bottom + 4))
    path.addLine(to: CGPoint(x: right, y: level))
    // Sand settles into a rounded mound.
    path.addQuadCurve(
        to: CGPoint(x: left, y: level),
        control: CGPoint(x: rect.midX, y: level + bowl * 0.42)
    )
    path.closeSubpath()
    return path
}

/// Sand still sitting in the upper bulb, drawn as a shallow funnel.
///
/// The mound is highest at the walls and dips toward the centre, which is what
/// makes it read as sand draining through the waist rather than a filled block.
func upperSandPath(in rect: CGRect, fill: CGFloat) -> CGPath {
    let top = rect.maxY
    let level = rect.maxY - rect.height * fill
    let dip = rect.height * 0.16
    let left = rect.minX + 10
    let right = rect.maxX - 10
    let path = CGMutablePath()

    path.move(to: CGPoint(x: left, y: top - 8))
    path.addLine(to: CGPoint(x: right, y: top - 8))
    path.addLine(to: CGPoint(x: right, y: level))
    // Two arcs meeting at the centre produce the familiar V of a draining bulb.
    path.addQuadCurve(
        to: CGPoint(x: rect.midX, y: level - dip),
        control: CGPoint(x: rect.midX + rect.width * 0.27, y: level)
    )
    path.addQuadCurve(
        to: CGPoint(x: left, y: level),
        control: CGPoint(x: rect.midX - rect.width * 0.27, y: level)
    )
    path.closeSubpath()
    return path
}

// MARK: - Drawing

func drawIcon(in context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let tile = squirclePath(in: tileRect)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Drop shadow beneath the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 38, color: rgb(4, 10, 26, 0.46))
    context.addPath(tile)
    context.setFillColor(rgb(14, 24, 46))
    context.fillPath()
    context.restoreGState()

    // Deep smoked-glass base. Keeping it dark lets the frosted hourglass and the
    // warm sand carry the contrast instead of fighting the tile for attention.
    context.saveGState()
    context.addPath(tile)
    context.clip()

    let baseGradient = CGGradient(
        colorsSpace: space,
        colors: [
            rgb(58, 92, 148),
            rgb(34, 54, 96),
            rgb(17, 26, 48)
        ] as CFArray,
        locations: [0, 0.5, 1]
    )!
    context.drawLinearGradient(
        baseGradient,
        start: CGPoint(x: tileRect.minX, y: tileRect.maxY),
        end: CGPoint(x: tileRect.maxX + 40, y: tileRect.minY),
        options: []
    )

    // Cool rim light in the top-left corner — the light source for everything else.
    let keyLight = CGGradient(
        colorsSpace: space,
        colors: [
            rgb(150, 208, 255, 0.40),
            rgb(120, 180, 255, 0.10),
            rgb(120, 180, 255, 0)
        ] as CFArray,
        locations: [0, 0.45, 1]
    )!
    context.drawRadialGradient(
        keyLight,
        startCenter: CGPoint(x: tileRect.minX + 150, y: tileRect.maxY - 130),
        startRadius: 0,
        endCenter: CGPoint(x: tileRect.minX + 150, y: tileRect.maxY - 130),
        endRadius: 560,
        options: []
    )

    // Faint warm bounce from the bottom-right, echoing the sand.
    let bounce = CGGradient(
        colorsSpace: space,
        colors: [rgb(255, 196, 128, 0.16), rgb(255, 170, 100, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        bounce,
        startCenter: CGPoint(x: tileRect.maxX - 170, y: tileRect.minY + 190),
        startRadius: 0,
        endCenter: CGPoint(x: tileRect.maxX - 170, y: tileRect.minY + 190),
        endRadius: 430,
        options: []
    )
    context.restoreGState()

    // ---- Hourglass ----
    let glassRect = CGRect(
        x: tileRect.midX - 158,
        y: tileRect.midY - 219,
        width: 316,
        height: 438
    )
    let waist: CGFloat = 15
    let glass = hourglassPath(in: glassRect, waist: waist)

    // Froster glass body, lifted slightly off the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: rgb(4, 12, 30, 0.55))
    context.addPath(glass)
    context.setFillColor(rgb(226, 240, 255, 0.16))
    context.fillPath()
    context.restoreGState()

    // Everything inside the silhouette is clipped to it.
    context.saveGState()
    context.addPath(glass)
    context.clip()

    // Frosted gradient: brighter where the light hits, fading down.
    let frost = CGGradient(
        colorsSpace: space,
        colors: [
            rgb(255, 255, 255, 0.30),
            rgb(206, 228, 255, 0.13),
            rgb(170, 200, 240, 0.07)
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        frost,
        start: CGPoint(x: glassRect.minX, y: glassRect.maxY),
        end: CGPoint(x: glassRect.maxX, y: glassRect.minY),
        options: []
    )

    // Champagne sand — warm, but desaturated enough to sit calmly on the blue.
    let sandGradient = CGGradient(
        colorsSpace: space,
        colors: [
            rgb(255, 238, 205),
            rgb(247, 205, 138),
            rgb(226, 166, 88)
        ] as CFArray,
        locations: [0, 0.5, 1]
    )!

    // Sand remaining in the top bulb.
    context.saveGState()
    context.addPath(upperSandPath(in: glassRect, fill: 0.22))
    context.clip()
    context.drawLinearGradient(
        sandGradient,
        start: CGPoint(x: glassRect.minX, y: glassRect.maxY),
        end: CGPoint(x: glassRect.minX, y: glassRect.midY + 40),
        options: []
    )
    context.restoreGState()

    // Sand piled in the bottom bulb.
    context.saveGState()
    context.addPath(lowerSandPath(in: glassRect, fill: 0.46))
    context.clip()
    context.drawLinearGradient(
        sandGradient,
        start: CGPoint(x: glassRect.minX, y: glassRect.minY + 16),
        end: CGPoint(x: glassRect.minX, y: glassRect.midY + 40),
        options: []
    )
    context.restoreGState()

    // Falling stream: thin and warm, kept inside the waist so it reads as sand.
    let stream = CGGradient(
        colorsSpace: space,
        colors: [
            rgb(255, 226, 176, 0.95),
            rgb(244, 190, 116, 0.55)
        ] as CFArray,
        locations: [0, 1]
    )!
    context.saveGState()
    context.clip(to: CGRect(x: glassRect.midX - 5, y: glassRect.midY - 4,
                            width: 10, height: glassRect.height * 0.20))
    context.drawLinearGradient(
        stream,
        start: CGPoint(x: 0, y: glassRect.midY + glassRect.height * 0.16),
        end: CGPoint(x: 0, y: glassRect.midY - 4),
        options: []
    )
    context.restoreGState()

    // Specular streak down the left wall.
    context.saveGState()
    context.setLineCap(.round)
    context.setStrokeColor(rgb(255, 255, 255, 0.55))
    context.setLineWidth(13)
    let highlight = CGMutablePath()
    highlight.move(to: CGPoint(x: glassRect.minX + 40, y: glassRect.maxY - 52))
    highlight.addCurve(
        to: CGPoint(x: glassRect.midX - 30, y: glassRect.midY + 34),
        control1: CGPoint(x: glassRect.minX + 62, y: glassRect.maxY - 158),
        control2: CGPoint(x: glassRect.midX - 72, y: glassRect.midY + 120)
    )
    context.addPath(highlight)
    context.strokePath()
    context.restoreGState()

    // Weight at the base of the glass.
    let depth = CGGradient(
        colorsSpace: space,
        colors: [rgb(12, 22, 48, 0), rgb(10, 18, 40, 0.38)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        depth,
        start: CGPoint(x: glassRect.midX, y: glassRect.midY - 30),
        end: CGPoint(x: glassRect.midX, y: glassRect.minY + 12),
        options: []
    )
    context.restoreGState()

    // Bright rim defines the glass against the dark tile.
    context.saveGState()
    context.addPath(glass)
    context.setLineWidth(7)
    context.setStrokeColor(rgb(255, 255, 255, 0.88))
    context.strokePath()
    context.restoreGState()

    // Top and bottom rails.
    context.saveGState()
    context.setLineCap(.round)
    context.setStrokeColor(rgb(255, 255, 255, 0.95))
    context.setLineWidth(17)
    context.move(to: CGPoint(x: glassRect.minX - 15, y: glassRect.maxY))
    context.addLine(to: CGPoint(x: glassRect.maxX + 15, y: glassRect.maxY))
    context.move(to: CGPoint(x: glassRect.minX - 15, y: glassRect.minY))
    context.addLine(to: CGPoint(x: glassRect.maxX + 15, y: glassRect.minY))
    context.strokePath()
    context.restoreGState()

    // Glass rim highlight on the tile itself.
    context.saveGState()
    context.addPath(tile)
    context.setLineWidth(5)
    context.setStrokeColor(rgb(255, 255, 255, 0.30))
    context.strokePath()
    context.restoreGState()
}

// MARK: - Output

func renderMaster() -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: Int(canvas),
        height: Int(canvas),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("could not create drawing context")
    }
    drawIcon(in: context)
    guard let image = context.makeImage() else { fatalError("could not render icon") }
    return image
}

func pngData(from image: CGImage, size: Int) -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("could not create \(size)px context")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let scaled = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(size)px png")
    }
    return data
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns> [staging-dir]\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let stagingURL = arguments.count >= 3
    ? URL(fileURLWithPath: arguments[2])
    : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sandglass-icon")

try? FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)

// The iconset layout `iconutil` expects.
let iconsetURL = stagingURL.appendingPathComponent("Sandglass.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let master = renderMaster()
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let url = iconsetURL.appendingPathComponent("\(variant.name).png")
    try pngData(from: master, size: variant.pixels).write(to: url)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed with status \(iconutil.terminationStatus)\n".utf8))
    exit(1)
}

print("icon: wrote \(outputURL.path)")
