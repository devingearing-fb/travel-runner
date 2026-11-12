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
#   FLAVOR=hackathon ./release.sh 1.0.0   Release Travel Runner Hackathon
#
# The two apps release to the same repository. The standard app reads the appcast of
# the release that GitHub marks as latest. A hackathon release is never marked as
# latest (tag hackathon-v<version>), and its app reads the appcast of the fixed
# release "hackathon-appcast", which each hackathon release replaces.
#
# The script first makes sure that the release can finish (signing identity, notary
# access, GitHub access, a clean tree that is on the remote), then runs the tests.
# SKIP_TESTS=1 skips the tests.
# ────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="TravelRunner"
# FLAVOR=hackathon makes the second app from the same source: Travel Runner Hackathon,
# for fb-travel-monolith-hackathon. It has its own bundle ID, icon and update feed.
FLAVOR="${FLAVOR:-standard}"
case "$FLAVOR" in
    standard)
        PRODUCT_NAME="TravelRunner"
        DISPLAY_NAME="Travel Runner"
        BUNDLE_ID="ai.fastbreak.travel-runner"
        ICON_FILE="AppIcon.icns"
        ;;
    hackathon)
        PRODUCT_NAME="TravelRunnerHackathon"
        DISPLAY_NAME="Travel Runner Hackathon"
        BUNDLE_ID="ai.fastbreak.travel-runner-hackathon"
        ICON_FILE="AppIcon-hackathon.icns"
        ;;
    *)
        echo "  ✗ Unknown FLAVOR '$FLAVOR' (standard or hackathon)"
        exit 1
        ;;
esac
APP_BUNDLE="$PRODUCT_NAME.app"

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
ZIP_NAME="${PRODUCT_NAME}-${VERSION}.zip"
FEED_TAG="hackathon-appcast"
if [ "$FLAVOR" = "hackathon" ]; then
    TAG="hackathon-v${VERSION}"
    FEED_URL="https://github.com/$GITHUB_REPO/releases/download/$FEED_TAG/appcast.xml"
else
    TAG="v${VERSION}"
    FEED_URL="https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"
fi

echo ""
echo "  ╔════════════════════════════════════╗"
echo "  ║   $DISPLAY_NAME release $TAG"
echo "  ╚════════════════════════════════════╝"
echo ""

# ── 0. Checks ───────────────────────────────────────────────────────────────
# Each one fails before the build. A failure after the notarization leaves a
# version that cannot be released again under the same number.
echo "  [0/7] Checking that the release can finish..."

fail() {
    echo "  ✗ $1"
    exit 1
}

security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID" \
    || fail "Signing identity $DEVELOPER_ID is not in the keychain"

# Apple returns 403 here when a program agreement waits for the account holder.
NOTARY_CHECK=$(xcrun notarytool history --keychain-profile "$NOTARIZE_PROFILE" 2>&1) \
    || fail "Notary service refused the '$NOTARIZE_PROFILE' credentials: $NOTARY_CHECK
    For 'A required agreement is missing or has expired': the account holder must accept
    the agreement at https://developer.apple.com/account. It can take five minutes to apply."

[ "$(gh api "repos/$GITHUB_REPO" --jq .permissions.push 2>/dev/null)" = "true" ] \
    || fail "The active gh account cannot release to $GITHUB_REPO (gh auth switch --user <owner>)"

gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1 \
    && fail "$TAG is already released. Use the next version number."

[ -f "$ICON_FILE" ] || fail "$ICON_FILE is missing (./generate-icon.swift $FLAVOR)"

[ -z "$(git status --porcelain)" ] || fail "The working tree has changes. Commit them first."

# The tag must be the commit of this build, and that commit must be on the remote.
RELEASE_COMMIT=$(git rev-parse HEAD)
git fetch --quiet origin
git branch -r --contains "$RELEASE_COMMIT" | grep -q . \
    || fail "Commit ${RELEASE_COMMIT:0:7} is not on the remote. Push it first."

if [ "${SKIP_TESTS:-0}" != "1" ]; then
    echo "  Running tests..."
    TEST_LOG=$(mktemp)
    if ! swift test >"$TEST_LOG" 2>&1; then
        grep -E "error:|failed" "$TEST_LOG" | head -20 || true
        rm -f "$TEST_LOG"
        fail "Tests failed. Fix them, or set SKIP_TESTS=1 to release without them."
    fi
    rm -f "$TEST_LOG"
fi
echo "  ✓ Ready to release"

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

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME"

cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

RESOURCE_BUNDLE=".build/release/${APP_NAME}_${APP_NAME}.bundle"
[ -d "$RESOURCE_BUNDLE" ] && cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"

# Copy Sparkle framework (use ditto to avoid ._AppleDouble files)
SPARKLE_FW=$(find .build/artifacts -name "Sparkle.framework" -type d 2>/dev/null | head -1)
if [ -n "$SPARKLE_FW" ] && [ -d "$SPARKLE_FW" ]; then
    ditto "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath @executable_path/../Frameworks \
        "$APP_BUNDLE/Contents/MacOS/$PRODUCT_NAME" 2>/dev/null || true
fi

# Write Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$PRODUCT_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>TRFlavor</key>
    <string>$FLAVOR</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$PRODUCT_NAME</string>
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
    <string>$FEED_URL</string>
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
    EDDSA_SIGNATURE=""
    LENGTH=$(stat -f%z "$ZIP_NAME")
fi

# An appcast with no signature, or a wrong one, makes Sparkle refuse the update on
# every installed copy. Stop before the release exists.
SPARKLE_KEYS=$(find .build/artifacts -name "generate_keys" -type f 2>/dev/null | head -1)
if [ -n "$SPARKLE_KEYS" ] && [ "$("$SPARKLE_KEYS" -p 2>/dev/null)" != "$EDDSA_PUBLIC_KEY" ]; then
    echo "  ✗ The Sparkle key in the keychain is not the key in the app (SUPublicEDKey)"
    exit 1
fi
if [ -z "$EDDSA_SIGNATURE" ]; then
    echo "  ✗ No Sparkle signature for $ZIP_NAME (sign_update: ${SIGNATURE:-not found})"
    exit 1
fi
if ! "$SPARKLE_SIGN" --verify "$ZIP_NAME" "$EDDSA_SIGNATURE" >/dev/null 2>&1; then
    echo "  ✗ The Sparkle signature does not match $ZIP_NAME"
    exit 1
fi

DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/${TAG}/${ZIP_NAME}"
PUB_DATE=$(date -R)

cat > appcast.xml << APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$DISPLAY_NAME Updates</title>
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

if [ "$FLAVOR" = "hackathon" ]; then
    # Never the latest release: the standard app reads its appcast from the latest one.
    gh release create "$TAG" \
        "$ZIP_NAME" \
        appcast.xml \
        --repo "$GITHUB_REPO" \
        --title "$DISPLAY_NAME v${VERSION}" \
        --target "$RELEASE_COMMIT" \
        --notes "Travel Runner for fb-travel-monolith-hackathon. It also starts the agent app (apps/amateur-agent). First install: download ${ZIP_NAME}, unzip it, and move the app to Applications. Later versions arrive through the app's update check." \
        --latest=false \
        $DRAFT_FLAG

    # The feed of the installed hackathon apps: one fixed release that holds the newest appcast.
    if ! $DRAFT; then
        if gh release view "$FEED_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
            gh release upload "$FEED_TAG" appcast.xml --repo "$GITHUB_REPO" --clobber
        else
            gh release create "$FEED_TAG" appcast.xml \
                --repo "$GITHUB_REPO" \
                --title "$DISPLAY_NAME update feed" \
                --target "$RELEASE_COMMIT" \
                --notes "The update feed of Travel Runner Hackathon. Each hackathon release replaces appcast.xml here. Do not delete this release." \
                --latest=false
        fi
    fi

    LATEST=$(gh api "repos/$GITHUB_REPO/releases/latest" --jq .tag_name)
    case "$LATEST" in
        hackathon-*) echo "  ✗ GitHub marks $LATEST as the latest release. Fix it now: the standard app reads its updates from the latest release."; exit 1 ;;
    esac
    echo "  ✓ Latest release is still $LATEST (the feed of the standard app)"
else
    gh release create "$TAG" \
        "$ZIP_NAME" \
        appcast.xml \
        --repo "$GITHUB_REPO" \
        --title "Travel Runner v${VERSION}" \
        --target "$RELEASE_COMMIT" \
        --generate-notes \
        $DRAFT_FLAG
fi

# Cleanup
rm -f appcast.xml

echo ""
echo "  ╔═══════════════════════════════════════════════════════╗"
echo "  ║  Release ${TAG} complete!"
echo "  ║  https://github.com/$GITHUB_REPO/releases  ║"
echo "  ╚═══════════════════════════════════════════════════════╝"
echo ""
