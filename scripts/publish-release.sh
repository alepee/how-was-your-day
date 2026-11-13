#!/bin/bash
# Publish locally signed assets, then update the Homebrew tap using gh authentication.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?Usage: scripts/publish-release.sh x.y.z release-notes.md}"
notes="${2:?Release notes file required}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -f "$notes" ]] || exit 1
[[ -z "$(git status --porcelain)" ]] || { echo "Commit changes before releasing." >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon release host required.' >&2; exit 1; }
repo=alepee/how-was-your-day
tag="v$version"
gh auth status >/dev/null
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "Release $tag exists; refusing to overwrite artifacts." >&2; exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || [[ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]]; then
    echo "Tag $tag already exists. If a previous run failed after pushing it, see docs/distribution.md." >&2; exit 1
fi
# Public releases are signed with Developer ID and notarized. NOTARY_PROFILE names a notarytool
# keychain profile created once with `xcrun notarytool store-credentials`.
identity="${SIGN_IDENTITY:-Developer ID Application}"
profile="${NOTARY_PROFILE:-apple-notary}"
# SIGN_IDENTITY may be a name prefix or a certificate SHA-1. After a renewal, two Developer ID
# certificates match the prefix and codesign refuses an ambiguous name: pass the SHA-1 then.
matches="$(security find-identity -v -p codesigning | grep -F -- "$identity" || true)"
[[ -n "$matches" ]] || { echo "Signing identity \"$identity\" missing from the keychain." >&2; exit 1; }
if [[ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" -gt 1 ]]; then
    echo "Several identities match \"$identity\". Set SIGN_IDENTITY to one SHA-1:" >&2; printf '%s\n' "$matches" >&2; exit 1
fi
notarize=0
if [[ "$matches" == *'"Developer ID Application'* ]]; then
    xcrun notarytool history --keychain-profile "$profile" >/dev/null || { echo "Notary profile \"$profile\" unavailable. See docs/distribution.md." >&2; exit 1; }
    notarize=1
elif [[ "${HWYD_ALLOW_UNNOTARIZED:-0}" != "1" ]]; then
    echo "Releases require Developer ID and notarization. Set HWYD_ALLOW_UNNOTARIZED=1 to publish without." >&2; exit 1
fi
# Updates are signed with the EdDSA key that `generate_keys` stored in the login keychain. Its
# public half must match the one built into the app, or installed copies reject the update.
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift package resolve >/dev/null
sparkle_bin=.build/artifacts/sparkle/Sparkle/bin
keychain_key="$("$sparkle_bin/generate_keys" -p 2>/dev/null || true)"
[[ -n "$keychain_key" && "$keychain_key" == "$(tr -d '[:space:]' < Resources/SparklePublicKey.txt)" ]] || {
    echo "Sparkle signing key missing from the keychain or different from Resources/SparklePublicKey.txt. See docs/distribution.md." >&2; exit 1; }
app='build/release/How Was Your Day.app'
build_number="$(git rev-list --count HEAD)"
SIGN_IDENTITY="$identity" SIGN_TIMESTAMP=1 VERSION="$version" BUILD_NUMBER="$build_number" HWYD_APP_OUTPUT="$app" scripts/build-app.sh release
if [[ "$notarize" == 1 ]]; then
    scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
    submission="$scratch/HowWasYourDay.zip"
    ditto -c -k --keepParent "$app" "$submission"
    xcrun notarytool submit "$submission" --keychain-profile "$profile" --wait
    xcrun stapler staple "$app"
fi
scripts/package.sh
if [[ "$notarize" == 1 ]]; then
    dmg=build/release/HowWasYourDay.dmg
    codesign --force --timestamp --sign "$identity" "$dmg"
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg"
    spctl --assess --type execute -v "$app"
    (cd build/release && shasum -a 256 HowWasYourDay.dmg HowWasYourDay.zip > SHA256SUMS)
fi
# The ZIP holds the stapled app: it is the archive Sparkle downloads.
python3 scripts/make-appcast.py "$version" "$build_number" build/release/HowWasYourDay.zip \
    "$("$sparkle_bin/sign_update" build/release/HowWasYourDay.zip)" build/release/appcast.xml
git tag "$tag"
git push origin HEAD "$tag"
gh release create "$tag" --repo "$repo" --verify-tag --title "$tag" --notes-file "$notes" \
    build/release/HowWasYourDay.dmg build/release/HowWasYourDay.zip build/release/SHA256SUMS build/release/appcast.xml
python3 scripts/update-homebrew.py "$version" build/release/HowWasYourDay.dmg
