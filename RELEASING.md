# Releasing

Local-only signing and notarization on the developer's Mac, then pushed to GitHub Releases.

## Prerequisites (one-time)

1. **Developer ID Application certificate** in your login keychain.
   Verify with `security find-identity -v -p codesigning`.
2. **`xcrun notarytool` keychain profile** named `bastion`:
   ```sh
   cp .env.signing.example .env.signing
   # Fill in APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID temporarily.
   make signing-setup
   # Then delete the three values from .env.signing; they live in the
   # keychain now.
   ```
3. **Sparkle EdDSA keypair**. Generated on first `make release`:
   ```sh
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   # Writes the private key to your keychain. The public key is read
   # automatically by _ensure-sparkle-public-key.
   ```
4. **GitHub CLI auth**: `gh auth status` shows a valid login.
5. **GitHub repo** `dbuskariol/bastion` exists with at least one
   placeholder release (so the Sparkle feed URL resolves):
   ```sh
   gh release create v0.0.0 --repo dbuskariol/bastion \
     --title v0.0.0 --notes "Placeholder for Sparkle feed bootstrap." \
     --draft=false
   ```

## Cutting a release

```sh
make release VERSION=0.1.0 PUBLISH=true
```

That runs:
1. `swift Scripts/make_app_icon.swift` — bake AppIcon.icns.
2. `make _generate_version` — pin the BUILD into `BastionVersion`.
3. `swift build -c release` — universal binaries for menu + CLI.
4. Assemble Bastion.app: install plists, copy Sparkle.framework, trim
   XPCServices (we're non-sandboxed).
5. Inject CFBundleIdentifier, version, SUFeedURL, SUPublicEDKey.
6. Inside-out codesign: Sparkle nested Mach-Os, then the framework,
   then the CLI, then the outer bundle with `--entitlements
   App/Bastion.entitlements --options runtime --timestamp`.
7. `xcrun notarytool submit` + wait + `xcrun stapler staple`.
8. Zip + DMG package, sign + notarize + staple the DMG separately.
9. Build appcast: render Markdown release notes to HTML; hydrate the
   last 10 release zips so Sparkle's generate_appcast produces a
   multi-entry feed.
10. `gh release create --draft` upload, then `gh release edit
    --draft=false` to publish.

Pre-release versions (e.g. `0.1.0-beta.1`) get `--prerelease` and stay
out of `/latest/`.

Stop after notarization with:
```sh
make release VERSION=0.1.0 PUBLISH=false
```

## Release-notes file

`make release` requires `releases/notes/<VERSION>.md` to exist. Format:

```markdown
- Headline change
- Another change
- Bug fix
```

## Failure modes

- **codesign timestamps fail** — your Apple Developer account is
  expired. Renew at https://developer.apple.com.
- **notarytool times out** — Apple's notarization service queue. Wait
  and re-run `make notarize` directly.
- **gh release create fails on duplicate tag** — the Makefile cleans up
  via `gh release delete v$VERSION --cleanup-tag` before re-creating;
  if that fails you have a stale tag — delete manually.
- **Sparkle feed URL doesn't resolve** — verify the placeholder release
  exists (Prereq 5).
