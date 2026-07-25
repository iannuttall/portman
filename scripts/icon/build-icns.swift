import AppKit
import SwiftUI

// Builds the legacy .icns. macOS 15 and earlier do no compositing of app icons,
// so the squircle, the inset, the drop shadow, the body gradient and the glyph's
// glow all have to be drawn here.
//
//   swiftc -swift-version 6 scripts/icon/build-icns.swift -o /tmp/build-icns
//   /tmp/build-icns <mark.png> /tmp/AppIcon.iconset
//   iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns

let markPath = CommandLine.arguments[1]
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let base = Color(red: 0x19/255, green: 0x19/255, blue: 0x1a/255)

/// Ink height as a fraction of the icon body.
let inkFraction = 0.62

/// macOS 26 wraps app icons in its own rounded shape, so the artwork has to run
/// edge to edge and let the system do the rounding. Drawing our own inset squircle
/// produced a squircle inside a squircle with a grey border around it.
///
/// The cost is macOS 15 and earlier, which do no masking — there this renders as a
/// square tile. Set FULL_BLEED=0 to get the self-rounded version back.
let fullBleed = ProcessInfo.processInfo.environment["FULL_BLEED"] != "0" 
/// Optical centring. The mark is geometrically dead centre, but a P carries its
/// mass in the stem and bowl with the lower right empty, so its centre of mass sits
/// ~6% up and left of its bounding box. Correcting by half of that reads as centred;
/// the full correction overshoots and opens a gap on the left.
let opticalFraction = 0.031

extension Color {
    func blended(_ amount: Double, with other: NSColor) -> Color {
        Color(nsColor: NSColor(self).blended(withFraction: amount, of: other) ?? NSColor(self))
    }
}

/// Trims the transparent border so the image's bounds ARE its ink.
///
/// The source artwork carries its own ~100px margin. Left in, it silently pads
/// every size calculation and "80%" stops meaning 80%.
func cropToInk(_ path: String) -> NSImage? {
    guard let image = NSImage(contentsOfFile: path), let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }

    let w = rep.pixelsWide, h = rep.pixelsHigh
    var minX = w, maxX = -1, minY = h, maxY = -1

    for y in 0..<h {
        for x in 0..<w {
            guard let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.05 else { continue }
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }

    guard maxX > minX, maxY > minY else { return nil }

    let rect = NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    let cropped = NSImage(size: rect.size)
    cropped.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: rect.size),
               from: NSRect(x: rect.minX, y: CGFloat(h) - rect.maxY,
                            width: rect.width, height: rect.height),
               operation: .copy, fraction: 1)
    cropped.unlockFocus()
    return cropped
}

guard let mark = cropToInk(markPath) else {
    print("could not read a mark from \(markPath)")
    exit(1)
}

@MainActor
func icon(side: CGFloat) -> NSImage? {
    // Apple's grid: the body occupies the middle 824 of a 1024 canvas, corner
    // radius ~22.37% of the body, continuous curvature.
    let body = fullBleed ? side : side * 824.0 / 1024.0
    let frame = body * inkFraction
    let nudge = frame * opticalFraction

    let view = ZStack {
        RoundedRectangle(cornerRadius: fullBleed ? 0 : body * 0.2237, style: .continuous)
            .fill(LinearGradient(
                colors: [base.blended(0.10, with: .white), base, base.blended(0.35, with: .black)],
                startPoint: .top, endPoint: .bottom))
            .frame(width: body, height: body)
            .shadow(color: .black.opacity(fullBleed ? 0 : 0.30),
                    radius: side * 0.014, y: side * 0.010)

        // A shadow at zero offset is a glow; a tight one and a wide one give a
        // bright core with a halo. Kept restrained — a stronger bloom bleeds into
        // the plug cutout and softens the detail the mark depends on.
        Image(nsImage: mark)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: frame, height: frame)
            .shadow(color: .white.opacity(0.42), radius: side * 0.012)
            .shadow(color: .white.opacity(0.20), radius: side * 0.038)
            .offset(x: nudge, y: nudge)
    }
    .frame(width: side, height: side)

    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    return renderer.nsImage
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

MainActor.assumeIsolated {
    for (name, px) in sizes {
        guard let image = icon(side: px), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { continue }
        rep.size = NSSize(width: px, height: px)
        guard let png = rep.representation(using: .png, properties: [:]) else { continue }
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }
}

print("wrote \(sizes.count) renditions at \(Int(inkFraction * 100))% ink")
