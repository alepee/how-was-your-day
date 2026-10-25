# Distribution

HWYD follows the same distribution path as No Bleeding Eyes: a signed app in a DMG and ZIP on GitHub Releases, plus a versioned cask in `alepee/homebrew-tap`.

## Requirements

- Apple Silicon build host, Xcode with Swift 6.2+ and macOS 26+ SDK.
- A persistent code signing certificate in the local keychain.
- GitHub CLI authentication with write access to `alepee/how-was-your-day` and `alepee/homebrew-tap`.
- A clean, committed working tree and release notes in English.

The signing private key stays on the maintainer's Mac. CI uses ad hoc signing for disposable artifacts only. No signing credentials or tap deploy keys are uploaded to GitHub by these scripts.

## Publish

Run the relevant tests first, then:

```sh
scripts/publish-release.sh 0.1.0 docs/releases/0.1.0.md
```

The script builds in `build/release`, leaving the running development app untouched. It sets the bundle version, verifies the signature, creates a DMG with an Applications shortcut, a ZIP and `SHA256SUMS`, pushes a tag and publishes the release. Finally it updates only the HWYD cask through GitHub's Contents API, with a SHA check to avoid overwriting concurrent edits.

The Homebrew update verifies that the published DMG digest matches the local file. If the release succeeds but the tap update fails, retry only:

```sh
python3 scripts/update-homebrew.py 0.1.0 build/release/HowWasYourDay.dmg
```

Existing releases are never overwritten. If publishing fails after the tag was pushed, inspect GitHub before retrying; publish the existing tag and artifacts with `gh release create --verify-tag`, then update the tap. Do not force-move a published tag.

## Signing status

Initial releases use a persistent self-signed certificate, like No Bleeding Eyes. They are not Apple-notarized. Gatekeeper may block the first launch; use the macOS Privacy & Security interface. No script or cask disables quarantine or security checks.

Developer ID signing and notarization remain future work. The build supports `SIGN_IDENTITY` and `SIGN_TIMESTAMP=1`, but packaging does not submit artifacts for notarization.

## CI and public files

GitHub Actions runs on `macos-26` (Apple Silicon), runs core/pipeline tests and synthetic app checks, and publishes a short-lived CI ZIP. These artifacts are not user releases and must not be used to update the cask.

Build directories, audio, databases, signing keys and private calibration reports are ignored. The original architecture documents are retained in French. New public documentation and release notes are written in English; app localization is unchanged.
