import AppKit

// Renders a built app's icon at an arbitrary size.
//
// actool's generated .icns stops at 256, so on macOS 15 and earlier anything larger
// — Get Info, Quick Look, large icon view — is upscaled from that and looks soft.
// The system can render from the vector layers in Assets.car at any size, so we ask
// it for the big renditions and merge them back into the .icns.
//
//   render-icon <app-bundle> <size> <output.png>

guard CommandLine.arguments.count == 4,
      let side = Int(CommandLine.arguments[2]) else {
    print("usage: render-icon <app-bundle> <size> <output.png>")
    exit(2)
}

let appPath = CommandLine.arguments[1]
let out = CommandLine.arguments[3]

let icon = NSWorkspace.shared.icon(forFile: appPath)
icon.size = NSSize(width: side, height: side)

// Drawn into a bitmap with explicit pixel dimensions rather than via lockFocus():
// on a Retina display lockFocus() renders at the 2x backing scale, so asking for
// 1024 silently produced 2048 and iconutil dropped the rendition on the floor.
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    print("could not allocate a \(side)px bitmap")
    exit(1)
}

rep.size = NSSize(width: side, height: side)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
          from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    print("could not encode the render")
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: out))
} catch {
    print("could not write \(out): \(error.localizedDescription)")
    exit(1)
}
