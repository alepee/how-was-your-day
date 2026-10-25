#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${HWYD_APP_OUTPUT:-build/release/How Was Your Day.app}"
output="${HWYD_RELEASE_DIR:-build/release}"
[[ -d "$app" ]] || { echo "Missing app: $app" >&2; exit 1; }
codesign --verify --deep --strict "$app"
# Public releases must retain a persistent signing identity.
if codesign -dv "$app" 2>&1 | grep -q 'Signature=adhoc'; then
    echo "Refusing to package an ad hoc signed app as a release." >&2; exit 1
fi
mkdir -p "$output"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/How Was Your Day.app"
ln -s /Applications "$staging/Applications"
hdiutil create -ov -volname 'How Was Your Day' -srcfolder "$staging" -fs HFS+ -format UDZO "$output/HowWasYourDay.dmg"
ditto -c -k --keepParent "$app" "$output/HowWasYourDay.zip"
(cd "$output" && shasum -a 256 HowWasYourDay.dmg HowWasYourDay.zip > SHA256SUMS)
printf 'Release artifacts: %s\n' "$output"
