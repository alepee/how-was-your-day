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
VERSION="$version" BUILD_NUMBER="$(git rev-list --count HEAD)" HWYD_APP_OUTPUT='build/release/How Was Your Day.app' scripts/build-app.sh release
scripts/package.sh
git tag "$tag"
git push origin HEAD "$tag"
gh release create "$tag" --repo "$repo" --verify-tag --title "$tag" --notes-file "$notes" \
    build/release/HowWasYourDay.dmg build/release/HowWasYourDay.zip build/release/SHA256SUMS
python3 scripts/update-homebrew.py "$version" build/release/HowWasYourDay.dmg
