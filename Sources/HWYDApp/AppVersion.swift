import Foundation

/// Version shown to the user. Release builds carry x.y.z; development builds carry `<sha>-dev`
/// (written by scripts/build-app.sh), so the Info.plist placeholder never reaches the UI.
enum AppVersion {
    static let display: String = (Bundle.main.object(forInfoDictionaryKey: "HWYDDisplayVersion")
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")) as? String ?? "dev" // l10n:ignore
}
