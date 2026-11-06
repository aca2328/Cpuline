// Renders the app icon in the panel's stacked-bars style into an .iconset
// directory, for bundle.sh to turn into AppIcon.icns with iconutil.
// Usage: swift make-icon.swift <output.iconset>

import AppKit

guard CommandLine.arguments.count == 2 else {
    print("Usage: swift make-icon.swift <output.iconset>")
    exit(1)
}
let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

/// Draws the icon on a 1024-point design canvas, scaled to `pixels`.
func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Shadows ignore the CTM, so blur and offset are scaled by `unit` by hand.
    let unit = CGFloat(pixels) / 1024
    ctx.scaleBy(x: unit, y: unit)

    // macOS icon grid: 824pt rounded square centered on the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 28 * unit, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Dark navy background, matching the graph canvas.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: nil, colors: [
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.19, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.075, alpha: 1).cgColor
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // Faint grid.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
    ctx.setLineWidth(4)
    for i in 1...4 {
        let y = tile.minY + CGFloat(i) * tile.height / 5
        ctx.move(to: CGPoint(x: tile.minX, y: y))
        ctx.addLine(to: CGPoint(x: tile.maxX, y: y))
    }
    ctx.strokePath()

    // Stacked user/system history bars with a glow. Fixed sRGB values, matching
    // the app's panel, so output doesn't depend on the build machine's settings.
    let user = NSColor(srgbRed: 0.36, green: 0.36, blue: 1.00, alpha: 1)
    let system = NSColor(srgbRed: 0.93, green: 0.27, blue: 0.60, alpha: 1)
    let bars: [(CGFloat, CGFloat)] = [
        (0.22, 0.12), (0.30, 0.16), (0.26, 0.12), (0.42, 0.20), (0.34, 0.18), (0.52, 0.24), (0.44, 0.20), (0.58, 0.28)
    ]
    let plot = tile.insetBy(dx: 90, dy: 130)
    let slot = plot.width / CGFloat(bars.count)
    for (i, bar) in bars.enumerated() {
        let x = plot.minX + CGFloat(i) * slot + slot * 0.14
        let width = slot * 0.72
        let userHeight = bar.0 * plot.height
        let systemHeight = bar.1 * plot.height
        for (color, y, height) in [(user, plot.minY, userHeight), (system, plot.minY + userHeight + 10, systemHeight)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 30 * unit, color: color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
                               cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
    ctx.restoreGState()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: outputDir.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: outputDir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
