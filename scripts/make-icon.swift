#!/usr/bin/env swift
// Generates Resources/AppIcon.icns — a placeholder app icon (an SF Symbol on a
// gradient squircle). Swap the symbol/colors here, or drop in your own .icns.
//   swift scripts/make-icon.swift
import AppKit

let SYMBOL = "list.bullet.rectangle"          // glyph
let TOP = NSColor(srgbRed: 0.40, green: 0.36, blue: 0.95, alpha: 1) // indigo
let BOTTOM = NSColor(srgbRed: 0.30, green: 0.55, blue: 0.98, alpha: 1) // blue

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let f = CGFloat(px)
    let inset = f * 0.09                       // macOS icons keep a transparent margin
    let body = NSRect(x: inset, y: inset, width: f - 2 * inset, height: f - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
    NSGradient(colors: [TOP, BOTTOM])!.draw(in: path, angle: -90)

    let glyphSize = body.width * 0.52
    let cfg = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
    if let sym = NSImage(systemSymbolName: SYMBOL, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = sym.size
        let tinted = NSImage(size: s)          // recolor the template glyph white on a transparent layer
        tinted.lockFocus()
        sym.draw(at: .zero, from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let r = NSRect(x: (f - s.width) / 2, y: (f - s.height) / 2, width: s.width, height: s.height)
        tinted.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (filename, pixel size) per Apple's iconset spec
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
var cache: [Int: Data] = [:]
for (name, px) in entries {
    let data = cache[px] ?? render(px)
    cache[px] = data
    try! data.write(to: iconset.appendingPathComponent("\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: iconset)
print("Wrote Resources/AppIcon.icns")
