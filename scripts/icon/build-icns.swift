import AppKit
import SwiftUI

// Builds the legacy .icns. macOS 15 and earlier do no compositing of their own,
// so the squircle, the inset, the shadow, the body gradient and the glyph's glow
// all have to be drawn here.

let markPath = CommandLine.arguments[1]
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
guard let mark = NSImage(contentsOfFile: markPath) else { exit(1) }

let base = Color(red: 0x19/255, green: 0x19/255, blue: 0x1a/255)

extension Color {
    func blended(_ amount: Double, with other: NSColor) -> Color {
        Color(nsColor: NSColor(self).blended(withFraction: amount, of: other) ?? NSColor(self))
    }
}

@MainActor
func icon(side: CGFloat) -> NSImage? {
    // Apple's grid: the body occupies the middle 824 of a 1024 canvas, with a
    // corner radius of ~22.37% of the body and continuous curvature.
    let body = side * 824.0 / 1024.0
    let radius = body * 0.2237

    let view = ZStack {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(
                colors: [base.blended(0.10, with: .white), base, base.blended(0.35, with: .black)],
                startPoint: .top, endPoint: .bottom))
            .frame(width: body, height: body)
            .shadow(color: .black.opacity(0.30), radius: side * 0.014, y: side * 0.010)

        // A shadow at zero offset is a glow; two of them — tight then wide — give
        // a bright core with a halo around it.
        Image(nsImage: mark)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: body * 0.78, height: body * 0.78)
            // Tuned down from a stronger bloom: the wider glow bled into the plug
            // cutout and softened the one detail the whole mark depends on.
            .shadow(color: .white.opacity(0.42), radius: side * 0.012)
            .shadow(color: .white.opacity(0.20), radius: side * 0.038)
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
print("wrote \(sizes.count) renditions")
