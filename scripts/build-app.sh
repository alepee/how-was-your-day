#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
configuration="${1:-debug}"
# A persistent certificate anchors TCC identity across rebuilds. Never silently use ad hoc.
sign_identity="${SIGN_IDENTITY:-No Bleeding Eyes Code Signing}"
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
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER must be numeric" >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$app/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -Rf Resources/Licenses "$app/Contents/Resources/"
for bundle in "$bin_path"/*.bundle; do
    [[ ! -d "$bundle" ]] || cp -R "$bundle" "$app/Contents/Resources/"
done
timestamp_flag="--timestamp=none"
[[ "${SIGN_TIMESTAMP:-0}" != "1" ]] || timestamp_flag="--timestamp"
codesign --force "${timestamp_flag}" --identifier dev.lepee.hwyd.pipeline --sign "$sign_identity" "$app/Contents/Helpers/hwyd-pipeline"
codesign --force "${timestamp_flag}" --identifier dev.lepee.hwyd.mcp --sign "$sign_identity" "$app/Contents/Helpers/hwyd-mcp"
codesign --force "${timestamp_flag}" --identifier dev.lepee.hwyd --options runtime --entitlements Resources/HWYD.entitlements --sign "$sign_identity" "$app"
printf 'App: %s/%s\n' "$PWD" "$app"
