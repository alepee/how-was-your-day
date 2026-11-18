#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
configuration="${1:-debug}"
# A persistent certificate anchors TCC identity across rebuilds. Never silently use ad hoc.
sign_identity="${SIGN_IDENTITY:-Apple Development}"
if [[ "$sign_identity" == "-" && "${HWYD_ALLOW_ADHOC:-0}" != "1" ]]; then
    echo "Ad hoc signing requires HWYD_ALLOW_ADHOC=1 (isolated tests only)." >&2
    exit 1
fi
if [[ "$sign_identity" != "-" ]] && ! security find-identity -p codesigning | grep -F -- "$sign_identity" >/dev/null; then
    echo "Persistent signing identity missing. Set SIGN_IDENTITY to a code-signing certificate in your keychain." >&2
    exit 1
fi
swift build -c "$configuration"
bin_path="$(swift build -c "$configuration" --show-bin-path)"
app="${HWYD_APP_OUTPUT:-build/How Was Your Day.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin_path/HWYD" "$app/Contents/MacOS/HWYD"
cp "$bin_path/hwyd-pipeline" "$app/Contents/Helpers/hwyd-pipeline"
cp "$bin_path/hwyd-mcp" "$app/Contents/Helpers/hwyd-mcp"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
    version="${VERSION#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be x.y.z" >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
    display_version="$version"
else
    # Development builds show the commit they come from, not the placeholder version of Info.plist.
    display_version="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)-dev"
fi
/usr/libexec/PlistBuddy -c "Add :HWYDDisplayVersion string $display_version" "$app/Contents/Info.plist"
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER must be numeric" >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$app/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -Rf Resources/Licenses "$app/Contents/Resources/"
# String Catalogs are the source of truth for UI text. SwiftPM does not compile them for this
# layout, so they become fr.lproj and en.lproj here. HWYDCore and the helpers resolve them too.
rm -rf "$app/Contents/Resources/"*.lproj
for catalog in Resources/Localizable.xcstrings Resources/InfoPlist.xcstrings; do
    xcrun xcstringstool compile "$catalog" --output-directory "$app/Contents/Resources"
done
for bundle in "$bin_path"/*.bundle; do
    [[ ! -d "$bundle" ]] || cp -R "$bundle" "$app/Contents/Resources/"
done
timestamp_flag="--timestamp=none"
[[ "${SIGN_TIMESTAMP:-0}" != "1" ]] || timestamp_flag="--timestamp"
codesign --force "${timestamp_flag}" --identifier dev.lepee.hwyd.pipeline --options runtime --sign "$sign_identity" "$app/Contents/Helpers/hwyd-pipeline"
codesign --force "${timestamp_flag}" --identifier dev.lepee.hwyd.mcp --options runtime --sign "$sign_identity" "$app/Contents/Helpers/hwyd-mcp"
codesign --force "${timestamp_flag}" --identifier dev.lepee.hwyd --options runtime --entitlements Resources/HWYD.entitlements --sign "$sign_identity" "$app"
printf 'App: %s/%s\n' "$PWD" "$app"
