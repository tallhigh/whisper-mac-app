#!/usr/bin/env swift  // Generates the app icon from a vector — this file is the single source.  //
//   swift scripts/make_icon.swift            # writes the asset catalog
//   swift scripts/make_icon.swift --preview  # also writes dist/icon-preview.png
//
// Why a script: keeping the icon in a design file makes it uneditable. Here the shape,
// the colours and the grid sit as readable constants; change one and run `make icon`.

import AppKit
import Foundation

// MARK: - Grid
//
// Apple's macOS icon grid: a 1024 canvas, an 824×824 body, 100 of margin on each side.
// The corners aren't circular but "continuous" (a squircle); produced with a superellipse.

let canvas: CGFloat = 1024
let bodyInset: CGFloat = 100
let bodySide: CGFloat = canvas - bodyInset * 2

/// The superellipse exponent. Around 5 sits closest to macOS's continuous corner.
let squircleExponent: CGFloat = 5

// MARK: - Colours

func srgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let gradientTop = srgb(0x7C5CFF)  // violet
let gradientBottom = srgb(0x2B1C7A)  // deep indigo
let inkColor = srgb(0xFFFFFF)

// MARK: - Shapes

/// A square with continuously curved corners — the macOS icon body.
func squirclePath(rect: CGRect, exponent: CGFloat, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY

    for step in 0...steps {
        let theta = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosT = cos(theta)
        let sinT = sin(theta)
        // the parametric form of |x/a|^n + |y/b|^n = 1
        let x = cx + a * pow(abs(cosT), 2 / exponent) * (cosT < 0 ? -1 : 1)
        let y = cy + b * pow(abs(sinT), 2 / exponent) * (sinT < 0 ? -1 : 1)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

/// The sound-wave bars — on the left, thick and few so they still read at 16 px.
let barWidth: CGFloat = 54
let barGap: CGFloat = 46
let barHeights: [CGFloat] = [188, 344, 468, 268, 150]

/// The lines of text — on the right, carrying the meaning "transcribed".
let lineHeight: CGFloat = 50
let linePitch: CGFloat = 118
let lineWidths: [CGFloat] = [206, 206, 138]

func drawMark(in context: CGContext) {
    context.setFillColor(inkColor)

    let barsWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * barGap
    let lineBlockWidth = lineWidths.max() ?? 0
    let groupGap: CGFloat = 76
    let totalWidth = barsWidth + groupGap + lineBlockWidth
    let startX = (canvas - totalWidth) / 2
    let centerY = canvas / 2

    for (index, height) in barHeights.enumerated() {
        let x = startX + CGFloat(index) * (barWidth + barGap)
        let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
        context.addPath(
            CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    }

    let lineX = startX + barsWidth + groupGap
    let blockHeight = CGFloat(lineWidths.count - 1) * linePitch + lineHeight
    var lineY = centerY + blockHeight / 2 - lineHeight
    for width in lineWidths {
        let rect = CGRect(x: lineX, y: lineY, width: width, height: lineHeight)
        context.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
        lineY -= linePitch
    }

    context.fillPath()
}

func drawIcon(in context: CGContext) {
    let body = CGRect(x: bodyInset, y: bodyInset, width: bodySide, height: bodySide)
    let shape = squirclePath(rect: body, exponent: squircleExponent)

    // A soft shadow under the body, so the icon lifts off the background in the Dock and Finder.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10), blur: 28, color: srgb(0x000000).copy(alpha: 0.28))
    context.addPath(shape)
    context.setFillColor(gradientBottom)
    context.fillPath()
    context.restoreGState()

    // The gradient
    context.saveGState()
    context.addPath(shape)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [gradientTop, gradientBottom] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.minY),
            options: []
        )
    }
    // The light from above. Clipping the sheen halfway leaves a visible step at the edge;
    // instead the stroke is used as a mask and a gradient that fades downwards is drawn
    // inside it.
    context.saveGState()
    context.setLineWidth(6)
    context.addPath(squirclePath(rect: body.insetBy(dx: 3, dy: 3), exponent: squircleExponent))
    context.replacePathWithStrokedPath()
    context.clip()
    if let sheen = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
            srgb(0xFFFFFF).copy(alpha: 0.34) as Any,
            srgb(0xFFFFFF).copy(alpha: 0) as Any,
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.midY),
            options: [.drawsAfterEndLocation]
        )
    }
    context.restoreGState()
    context.restoreGState()

    drawMark(in: context)
}

// MARK: - Writing to disk

func renderPNG(side: Int) throws -> Data {
    guard
        let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        throw Failure("could not create the CGContext (\(side)px)")
    }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    // Each size is redrawn at that scale rather than downsampled from 1024:
    // that's what keeps the vector edges sharp.
    let scale = CGFloat(side) / canvas
    context.scaleBy(x: scale, y: scale)
    drawIcon(in: context)

    guard let image = context.makeImage() else { throw Failure("could not produce the CGImage (\(side)px)") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: side, height: side)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw Failure("could not encode the PNG (\(side)px)")
    }
    return data
}

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The (size, scale) pairs macOS's AppIcon asks for.
let slots: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

let root = URL(filePath: FileManager.default.currentDirectoryPath)
let iconSet = root.appending(path: "app/WhisperTranscriber/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var images: [[String: String]] = []
var cache: [Int: Data] = [:]

for slot in slots {
    let side = slot.point * slot.scale
    let data = try cache[side] ?? renderPNG(side: side)
    cache[side] = data

    let name = "icon_\(slot.point)x\(slot.point)\(slot.scale == 2 ? "@2x" : "").png"
    try data.write(to: iconSet.appending(path: name), options: .atomic)
    images.append([
        "idiom": "mac",
        "size": "\(slot.point)x\(slot.point)",
        "scale": "\(slot.scale)x",
        "filename": name,
    ])
    print("  \(name) — \(side)×\(side), \(data.count / 1024) KB")
}

let contents: [String: Any] = [
    "images": images,
    "info": ["version": 1, "author": "scripts/make_icon.swift"],
]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appending(path: "Contents.json"), options: .atomic)

// The asset catalog root wants a Contents.json of its own too.
let catalogRoot = iconSet.deletingLastPathComponent()
let rootContents = try JSONSerialization.data(
    withJSONObject: ["info": ["version": 1, "author": "scripts/make_icon.swift"]],
    options: [.prettyPrinted, .sortedKeys]
)
try rootContents.write(to: catalogRoot.appending(path: "Contents.json"), options: .atomic)

if CommandLine.arguments.contains("--preview") {
    let dist = root.appending(path: "dist")
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try (cache[1024] ?? renderPNG(side: 1024)).write(to: dist.appending(path: "icon-preview.png"))
    // So you can see with your own eyes that the small sizes really do read.
    try (cache[32] ?? renderPNG(side: 32)).write(to: dist.appending(path: "icon-preview-32.png"))
    print("  wrote dist/icon-preview.png and dist/icon-preview-32.png")
}

print("AppIcon.appiconset ready: \(slots.count) entries")
