// Renders the HWYD app icon as an exact-pixel .iconset.
// Usage: swift scripts/make-icon.swift <out.iconset> [preview-dir]
// Then: iconutil -c icns <out.iconset> -o Resources/AppIcon.icns
// See docs/ui/app-icon.md.
import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let previewDirectory = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat(hex >> 16 & 0xff) / 255, CGFloat(hex >> 8 & 0xff) / 255, CGFloat(hex & 0xff) / 255, alpha])!
}

// Same silhouette as the SF Symbol `waveform` used in the menu bar: six bars, tallest third.
let barHeights: [CGFloat] = [0.22, 0.61, 1.00, 0.50, 0.78, 0.30]

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let p = CGFloat(pixels)
    let small = pixels <= 32

    // macOS icon grid: 824/1024 body with a soft drop shadow. Tiny sizes use more of the canvas.
    let inset = small ? (pixels == 16 ? 1 : 2) : (p * 100 / 1024).rounded()
    let body = CGRect(x: inset, y: inset, width: p - 2 * inset, height: p - 2 * inset)
    let radius = body.width * 0.225
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    if !small {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -p * 10 / 1024), blur: p * 24 / 1024, color: color(0x000000, 0.45))
        cg.addPath(shape); cg.setFillColor(color(0x1b2025)); cg.fillPath()
        cg.restoreGState()
    }

    // Graphite body, slightly lifted at the top.
    cg.saveGState()
    cg.addPath(shape); cg.clip()
    let background = CGGradient(colorsSpace: srgb, colors: [color(0x2b343b), color(0x1b2025), color(0x161a1e)] as CFArray, locations: [0, 0.55, 1])!
    cg.drawLinearGradient(background, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    // Faint mint glow behind the waveform.
    if !small {
        let glow = CGGradient(colorsSpace: srgb, colors: [color(0xa5dcc8, 0.16), color(0xa5dcc8, 0)] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX, y: body.midY), startRadius: 0, endCenter: CGPoint(x: body.midX, y: body.midY), endRadius: body.width * 0.42, options: [])
    }
    cg.restoreGState()

    // Hairline rim: light on top, dark at the bottom.
    if pixels >= 64 {
        let line = max(1, p / 512)
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: body.insetBy(dx: line / 2, dy: line / 2), cornerWidth: radius - line / 2, cornerHeight: radius - line / 2, transform: nil))
        cg.setLineWidth(line); cg.replacePathWithStrokedPath(); cg.clip()
        let rim = CGGradient(colorsSpace: srgb, colors: [color(0xffffff, 0.16), color(0xffffff, 0.03), color(0x000000, 0.25)] as CFArray, locations: [0, 0.5, 1])!
        cg.drawLinearGradient(rim, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        cg.restoreGState()
    }

    // Waveform. Bars snap to whole pixels below 64 px so they stay crisp.
    let span = body.width * (small ? 0.78 : 0.56)
    let maxHeight = body.height * (small ? 0.70 : 0.56)
    var pitch = span / CGFloat(barHeights.count)
    var width = pitch * 0.46
    if pixels < 64 {
        pitch = max(2, (span / CGFloat(barHeights.count)).rounded())
        width = max(1, (pitch * 0.5).rounded())
    }
    let total = pitch * CGFloat(barHeights.count - 1) + width
    var x = body.midX - total / 2
    if pixels < 64 { x = x.rounded() }
    let mint = CGGradient(colorsSpace: srgb, colors: [color(0xc4ecdd), color(0xa5dcc8), color(0x86c4ad)] as CFArray, locations: [0, 0.5, 1])!
    for height in barHeights {
        var h = max(width, maxHeight * height)
        if pixels < 64 { h = max(2, (h / 2).rounded() * 2 + (pixels.isMultiple(of: 2) ? 0 : 1)) }
        var y = body.midY - h / 2
        if pixels < 64 { y = y.rounded() }
        let bar = CGRect(x: x, y: y, width: width, height: h)
        let corner = small ? 0 : width / 2
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: bar, cornerWidth: corner, cornerHeight: corner, transform: nil)); cg.clip()
        cg.drawLinearGradient(mint, start: CGPoint(x: 0, y: body.midY + maxHeight / 2), end: CGPoint(x: 0, y: body.midY - maxHeight / 2), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()
        x += pitch
    }
    context.flushGraphics()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try write(render(pixels: size * scale), to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

// Preview sheet: every pixel size at 1:1 on graphite and light backgrounds, plus 16 and 32 magnified.
if let previewDirectory {
    try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
    let sizes = [16, 32, 64, 128, 256, 512, 1024]
    for size in sizes { try write(render(pixels: size), to: previewDirectory.appendingPathComponent("icon-\(size).png")) }
    let width = 1024 + 512 + 256 + 128 + 64 + 32 + 16 + 8 * 40
    let height = 2 * (1024 + 80)
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: sheet)!
    let cg = context.cgContext
    for (row, background) in [0x1b2025, 0xeef1f2].enumerated() {
        let rowY = CGFloat(row * (1024 + 80))
        cg.setFillColor(color(UInt32(background))); cg.fill(CGRect(x: 0, y: rowY, width: CGFloat(width), height: 1024 + 80))
        var x: CGFloat = 40
        for size in sizes.reversed() {
            let image = render(pixels: size).cgImage!
            cg.interpolationQuality = .none
            cg.draw(image, in: CGRect(x: x, y: rowY + 40, width: CGFloat(size), height: CGFloat(size)))
            x += CGFloat(size) + 40
        }
    }
    context.flushGraphics()
    try write(sheet, to: previewDirectory.appendingPathComponent("sheet.png"))
    for size in [16, 32] {
        let zoom = 512
        let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: zoom, pixelsHigh: zoom, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let bigContext = NSGraphicsContext(bitmapImageRep: big)!
        bigContext.cgContext.setFillColor(color(0x808080)); bigContext.cgContext.fill(CGRect(x: 0, y: 0, width: zoom, height: zoom))
        bigContext.cgContext.interpolationQuality = .none
        bigContext.cgContext.draw(render(pixels: size).cgImage!, in: CGRect(x: 0, y: 0, width: zoom, height: zoom))
        bigContext.flushGraphics()
        try write(big, to: previewDirectory.appendingPathComponent("zoom-\(size).png"))
    }
}
