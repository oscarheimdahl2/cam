#!/usr/bin/env swift
// Builds the menu bar icon assets from design/menuicon.png (white shape on a transparent background).
// Crops to the visible shape, scales it to a fixed height, and writes the 1x and 2x images of the asset catalog's
// MenuIcon image set. It is a template image, so macOS tints it for light and dark menu bars.
//
//   swift scripts/make-menu-icon.swift
//
// Also writes a preview at the real sizes to /tmp/cam-menuicon-preview.png.
import AppKit

/// Height of the icon in points. Matched against the neighbouring menu bar icons (a full 18 pt looked too big).
let heightPoints = 15

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("design/menuicon.png")
let imageSet = root.appendingPathComponent("App/Assets.xcassets/MenuIcon.imageset")

guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("Cannot read \(source.path)"); exit(1)
}
let w0 = full.width, h0 = full.height

// Find the visible shape so empty margin in the file doesn't shrink the icon.
let probe = CGContext(data: nil, width: w0, height: h0, bitsPerComponent: 8, bytesPerRow: w0 * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
probe.draw(full, in: CGRect(x: 0, y: 0, width: w0, height: h0))
let pixels = probe.data!.assumingMemoryBound(to: UInt8.self)
var minX = w0, minY = h0, maxX = -1, maxY = -1
for y in 0..<h0 { for x in 0..<w0 where pixels[(y * w0 + x) * 4 + 3] > 8 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
guard maxX >= 0 else { print("The image has no visible pixels (is it fully transparent?)"); exit(1) }
print("file \(w0)x\(h0); shape \(maxX - minX + 1)x\(maxY - minY + 1); margins L\(minX) R\(w0 - 1 - maxX) T\(minY) B\(h0 - 1 - maxY)")

// The probe read rows from the bottom; CGImage.cropping uses a top-left origin.
let glyph = full.cropping(to: CGRect(x: minX, y: h0 - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1))!
let aspect = Double(glyph.width) / Double(glyph.height)

for (name, scale) in [("menuicon.png", 1), ("menuicon@2x.png", 2)] {
    let h = heightPoints * scale, w = Int((Double(h) * aspect).rounded())
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(glyph, in: CGRect(x: 0, y: 0, width: w, height: h))
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: imageSet.appendingPathComponent(name))
    print("\(name): \(w)x\(h)")
}

// Preview: the icon at 2x and 1x on a light and a dark menu bar.
func tinted(_ color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: glyph.width, height: glyph.height), flipped: false) { rect in
        let c = NSGraphicsContext.current!.cgContext
        c.clip(to: rect, mask: glyph); color.setFill(); rect.fill(); return true
    }
}
let sheet = NSImage(size: NSSize(width: 260, height: 120), flipped: false) { _ in
    for (row, (bg, fg)) in [(NSColor(white: 0.95, alpha: 1), NSColor.black), (NSColor(white: 0.14, alpha: 1), NSColor.white)].enumerated() {
        bg.setFill(); NSRect(x: 0, y: CGFloat(row) * 60, width: 260, height: 60).fill()
        var x: CGFloat = 12
        for height in [Double(heightPoints * 2), Double(heightPoints)] {
            tinted(fg).draw(in: NSRect(x: x, y: CGFloat(row) * 60 + 14, width: height * aspect, height: height))
            x += height * aspect + 20
        }
    }
    return true
}
try! NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "/tmp/cam-menuicon-preview.png"))
