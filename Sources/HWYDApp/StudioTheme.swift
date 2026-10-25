import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: "Système"; case .light: "Clair"; case .dark: "Sombre" } }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    var appearance: NSAppearance? { switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) } }
}
enum Studio {
    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
    static let background = adaptive("StudioBackground", light: 0xf4f6f5, dark: 0x1b2025)
    static let surface = adaptive("StudioSurface", light: 0xffffff, dark: 0x232a30)
    static let inset = adaptive("StudioInset", light: 0xe8eeeb, dark: 0x171c20)
    static let line = adaptive("StudioLine", light: 0xcbd5d0, dark: 0x343d44)
    static let text = adaptive("StudioText", light: 0x202b29, dark: 0xe7ecee)
    static let muted = adaptive("StudioMuted", light: 0x596b65, dark: 0x9aa8af)
    static let mint = adaptive("StudioMint", light: 0x256951, dark: 0xa5dcc8)
    static let copper = adaptive("StudioCopper", light: 0x99492f, dark: 0xe9a48c)
    static let onAccent = adaptive("StudioOnAccent", light: 0xffffff, dark: 0x171c20)
}
struct StudioButtonStyle: ButtonStyle {
    var primary = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(primary ? Studio.onAccent : Studio.text)
            .background((primary ? (destructive ? Studio.copper : Studio.mint) : Studio.surface).opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(primary ? .clear : Studio.line))
    }
}
struct Eyebrow: View {
    var text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1.5).foregroundStyle(Studio.muted) }
}
struct Badge: View {
    var text: String
    var color: Color = Studio.mint
    var body: some View { Text(text).font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 5).foregroundStyle(color).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.2))) }
}
struct WaveformView: View {
    var level: Float = 0
    var decorative = false
    var progress: Double = 0
    var color: Color = Studio.mint
    var body: some View {
        GeometryReader { geometry in
            let count = max(8, Int(geometry.size.width / 7))
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<count, id: \.self) { i in
                    let pattern = Double((i * 17 + i * i * 3) % 80) / 100 + 0.12
                    let height = decorative ? pattern : max(0.04, pattern * Double(level))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(progress > 0 && Double(i) / Double(count) < progress ? 1 : decorative ? 0.48 : 0.8))
                        .frame(maxWidth: .infinity).frame(height: max(2, geometry.size.height * height))
                }
            }.frame(height: geometry.size.height)
        }.accessibilityHidden(true)
    }
}
struct EmptyPanel: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Studio.mint)
            Text(title).font(.system(size: 20, weight: .medium)).foregroundStyle(Studio.text)
            Text(detail).font(.system(size: 13)).foregroundStyle(Studio.muted).multilineTextAlignment(.center).lineSpacing(5).frame(maxWidth: 380)
        }.frame(maxWidth: .infinity).padding(.vertical, 52)
    }
}
