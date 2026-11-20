// Run from the project directory with: swift Design/MakeIcon.swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let fm = FileManager.default
let rootDir = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
let sourceIconURL = rootDir.appendingPathComponent("Assets/orfeus-icon-1024.png")
let dockIconURL = rootDir.appendingPathComponent("Assets/orfeus-dock-1024.png")
let appIconSetURL = rootDir.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let menuBarSetURL = rootDir.appendingPathComponent("App/Assets.xcassets/MenuBarIcon.imageset", isDirectory: true)

try fm.createDirectory(at: appIconSetURL, withIntermediateDirectories: true)
try fm.createDirectory(at: menuBarSetURL, withIntermediateDirectories: true)

func makeContext(pixelsWide: Int, pixelsHigh: Int) throws -> CGContext {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: nil,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    ctx.interpolationQuality = .high
    return ctx
}

func savePNG(_ cgImage: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    if !CGImageDestinationFinalize(dest) {
        throw CocoaError(.fileWriteUnknown)
    }
}

// MARK: - AppIcon (Orfeus A Lyre Emblem inside macOS HIG Squircle)

guard let srcNSImage = NSImage(contentsOf: sourceIconURL),
      let srcCGImage = srcNSImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    throw CocoaError(.fileReadNoSuchFile)
}

func renderSquircleAppIcon(pixels: Int) throws -> CGImage {
    let s = CGFloat(pixels)
    let ctx = try makeContext(pixelsWide: pixels, pixelsHigh: pixels)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let margin = s * (100.0 / 1024.0)
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2.0, height: s - margin * 2.0)
    let radius = rect.width * (185.0 / 824.0)

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    let squirclePath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * (12.0 / 1024.0)),
        blur: s * (26.0 / 1024.0),
        color: CGColor(srgbRed: 0.05, green: 0.07, blue: 0.11, alpha: 0.24)
    )
    NSColor(srgbRed: 0.953, green: 0.925, blue: 0.882, alpha: 1.0).setFill()
    squirclePath.fill()
    ctx.restoreGState()

    ctx.saveGState()
    squirclePath.addClip()
    ctx.draw(srcCGImage, in: rect)

    let borderInset = max(0.5, s * (1.25 / 1024.0))
    let borderRect = rect.insetBy(dx: borderInset * 0.5, dy: borderInset * 0.5)
    let borderPath = NSBezierPath(
        roundedRect: borderRect,
        xRadius: radius - borderInset * 0.5,
        yRadius: radius - borderInset * 0.5
    )
    borderPath.lineWidth = borderInset
    NSColor(srgbRed: 0.14, green: 0.10, blue: 0.08, alpha: 0.12).setStroke()
    borderPath.stroke()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    guard let img = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    return img
}

var appIconFiles: [Int: String] = [:]
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let name = "Icon-\(pixels).png"
    let img = try renderSquircleAppIcon(pixels: pixels)
    try savePNG(img, to: appIconSetURL.appendingPathComponent(name))
    appIconFiles[pixels] = name
    if pixels == 1024 {
        try savePNG(img, to: dockIconURL)
    }
}

let appIconEntries: [[String: String]] = [16, 32, 128, 256, 512].flatMap { size in
    [1, 2].map { scale in
        [
            "filename": appIconFiles[size * scale] ?? "",
            "idiom": "mac",
            "scale": "\(scale)x",
            "size": "\(size)x\(size)",
        ]
    }
}
let appIconCatalog: [String: Any] = ["images": appIconEntries, "info": ["author": "xcode", "version": 1]]
let appIconJSON = try JSONSerialization.data(withJSONObject: appIconCatalog, options: [.prettyPrinted, .sortedKeys])
try appIconJSON.write(to: appIconSetURL.appendingPathComponent("Contents.json"))

// MARK: - MenuBarIcon (Monochrome Template Silhouette for System Tray)

func renderMenuBarTemplateIcon(pixels: Int) throws -> CGImage {
    let s = CGFloat(pixels)
    let ctx = try makeContext(pixelsWide: pixels, pixelsHigh: pixels)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Draw in normalized 100x100 CoreGraphics space (origin at bottom-left)
    ctx.scaleBy(x: s / 100.0, y: s / 100.0)
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // 1. Sculpted classical soundbox cradle at the base
    let soundbox = CGMutablePath()
    soundbox.move(to: CGPoint(x: 22.5, y: 31.5))
    soundbox.addCurve(to: CGPoint(x: 50, y: 11.5),
                      control1: CGPoint(x: 24.5, y: 15.5),
                      control2: CGPoint(x: 35.5, y: 11.5))
    soundbox.addCurve(to: CGPoint(x: 77.5, y: 31.5),
                      control1: CGPoint(x: 64.5, y: 11.5),
                      control2: CGPoint(x: 75.5, y: 15.5))
    soundbox.addCurve(to: CGPoint(x: 50, y: 23.0),
                      control1: CGPoint(x: 69.5, y: 24.5),
                      control2: CGPoint(x: 60.5, y: 23.0))
    soundbox.addCurve(to: CGPoint(x: 22.5, y: 31.5),
                      control1: CGPoint(x: 39.5, y: 23.0),
                      control2: CGPoint(x: 30.5, y: 24.5))
    soundbox.closeSubpath()
    ctx.addPath(soundbox)
    ctx.fillPath()

    // 2. Symmetrical sweeping S-curve lyre arms ending in open Greek volutes
    for isRight in [false, true] {
        let fx: (CGFloat) -> CGFloat = { x in isRight ? (100.0 - x) : x }

        ctx.setLineWidth(7.2)
        let arm = CGMutablePath()
        arm.move(to: CGPoint(x: fx(25.5), y: 27.5))
        arm.addCurve(to: CGPoint(x: fx(16.0), y: 46.5),
                     control1: CGPoint(x: fx(19.5), y: 32.5),
                     control2: CGPoint(x: fx(16.0), y: 38.5))
        arm.addCurve(to: CGPoint(x: fx(26.5), y: 73.5),
                     control1: CGPoint(x: fx(16.0), y: 56.5),
                     control2: CGPoint(x: fx(26.5), y: 63.5))
        ctx.addPath(arm)
        ctx.strokePath()

        ctx.setLineWidth(6.2)
        let volute = CGMutablePath()
        volute.move(to: CGPoint(x: fx(26.5), y: 73.5))
        volute.addCurve(to: CGPoint(x: fx(23.5), y: 85.0),
                        control1: CGPoint(x: fx(26.5), y: 79.0),
                        control2: CGPoint(x: fx(25.5), y: 82.5))
        volute.addCurve(to: CGPoint(x: fx(9.5), y: 82.5),
                        control1: CGPoint(x: fx(20.0), y: 90.0),
                        control2: CGPoint(x: fx(10.5), y: 89.5))
        volute.addCurve(to: CGPoint(x: fx(15.0), y: 75.5),
                        control1: CGPoint(x: fx(8.8), y: 77.0),
                        control2: CGPoint(x: fx(11.8), y: 74.8))
        ctx.addPath(volute)
        ctx.strokePath()
    }

    // 3. Crossbar uniting the upper lyre arms
    ctx.setLineWidth(6.8)
    ctx.move(to: CGPoint(x: 26.5, y: 72.5))
    ctx.addLine(to: CGPoint(x: 73.5, y: 72.5))
    ctx.strokePath()

    // 4. Three parallel vertical strings with staggered volume-slider beads
    let sliders: [(x: CGFloat, beadY: CGFloat)] = [
        (36.5, 56.0),
        (50.0, 39.0),
        (63.5, 50.0),
    ]
    ctx.setLineWidth(5.0)
    for slider in sliders {
        ctx.move(to: CGPoint(x: slider.x, y: 20.5))
        ctx.addLine(to: CGPoint(x: slider.x, y: 72.5))
        ctx.strokePath()
    }

    let beadWidth: CGFloat = 9.6
    let beadHeight: CGFloat = 14.4
    let beadRadius: CGFloat = beadWidth / 2.0
    for slider in sliders {
        let pillRect = CGRect(
            x: slider.x - beadWidth / 2.0,
            y: slider.beadY - beadHeight / 2.0,
            width: beadWidth,
            height: beadHeight
        )
        let pill = CGPath(roundedRect: pillRect, cornerWidth: beadRadius, cornerHeight: beadRadius, transform: nil)
        ctx.addPath(pill)
        ctx.fillPath()
    }

    guard let img = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    return img
}

var menuEntries: [[String: String]] = []
for (scale, px) in [(1, 18), (2, 36)] {
    let filename = "MenuBarIcon-\(px).png"
    let img = try renderMenuBarTemplateIcon(pixels: px)
    try savePNG(img, to: menuBarSetURL.appendingPathComponent(filename))
    menuEntries.append([
        "filename": filename,
        "idiom": "mac",
        "scale": "\(scale)x",
    ])
}

let menuCatalog: [String: Any] = [
    "images": menuEntries,
    "info": ["author": "xcode", "version": 1],
    "properties": ["template-rendering-intent": "template"],
]
let menuJSON = try JSONSerialization.data(withJSONObject: menuCatalog, options: [.prettyPrinted, .sortedKeys])
try menuJSON.write(to: menuBarSetURL.appendingPathComponent("Contents.json"))

print("Generated Orfeus AppIcon and MenuBarIcon sets.")
