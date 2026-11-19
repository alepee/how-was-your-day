import SwiftUI
import HWYDCore

/// The banner over each step of the welcome tour, drawn and animated in code: a misty mint
/// waveform that keeps flowing from one step to the next, and over it one motif per feature, with
/// copper as the single accent. With Reduce Motion on, the banner stands still.
struct OnboardingIllustration: View {
    let step: OnboardingStep
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 12 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            let palette = BannerPalette(dark: colorScheme == .dark)
            ZStack {
                Canvas { context, size in BannerMist.draw(in: &context, size: size, time: time, palette: palette) }
                Canvas { context, size in BannerMotif.draw(step, in: &context, size: size, time: time, palette: palette) }
                    .id(step).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: step)
        // The banner fades into the sheet on both sides.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .frame(height: 150).frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// The Studio mint and copper, resolved for the appearance: a canvas draws plain colors.
private struct BannerPalette {
    let mint: Color
    let copper: Color
    let mist: Color
    init(dark: Bool) {
        mint = dark ? Color(red: 165 / 255, green: 220 / 255, blue: 200 / 255) : Color(red: 37 / 255, green: 105 / 255, blue: 81 / 255)
        copper = dark ? Color(red: 233 / 255, green: 164 / 255, blue: 140 / 255) : Color(red: 153 / 255, green: 73 / 255, blue: 47 / 255)
        mist = dark ? Color(red: 120 / 255, green: 170 / 255, blue: 155 / 255) : Color(red: 90 / 255, green: 140 / 255, blue: 125 / 255)
    }
}

/// Soft ribbons of a slow waveform, each a blurred band with a fine line through it.
private enum BannerMist {
    private struct Ribbon {
        let base: Double, amplitude: Double, wavelength: Double, speed: Double, phase: Double, thickness: Double
    }
    private static let ribbons = [
        Ribbon(base: 0.66, amplitude: 9, wavelength: 260, speed: 0.22, phase: 0, thickness: 16),
        Ribbon(base: 0.70, amplitude: 12, wavelength: 340, speed: -0.16, phase: 1.7, thickness: 22),
        Ribbon(base: 0.63, amplitude: 7, wavelength: 200, speed: 0.30, phase: 3.1, thickness: 10),
        Ribbon(base: 0.74, amplitude: 10, wavelength: 420, speed: 0.12, phase: 4.4, thickness: 26),
        Ribbon(base: 0.68, amplitude: 14, wavelength: 300, speed: -0.24, phase: 5.2, thickness: 14),
    ]

    static func draw(in context: inout GraphicsContext, size: CGSize, time: Double, palette: BannerPalette) {
        for ribbon in ribbons {
            let y = { (x: Double) -> Double in
                let k = 2 * .pi / ribbon.wavelength
                return size.height * ribbon.base
                    + ribbon.amplitude * sin(k * x + ribbon.phase + time * ribbon.speed)
                    + ribbon.amplitude * 0.4 * sin(k * 2.3 * x - ribbon.phase - time * ribbon.speed * 1.6)
            }
            // The band swells and thins along the ribbon.
            let half = { (x: Double) -> Double in
                ribbon.thickness / 2 * (0.55 + 0.45 * sin(x / 90 + ribbon.phase * 2 + time * 0.2))
            }
            var band = Path()
            band.move(to: CGPoint(x: 0, y: y(0) - half(0)))
            for x in stride(from: 6.0, through: size.width, by: 6) { band.addLine(to: CGPoint(x: x, y: y(x) - half(x))) }
            for x in stride(from: size.width, through: 0, by: -6) { band.addLine(to: CGPoint(x: x, y: y(x) + half(x))) }
            band.closeSubpath()
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 7))
                layer.fill(band, with: .color(palette.mist.opacity(0.13)))
            }
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(0)))
            for x in stride(from: 4.0, through: size.width, by: 4) { line.addLine(to: CGPoint(x: x, y: y(x))) }
            context.stroke(line, with: .color(palette.mist.opacity(0.22)), lineWidth: 0.6)
        }
    }
}

/// One motif per feature, centered over the mist.
private enum BannerMotif {
    static func draw(_ step: OnboardingStep, in context: inout GraphicsContext, size: CGSize, time: Double, palette: BannerPalette) {
        let cx = size.width / 2
        switch step {
        case .record: record(&context, cx: cx, size: size, time: time, palette: palette)
        case .calendar: calendar(&context, cx: cx, size: size, time: time, palette: palette)
        case .transcription: transcription(&context, cx: cx, size: size, time: time, palette: palette)
        case .voices: voices(&context, cx: cx, size: size, time: time, palette: palette)
        case .summary: summary(&context, cx: cx, size: size, time: time, palette: palette)
        case .context: orbit(&context, cx: cx, size: size, time: time, palette: palette)
        }
    }

    /// Ripples spreading from where a copper dot meets the waveform.
    private static func record(_ context: inout GraphicsContext, cx: Double, size: CGSize, time: Double, palette: BannerPalette) {
        let center = CGPoint(x: cx, y: size.height * 0.62)
        for ring in 0..<4 {
            let progress = (time / 5 + Double(ring) / 4).truncatingRemainder(dividingBy: 1)
            let rx = 18 + progress * 120
            let ellipse = Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - rx * 0.2, width: rx * 2, height: rx * 0.4))
            context.stroke(ellipse, with: .color(palette.mint.opacity(0.5 * sin(.pi * progress))), lineWidth: 0.8)
        }
        let dot = CGPoint(x: cx, y: size.height * 0.2)
        var stem = Path()
        stem.move(to: CGPoint(x: dot.x, y: dot.y + 8))
        stem.addLine(to: center)
        context.stroke(stem, with: .color(palette.mint.opacity(0.35)), lineWidth: 0.8)
        glowingDot(&context, at: dot, radius: 7, pulse: 0.5 + 0.5 * sin(time * 2.4), color: palette.copper)
    }

    /// The arc of a day, with copper travelling along the hours.
    private static func calendar(_ context: inout GraphicsContext, cx: Double, size: CGSize, time: Double, palette: BannerPalette) {
        let center = CGPoint(x: cx, y: size.height * 0.9)
        for (radius, opacity) in [(78.0, 0.5), (60.0, 0.22)] {
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            context.stroke(arc, with: .color(palette.mint.opacity(opacity)), lineWidth: 0.8)
        }
        let travel = (time / 14).truncatingRemainder(dividingBy: 1)
        let angle = 195 + travel * 150
        for hour in stride(from: 195.0, through: 345, by: 25) {
            let point = point(on: center, radius: 78, degrees: hour)
            let lit = max(0, 1 - abs(hour - angle) / 25)
            context.fill(Path(ellipseIn: CGRect(x: point.x - 1.8, y: point.y - 1.8, width: 3.6, height: 3.6)),
                         with: .color(palette.mint.opacity(0.45 + 0.4 * lit)))
        }
        let fade = min(1, min(travel, 1 - travel) * 10)
        glowingDot(&context, at: point(on: center, radius: 78, degrees: angle), radius: 6, pulse: 0.5 + 0.5 * sin(time * 2),
                   color: palette.copper, opacity: fade)
    }

    /// A waveform that settles into lines of text.
    private static func transcription(_ context: inout GraphicsContext, cx: Double, size: CGSize, time: Double, palette: BannerPalette) {
        let start = cx - 190, settle = cx + 10
        for line in 0..<5 {
            let offset = Double(line - 2) * 7
            let base = size.height * 0.52 + offset
            let end = settle + [110, 150, 128, 168, 92][line] * (0.9 + 0.1 * sin(time * 0.9 + Double(line)))
            var path = Path()
            for x in stride(from: start, through: settle, by: 2) {
                let progress = (x - start) / (settle - start)
                let envelope = sin(.pi * min(1, progress * 1.25)) * (1 - smoothstep(0.7, 1, progress))
                let y = base + 24 * envelope * sin(x / 26 - time * 1.4 + Double(line) * 0.35) - offset * envelope * 0.6
                if x == start { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            path.addLine(to: CGPoint(x: end, y: base))
            context.stroke(path, with: .color(palette.mint.opacity(0.55)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        }
    }

    /// Two voices, mint and copper, that cross and then go their own way.
    private static func voices(_ context: inout GraphicsContext, cx: Double, size: CGSize, time: Double, palette: BannerPalette) {
        let start = cx - 200, part = cx - 10, base = size.height * 0.5
        for (voice, color) in [(1.0, palette.mint), (-1.0, palette.copper)] {
            for strand in 0..<3 {
                let shift = Double(strand - 1) * 1.8
                var path = Path()
                for x in stride(from: start, through: size.width, by: 2) {
                    let progress = min(1, max(0, (x - start) / (part - start)))
                    let crossing = sin(.pi * progress) * sin(x / 22 - time * 1.2)
                    let apart = smoothstep(part - 40, part + 50, x)
                    let y = base + voice * (16 * crossing + 22 * apart) + shift
                    if x == start { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(color.opacity(strand == 1 ? 0.65 : 0.3)), lineWidth: 0.8)
            }
        }
    }

    /// A spark rising from the ribbons.
    private static func summary(_ context: inout GraphicsContext, cx: Double, size: CGSize, time: Double, palette: BannerPalette) {
        let center = CGPoint(x: cx, y: size.height * 0.5 - 3 * sin(time * 0.8))
        let pulse = 0.5 + 0.5 * sin(time * 1.6)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 12))
            layer.fill(Path(ellipseIn: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52)),
                       with: .color(palette.mint.opacity(0.18 + 0.12 * pulse)))
        }
        context.fill(star(at: center, height: 30 + 3 * pulse, width: 18 + 2 * pulse), with: .color(palette.mint.opacity(0.85)))
        for (index, offset) in [(-58.0, -14.0), (52.0, -22.0), (34.0, 18.0)].enumerated() {
            let twinkle = max(0, sin(time * 1.3 + Double(index) * 2.1))
            context.fill(star(at: CGPoint(x: center.x + offset.0, y: center.y + offset.1), height: 8 * twinkle, width: 5 * twinkle),
                         with: .color(palette.mint.opacity(0.5 * twinkle)))
        }
    }

    /// Notes orbiting the agent.
    private static func orbit(_ context: inout GraphicsContext, cx: Double, size: CGSize, time: Double, palette: BannerPalette) {
        let center = CGPoint(x: cx, y: size.height * 0.56)
        let orbits: [(rx: Double, speed: Double, phase: Double, copper: Bool)] = [(104, 0.16, 0.6, true), (72, -0.24, 2.4, false), (42, 0.34, 4.1, false)]
        for orbit in orbits {
            let ry = orbit.rx * 0.3
            context.stroke(Path(ellipseIn: CGRect(x: center.x - orbit.rx, y: center.y - ry, width: orbit.rx * 2, height: ry * 2)),
                           with: .color(palette.mint.opacity(0.4)), lineWidth: 0.8)
            let angle = orbit.phase + time * orbit.speed
            let point = CGPoint(x: center.x + orbit.rx * cos(angle), y: center.y + ry * sin(angle))
            if orbit.copper {
                glowingDot(&context, at: point, radius: 4, pulse: 0.5 + 0.5 * sin(time * 2), color: palette.copper)
            } else {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(palette.mint.opacity(0.7)))
            }
        }
        context.fill(star(at: center, height: 16, width: 10), with: .color(palette.mint.opacity(0.85)))
    }

    private static func glowingDot(_ context: inout GraphicsContext, at point: CGPoint, radius: Double, pulse: Double, color: Color, opacity: Double = 1) {
        let glow = radius * (2 + 0.6 * pulse)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius))
            layer.fill(Path(ellipseIn: CGRect(x: point.x - glow, y: point.y - glow, width: glow * 2, height: glow * 2)),
                       with: .color(color.opacity((0.22 + 0.14 * pulse) * opacity)))
        }
        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                     with: .color(color.opacity(opacity)))
    }

    /// A four-pointed star with concave sides.
    private static func star(at center: CGPoint, height: Double, width: Double) -> Path {
        var path = Path()
        let top = CGPoint(x: center.x, y: center.y - height / 2), bottom = CGPoint(x: center.x, y: center.y + height / 2)
        let left = CGPoint(x: center.x - width / 2, y: center.y), right = CGPoint(x: center.x + width / 2, y: center.y)
        path.move(to: top)
        path.addQuadCurve(to: right, control: center)
        path.addQuadCurve(to: bottom, control: center)
        path.addQuadCurve(to: left, control: center)
        path.addQuadCurve(to: top, control: center)
        return path
    }

    private static func point(on center: CGPoint, radius: Double, degrees: Double) -> CGPoint {
        CGPoint(x: center.x + radius * cos(degrees * .pi / 180), y: center.y + radius * sin(degrees * .pi / 180))
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}
