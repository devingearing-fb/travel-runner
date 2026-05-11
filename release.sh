#!/bin/bash
set -euo pipefail

# ── travel-runner release script ───────────────────────────────────────────
# Builds, signs with Developer ID, notarizes, staples, generates Sparkle
# appcast, and creates a GitHub Release.
#
# Prerequisites:
#   - Apple Developer ID Application certificate installed in Keychain
#   - Notarization credentials stored: xcrun notarytool store-credentials "travel-runner-notarize" ...
#   - Sparkle EdDSA private key in Keychain (from generate_keys)
#   - gh CLI authenticated
#
# Usage:
#   ./release.sh 0.2.0             Build + sign + notarize + release
#   ./release.sh 0.2.0 --draft     Same but creates a draft release
# ────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="TravelRunner"
APP_BUNDLE="$APP_NAME.app"
BUNDLE_ID="ai.fastbreak.travel-runner"

# ── Update these after initial setup ───────────────────────────────────────
DEVELOPER_ID="${DEVELOPER_ID:-B614A6CBF6DEE52D65D2E4B7BF7C1312E04E39AF}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-travel-runner-notarize}"
GITHUB_REPO="${GITHUB_REPO:-devingearing-fb/travel-runner}"
EDDSA_PUBLIC_KEY="${EDDSA_PUBLIC_KEY:-Z7c9sySgE0b4RH8NOK405c3mv/7w4NKMrs3DJDCxHsU=}"
# ────────────────────────────────────────────────────────────────────────────

VERSION="${1:?Usage: ./release.sh <version> [--draft]}"
DRAFT=false
[[ "${2:-}" == "--draft" ]] && DRAFT=true

BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
ZIP_NAME="TravelRunner-${VERSION}.zip"

echo ""
echo "  ╔════════════════════════════════════╗"
echo "  ║   travel-runner release v$VERSION"
echo "  ╚════════════════════════════════════╝"
echo ""

# ── 1. Build ────────────────────────────────────────────────────────────────
echo "  [1/7] Building release binary..."
swift build -c release 2>&1 | while IFS= read -r line; do echo "    $line"; done

if [ ! -f ".build/release/$APP_NAME" ]; then
    echo "  ✗ Build failed"
    exit 1
fi
echo "  ✓ Build complete"

# ── 2. Package .app ─────────────────────────────────────────────────────────
echo "  [2/7] Packaging $APP_BUNDLE..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

[ -f "AppIcon.icns" ] && cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"

RESOURCE_BUNDLE=".build/release/${APP_NAME}_${APP_NAME}.bundle"
[ -d "$RESOURCE_BUNDLE" ] && cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"

# Copy Sparkle framework (use ditto to avoid ._AppleDouble files)
SPARKLE_FW=$(find .build/artifacts -name "Sparkle.framework" -type d 2>/dev/null | head -1)
if [ -n "$SPARKLE_FW" ] && [ -d "$SPARKLE_FW" ]; then
    ditto "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath @executable_path/../Frameworks \
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

# Write Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Travel Runner</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>SUFeedURL</key>
    <string>https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>$EDDSA_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAllowsAutomaticUpdates</key>
    <true/>
</dict>
</plist>
PLIST

echo "  ✓ App packaged"

# ── 3. Codesign ─────────────────────────────────────────────────────────────
echo "  [3/7] Signing with Developer ID..."

# Sign all Sparkle components inside-out (binaries, XPC services, apps, framework)
SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    find "$SPARKLE" -type f -perm +111 -o -name "*.dylib" | while read binary; do
        codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$binary"
    done
    for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do
        [ -d "$xpc" ] && codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$xpc"
    done
    for app in "$SPARKLE"/Versions/B/*.app; do
        [ -d "$app" ] && codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$app"
    done
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$SPARKLE"
fi

codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
    --entitlements TravelRunner.entitlements \
    "$APP_BUNDLE"

codesign --verify --deep --strict "$APP_BUNDLE"
echo "  ✓ Signed and verified"

# ── 4. ZIP for notarization ─────────────────────────────────────────────────
echo "  [4/7] Creating ZIP..."
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"

# ── 5. Notarize ─────────────────────────────────────────────────────────────
echo "  [5/7] Notarizing (this may take a few minutes)..."
xcrun notarytool submit "$ZIP_NAME" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait
echo "  ✓ Notarized"

# ── 6. Staple ───────────────────────────────────────────────────────────────
echo "  [6/7] Stapling ticket..."
xcrun stapler staple "$APP_BUNDLE"

# Re-create ZIP with stapled ticket
rm -f "$ZIP_NAME"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"
echo "  ✓ Stapled"

# ── 7. Sparkle appcast + GitHub Release ─────────────────────────────────────
echo "  [7/7] Generating appcast and creating release..."

# Sign the ZIP with Sparkle's EdDSA key
SPARKLE_SIGN=$(find .build/artifacts -name "sign_update" -type f 2>/dev/null | head -1)
if [ -n "$SPARKLE_SIGN" ] && [ -x "$SPARKLE_SIGN" ]; then
    SIGNATURE=$("$SPARKLE_SIGN" "$ZIP_NAME" 2>&1 || true)
    EDDSA_SIGNATURE=$(echo "$SIGNATURE" | grep -o 'edSignature="[^"]*"' | sed 's/edSignature="//;s/"//' || echo "")
    LENGTH=$(echo "$SIGNATURE" | grep -o 'length="[^"]*"' | sed 's/length="//;s/"//' || stat -f%z "$ZIP_NAME")
else
    echo "  ⚠ sign_update not found — appcast signature will be empty"
    EDDSA_SIGNATURE=""
    LENGTH=$(stat -f%z "$ZIP_NAME")
fi

DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v${VERSION}/${ZIP_NAME}"
PUB_DATE=$(date -R)

cat > appcast.xml << APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Travel Runner Updates</title>
    <link>https://github.com/$GITHUB_REPO</link>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="$DOWNLOAD_URL"
        length="$LENGTH"
        type="application/octet-stream"
        sparkle:edSignature="$EDDSA_SIGNATURE"
      />
    </item>
  </channel>
</rss>
APPCAST

# Create GitHub Release
DRAFT_FLAG=""
$DRAFT && DRAFT_FLAG="--draft"

gh release create "v${VERSION}" \
    "$ZIP_NAME" \
    appcast.xml \
    --repo "$GITHUB_REPO" \
    --title "Travel Runner v${VERSION}" \
    --generate-notes \
    $DRAFT_FLAG

# Cleanup
rm -f appcast.xml

echo ""
echo "  ╔═══════════════════════════════════════════════════════╗"
echo "  ║  Release v${VERSION} complete!                             ║"
echo "  ║  https://github.com/$GITHUB_REPO/releases  ║"
echo "  ╚═══════════════════════════════════════════════════════╝"
echo ""
