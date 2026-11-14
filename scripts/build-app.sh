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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin_path/HWYD" "$app/Contents/MacOS/HWYD"
# Sparkle is a dynamic framework: embed it and load it from the bundle, never from the build tree.
rm -rf "$app/Contents/Frameworks/Sparkle.framework"
ditto "$bin_path/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
# The app is not sandboxed: Sparkle's XPC services are not needed (Sparkle documentation).
rm -rf "$app/Contents/Frameworks/Sparkle.framework/XPCServices" "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
while read -r rpath; do
    install_name_tool -delete_rpath "$rpath" "$app/Contents/MacOS/HWYD"
done < <(otool -l "$app/Contents/MacOS/HWYD" | awk '/LC_RPATH/ { getline; getline; print $2 }' | grep '^/' || true)
otool -l "$app/Contents/MacOS/HWYD" | grep -q '@executable_path/../Frameworks' || install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/HWYD"
cp "$bin_path/hwyd-pipeline" "$app/Contents/Helpers/hwyd-pipeline"
cp "$bin_path/hwyd-mcp" "$app/Contents/Helpers/hwyd-mcp"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
    version="${VERSION#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be x.y.z" >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER must be numeric" >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$app/Contents/Info.plist"
fi
# Only release builds (VERSION set) check for updates, so a development build is never replaced by
# the public release. HWYD_UPDATE_FEED and HWYD_UPDATE_PUBLIC_KEY point a build at a test appcast.
if [[ -n "${VERSION:-}" || -n "${HWYD_UPDATE_FEED:-}" ]]; then
    public_key="${HWYD_UPDATE_PUBLIC_KEY:-$(tr -d '[:space:]' < Resources/SparklePublicKey.txt 2>/dev/null || true)}"
    [[ -n "$public_key" ]] || { echo "Resources/SparklePublicKey.txt is missing. See docs/distribution.md." >&2; exit 1; }
    feed="${HWYD_UPDATE_FEED:-https://github.com/alepee/how-was-your-day/releases/latest/download/appcast.xml}"
    [[ "$feed" == https://* || "$feed" == http://127.0.0.1:* || "$feed" == http://localhost:* ]] || { echo "HWYD_UPDATE_FEED must be https (or a local test server)." >&2; exit 1; }
    plist="$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed" -c "Add :SUPublicEDKey string $public_key" "$plist"
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
sparkle="$app/Contents/Frameworks/Sparkle.framework"
codesign --force "${timestamp_flag}" --options runtime --sign "$sign_identity" "$sparkle/Versions/B/Autoupdate"
codesign --force "${timestamp_flag}" --options runtime --sign "$sign_identity" "$sparkle/Versions/B/Updater.app"
codesign --force "${timestamp_flag}" --options runtime --sign "$sign_identity" "$sparkle"
entitlements=Resources/HWYD.entitlements
# Under the hardened runtime, library validation only loads code signed by the same team. Ad hoc
# signatures have no team, so an ad hoc app cannot load its own ad hoc Sparkle. Isolated ad hoc
# builds relax library validation; builds with a persistent identity keep it.
if [[ "$sign_identity" == "-" ]]; then
    entitlements="$(mktemp -t hwyd-adhoc-entitlements)"
    trap 'rm -f "$entitlements"' EXIT
    cp Resources/HWYD.entitlements "$entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$entitlements" >/dev/null
fi
codesign --force "${timestamp_flag}" --identifier dev.lepee.hwyd --options runtime --entitlements "$entitlements" --sign "$sign_identity" "$app"
printf 'App: %s/%s\n' "$PWD" "$app"
