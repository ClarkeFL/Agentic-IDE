# Release setup (one-time)

This walks through the one-time setup needed before tag pushes start producing
auto-updating Releases on GitHub.

## 1. Create the GitHub repo

```bash
gh repo create Agentic-IDE --source . --private --remote origin
git push -u origin main
```

(Public is fine too — Sparkle's update channel is just static files.)

## 2. Generate Sparkle's Ed25519 keys

You only do this once per app, ever. The private key signs every release; the
public key is embedded in the app and verifies signatures at install time.

After running `xcodebuild -resolvePackageDependencies`, Sparkle's CLI tools are
in your DerivedData. Find them and run `generate_keys`:

```bash
SPARKLE_TOOLS=$(find ~/Library/Developer/Xcode/DerivedData -name 'generate_keys' -type f 2>/dev/null | head -1)
"$SPARKLE_TOOLS"
```

That prints something like:

```
Generated a new keypair! …
Public key: <BASE64_PUB_KEY>
The private key has been stored in your Keychain. To export it for CI use:
    generate_keys -x ~/Desktop/sparkle_private_key
```

### Save the public key in the app

Open `AgenticIDE.xcodeproj/project.pbxproj` and replace the placeholder string:

```
INFOPLIST_KEY_SUPublicEDKey = "REPLACE_WITH_YOUR_PUBLIC_KEY";
```

with the `Public key:` value from `generate_keys`.

### Save the private key as a GitHub secret

```bash
"$SPARKLE_TOOLS" -x /tmp/sparkle_private_key
gh secret set SPARKLE_PRIVATE_KEY < /tmp/sparkle_private_key
rm /tmp/sparkle_private_key
```

(If you ever leak the private key, regenerate with `generate_keys` and ship a
new public key in the next app version. Old installs won't be able to update,
so you'd need to ask users to re-download.)

## 3. Update the feed URL

Edit `INFOPLIST_KEY_SUFeedURL` in `project.pbxproj`. With your repo at
`https://github.com/USER/REPO`, set it to:

```
INFOPLIST_KEY_SUFeedURL = "https://raw.githubusercontent.com/USER/REPO/main/appcast.xml";
```

The `raw.githubusercontent.com` host serves the file directly with no caching
headaches.

## 4. Cut your first release

```bash
git tag v0.1.0
git push origin v0.1.0
```

The `Release` workflow (`.github/workflows/release.yml`) will:

1. Build Release on a `macos-14` runner.
2. Ad-hoc sign the `.app` (`codesign --sign -`).
3. Zip the `.app`.
4. Sign the zip with the Sparkle private key.
5. Update `appcast.xml` and push it back to `main`.
6. Create a GitHub Release with the zip attached.

## 5. Install the first build

Download the zip from the Release page, unzip, drag `AgenticIDE.app` into
`/Applications`. First launch will warn about an unidentified developer (no
Apple Developer ID) — right-click the app, choose Open, confirm once. macOS
remembers and won't ask again.

## 6. Subsequent releases

Just bump the tag:

```bash
git tag v0.2.0
git push origin v0.2.0
```

The next time the installed app's Sparkle scheduler hits the feed (or the user
clicks **AgenticIDE → Check for Updates…**) it will download, verify, install
the new version, and relaunch.

## Notes on the ad-hoc signing path

Without a paid Apple Developer account we can't notarise. macOS Gatekeeper will
still let users open the app via right-click → Open on first launch. Sparkle
itself still works because its signature scheme is independent of Apple's —
it's the Ed25519 key you generated in step 2.

If you ever upgrade to a paid account, swap `CODE_SIGN_IDENTITY=-` in the
workflow for your Developer ID Application identity and add a `xcrun notarytool`
step before zipping.
