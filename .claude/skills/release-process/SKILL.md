---
name: release-process
description: How to build, sign, notarize, and release travel-runner. Use when making changes that need to ship to teammates, doing a release, or debugging update issues.
trigger: when the user asks to release, ship, deploy, build for distribution, push an update, or fix update/signing issues
---

# travel-runner Release Process

## Quick Release

To ship a new version after making code changes:

```bash
cd "/Users/devingearing/Documents/Codebases/TRAVEL BOOKING/travel-runner"
git add -A && git commit -m "description" && git push
./release.sh 0.X.Y
```

`release.sh` handles everything: build → sign → notarize → staple → Sparkle appcast → GitHub Release.

Users on previous versions get the update automatically via Sparkle (checks every 24h), or manually via right-click → Check for Updates.

## Critical Details

### Signing Identity

- **Certificate:** Developer ID Application: Devin Gearing (JR7Z6LSD98)
- **SHA-1 hash:** `B614A6CBF6DEE52D65D2E4B7BF7C1312E04E39AF` (used in release.sh to avoid ambiguity — there's a duplicate cert in the System keychain)
- **Notarization profile:** `travel-runner-notarize` (stored in Keychain, Apple ID: devin.e.gearing@gmail.com)
- **Sparkle EdDSA public key:** `Z7c9sySgE0b4RH8NOK405c3mv/7w4NKMrs3DJDCxHsU=`

### Version Numbering

- `CFBundleShortVersionString` = semantic version (e.g., `0.1.5`)
- `CFBundleVersion` = build number in `YYYYMMDDHHMMSS` format (e.g., `20260510215000`)
- **NEVER** use `date +%s` (Unix timestamp) for build numbers — produces numbers like `1778463926` which are higher than any `YYYYMMDD` format and break Sparkle update comparisons
- Both `build.sh` and `release.sh` use `date +%Y%m%d%H%M%S`

### GitHub Releases

- **Repo:** `devingearing-fb/travel-runner` (public, required for Sparkle to fetch appcast)
- **Appcast URL:** `https://github.com/devingearing-fb/travel-runner/releases/latest/download/appcast.xml`
- Each release has two assets: `TravelRunner-{version}.zip` and `appcast.xml`

## Pitfalls We've Hit (Don't Repeat These)

### 1. Sparkle framework ._AppleDouble files
**Problem:** `cp -R` creates `._` resource fork files inside Sparkle.framework, which breaks the code seal ("unsealed contents present in the root directory").
**Fix:** Always use `ditto` instead of `cp -R` when copying Sparkle.framework. Both `build.sh` and `release.sh` already use `ditto`.

### 2. Unsigned XPC services inside Sparkle
**Problem:** Notarization rejects if `Sparkle.framework/Versions/B/XPCServices/Downloader.xpc` and `Installer.xpc` aren't signed with Developer ID.
**Fix:** `release.sh` signs ALL executables inside Sparkle using `find` + `codesign`, then signs XPC bundles, app bundles, the framework, and finally the main app (inside-out order).

### 3. EdDSA signature must match the FINAL zip
**Problem:** If you sign the zip before stapling, the stapled zip has different contents and the signature won't verify ("improperly signed" error in Sparkle).
**Fix:** `release.sh` staples first, re-creates the zip, THEN signs it with `sign_update`. The order in release.sh is correct — don't change it.

### 4. Dev builds vs release builds must use same signing identity
**Problem:** If the installed app is ad-hoc signed but the update is Developer ID signed, Sparkle rejects the update ("improperly signed").
**Fix:** For local testing of updates, always install the release build: `rm -rf /Applications/TravelRunner.app && cp -R TravelRunner.app /Applications/`. The release script produces the app at `./TravelRunner.app`.

### 5. Ambiguous signing identity
**Problem:** There's a duplicate Developer ID cert in the System keychain. Using the cert name causes "ambiguous" errors.
**Fix:** `release.sh` uses the SHA-1 hash (`B614A6CBF6DEE52D65D2E4B7BF7C1312E04E39AF`) instead of the name.

### 6. First install is always manual
Sparkle can't update an app that doesn't have Sparkle. The very first install on a new machine must be done by sending the zip directly. After that, all updates are automatic.

## Installing Locally After a Release

```bash
pkill -x TravelRunner 2>/dev/null; sleep 1
rm -rf /Applications/TravelRunner.app
cp -R TravelRunner.app /Applications/
open /Applications/TravelRunner.app
```

The `TravelRunner.app` in the project directory after running `release.sh` is the signed+notarized+stapled build — it's identical to what's in the GitHub Release zip.

## Dev Builds (build.sh)

For local development (not distribution):

```bash
./build.sh          # Build TravelRunner.app
./build.sh --run    # Build + launch
./build.sh --install  # Build + copy to /Applications
```

Dev builds are ad-hoc signed. They work on your machine but NOT on teammates' machines and will NOT pass Sparkle update verification. Always use `release.sh` for distribution.

## Stripe is Optional

Stripe CLI is not required. If a teammate doesn't have it:
- Preflight shows a warning (orange), not a failure
- Startup skips Stripe (shows SKIPPED in gray)
- Everything else works normally

## OrbStack / Docker Detection

The app auto-detects OrbStack vs Docker Desktop by checking for `/Applications/OrbStack.app`. All UI text, preflight checks, and fix suggestions use the correct name. If the container runtime isn't running at startup, the app tries to launch it automatically and waits up to 20 seconds.
