# Releasing CodexBoard

CodexBoard supports a reproducible **local preview** package. An ad-hoc signed
preview may be published only as a clearly labeled GitHub Pre-release. A stable
public release remains blocked until the signing prerequisites below are
satisfied.

## Local preview release

From a clean review of the intended changes:

```bash
./script/package_release.sh
```

The script reads the version from `Resources/Info.plist`, runs the full Swift test suite, builds and verifies the app bundle, checks its localization, icon, and legal-document assets, confirms the current signing mode, and writes:

```text
dist/release/v0.1.0/
├── CodexBoard-v0.1.0-macOS.zip
├── CodexBoard-v0.1.0-SHA256SUMS.txt
├── CodexBoard-v0.1.0-release-notes.md
└── CodexBoard-v0.1.0-release-manifest.txt
```

The manifest records the bundle identifier, app version, build number, minimum macOS version, architecture, signing mode, archive size, and SHA-256 checksum.

Verify the archive from inside its release directory so the relative filename in the checksum file resolves correctly:

```bash
cd dist/release/v0.1.0
shasum -a 256 -c CodexBoard-v0.1.0-SHA256SUMS.txt
```

## Public release prerequisites

Before publishing an artifact to general users:

1. Replace `com.local.CodexBoard` with a stable production bundle identifier owned by the publisher. Plan migration for preferences and notification authorization because those are scoped to the bundle identifier.
2. Install an Apple Developer ID Application certificate and verify it appears in:

   ```bash
   security find-identity -v -p codesigning
   ```

3. Enable the hardened runtime and sign the complete app with the Developer ID identity and timestamp.
4. Submit the ZIP or app for notarization with `notarytool`, wait for acceptance, and staple the ticket to the app.
5. Rebuild the final ZIP after stapling, then verify:

   ```bash
   codesign --verify --deep --strict --verbose=2 CodexBoard.app
   spctl --assess --type execute --verbose=4 CodexBoard.app
   xcrun stapler validate CodexBoard.app
   ```

6. Generate checksums from the final notarized archive and run a clean-machine smoke test on the oldest supported macOS version.
7. Confirm the source repository and app bundle contain `LICENSE`, `NOTICE`, and the trademark guidelines before publishing.

If the current ad-hoc artifact is uploaded, mark the GitHub Release as a
Pre-release and state prominently that the app is neither Developer ID signed
nor notarized. Do not publish it under wording that implies it is broadly
trusted by Gatekeeper.

## Versioning checklist

- Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Resources/Info.plist`.
- Add a matching section to `CHANGELOG.md`.
- Add `docs/releases/v<version>.md`.
- Confirm both README landing pages describe the actual release state.
- Run `./script/package_release.sh`.
- Inspect the generated release manifest and checksum file.
- For an ad-hoc preview: create a GitHub Pre-release and upload the ZIP,
  checksum, notes, and manifest with the trust warning intact.
- Only after successful notarization: promote a release as stable.
