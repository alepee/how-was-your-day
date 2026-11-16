import AppKit
import SwiftUI

/// The round ink stamp that marks a session whose people present were declared informed and
/// agreeing. Drawn, not an image: the ring text and the date follow the app's language, and the
/// ink texture masks it so it reads as pressed on paper.
struct ConsentStamp: View {
    let date: Date
    var color: Color = Studio.copper
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height), unit = side / 200
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func ring(_ radius: CGFloat, _ width: CGFloat) {
                let rect = CGRect(x: center.x - radius * unit, y: center.y - radius * unit, width: 2 * radius * unit, height: 2 * radius * unit)
                context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: width * unit)
            }
            ring(92, 5.5); ring(82, 1.6); ring(54, 1.6)
            // Ring text, spread so it closes the circle whatever the language.
            let glyphs = Array(ConsentStamp.ringText).map { context.resolve(Text(String($0)).font(.system(size: 12.5 * unit, weight: .heavy)).foregroundStyle(color)) }
            let widths = glyphs.map { $0.measure(in: size).width }
            let radius = 68 * unit, circumference = 2 * .pi * radius
            let spacing = max(0, (circumference - widths.reduce(0, +)) / CGFloat(glyphs.count))
            var travelled: CGFloat = 0
            for (glyph, width) in zip(glyphs, widths) {
                let angle = (travelled + width / 2) / radius - .pi / 2
                var letter = context
                letter.translateBy(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                letter.rotate(by: .radians(Double(angle + .pi / 2)))
                letter.draw(glyph, at: .zero, anchor: .center)
                travelled += width + spacing
            }
            context.draw(Text(ConsentStamp.day(date)).font(.system(size: 14 * unit, weight: .bold, design: .monospaced)).foregroundStyle(color),
                         at: CGPoint(x: center.x, y: center.y - 9 * unit), anchor: .center)
            context.draw(Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 21 * unit, weight: .heavy, design: .monospaced)).foregroundStyle(color),
                         at: CGPoint(x: center.x, y: center.y + 13 * unit), anchor: .center)
        }
        .mask { Image(decorative: StampInk.texture, scale: 1).resizable().interpolation(.high) }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement().accessibilityLabel(Text("Consentement déclaré à \(date.formatted(date: .omitted, time: .shortened))"))
    }
    static let ringText = String(localized: "CONSENTEMENT RECUEILLI ✦ PERSONNES INFORMÉES ✦ ")
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits)).replacingOccurrences(of: "/", with: "·")
    }
}

/// The stamp landing: it comes down large, blurred and casting a shadow, presses slightly past
/// its size, then rests at a slight angle. Reduce Motion fades it in instead.
struct StampPress: ViewModifier {
    var progress: CGFloat
    func body(content: Content) -> some View {
        let remaining = max(0, 1 - progress)
        content
            .scaleEffect(1 + 0.9 * (1 - progress))
            .blur(radius: 4 * remaining)
            .shadow(color: .black.opacity(0.5 * remaining), radius: 18 * remaining, y: 26 * remaining)
            .opacity(Double(min(1, max(0, progress * 2))) * 0.92)
    }
}

extension AnyTransition {
    static func stamp(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .modifier(active: StampPress(progress: 0), identity: StampPress(progress: 1)), removal: .opacity)
    }
}

enum StampImpact {
    /// A trackpad tap as the stamp touches down. Silent: a sound could reach a call's microphone.
    @MainActor static func feel() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
    }
}

/// Ink coverage: large soft patches where the stamp pressed less, and a fine grain. Computed
/// once from a fixed seed so every stamp wears the same ink.
enum StampInk {
    static let texture: CGImage = make(side: 256)
    private static func make(side: Int) -> CGImage {
        var generator = SeededGenerator(seed: 0x5EA1)
        let grid = 9
        let coarse = (0..<(grid * grid)).map { _ in Double.random(in: 0...1, using: &generator) }
        func blot(_ x: Double, _ y: Double) -> Double {
            let gx = x * Double(grid - 1), gy = y * Double(grid - 1)
            let x0 = min(grid - 2, Int(gx)), y0 = min(grid - 2, Int(gy))
            let fx = gx - Double(x0), fy = gy - Double(y0)
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            func at(_ i: Int, _ j: Int) -> Double { coarse[j * grid + i] }
            let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * sx
            let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * sx
            return top + (bottom - top) * sy
        }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let patch = min(1, max(0, 2.1 - 2.6 * blot(Double(x) / Double(side - 1), Double(y) / Double(side - 1))))
                let grain = min(1, max(0, 1.75 - 1.6 * Double.random(in: 0...1, using: &generator)))
                // Premultiplied white: the coverage is the alpha the mask reads.
                let value = UInt8(255 * patch * grain)
                for channel in 0..<4 { pixels[(y * side + x) * 4 + channel] = value }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)!
    }
}

/// SplitMix64, so the ink is the same on every launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
