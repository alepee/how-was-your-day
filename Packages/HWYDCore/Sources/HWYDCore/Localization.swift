import Foundation

/// Where user-facing strings of HWYDCore and the helpers are looked up.
///
/// The String Catalog `Resources/Localizable.xcstrings` is compiled by `scripts/build-app.sh`
/// into `Contents/Resources/{fr,en}.lproj` of the app. HWYDCore strings use
/// `String(localized: "…", bundle: .hwyd)`:
/// - in the app, `.hwyd` is `Bundle.main`, so SwiftUI and HWYDCore follow the same language;
/// - in a helper (`Contents/Helpers/hwyd-pipeline`, `hwyd-mcp`), `Bundle.main` is the helper
///   directory, so `.hwyd` is the app's `.lproj` matching `HWYD_LOCALIZATION` (set by the app on
///   its child processes) or the user's preferred languages;
/// - elsewhere (tests, `swift run`), no catalog is found and the French source text is returned.
public enum HWYDLocalization {
    /// Environment variable the app sets on its helpers so they answer in the app's language.
    public static let environmentKey = "HWYD_LOCALIZATION"

    /// The localization the app resolved for itself, passed to child processes.
    /// In a helper, the language the app passed; `Bundle.hwyd` is then a single `.lproj`.
    public static var current: String {
        if Bundle.main.bundleURL.pathExtension != "app", let passed = ProcessInfo.processInfo.environment[environmentKey], !passed.isEmpty { return passed }
        // Without the catalog (tests, `swift run`), strings are the French source text: so is the language.
        guard Bundle.hwyd.path(forResource: "Localizable", ofType: "strings") != nil else { return "fr" }
        return Bundle.hwyd.preferredLocalizations.first ?? Bundle.hwyd.developmentLocalization ?? "fr"
    }

    static func resolve(main: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bundle {
        if main.bundleURL.pathExtension == "app" { return main }
        guard let executable = main.executableURL?.resolvingSymlinksInPath() else { return main }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", let appBundle = Bundle(url: app) else { return main }
        let requested = environment[environmentKey].map { [$0] } ?? Locale.preferredLanguages
        let language = Bundle.preferredLocalizations(from: appBundle.localizations, forPreferences: requested).first
            ?? appBundle.developmentLocalization ?? "fr"
        return appBundle.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? appBundle
    }
}

extension Bundle {
    /// Bundle holding the compiled String Catalog for HWYDCore and helper strings.
    public static let hwyd: Bundle = HWYDLocalization.resolve()
}
