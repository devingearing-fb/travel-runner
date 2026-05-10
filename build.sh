#!/bin/bash
set -euo pipefail

# ── travel-runner build script ──────────────────────────────────────────────
# Builds the Swift project and packages it as a macOS .app bundle.
#
# Prerequisites:
#   - macOS 14+
#   - Xcode Command Line Tools (xcode-select --install)
#
# Usage:
#   ./build.sh              Build and create TravelRunner.app
#   ./build.sh --install    Build + copy to /Applications
#   ./build.sh --run        Build + launch immediately
# ────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="TravelRunner"
APP_BUNDLE="$APP_NAME.app"
BUNDLE_ID="ai.fastbreak.travel-runner"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"

INSTALL=false
RUN=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --run) RUN=true ;;
    esac
done

# ── Check prerequisites ─────────────────────────────────────────────────────

echo ""
echo "  ╔════════════════════════════════════╗"
echo "  ║        travel-runner build         ║"
echo "  ╚════════════════════════════════════╝"
echo ""

if ! command -v swift &>/dev/null; then
    echo "  ✗ Swift compiler not found."
    echo "    Install Xcode from the App Store."
    echo ""
    exit 1
fi

SWIFT_VERSION=$(swift --version 2>&1 | head -1)
SWIFT_MAJOR=$(swift --version 2>&1 | grep -oE 'Swift version [0-9]+' | grep -oE '[0-9]+')
DEV_DIR=$(xcode-select -p 2>/dev/null)

echo "  ✓ $SWIFT_VERSION"
echo "  ✓ Developer tools: $DEV_DIR"

# Check Swift version is 6.0+
if [ -n "$SWIFT_MAJOR" ] && [ "$SWIFT_MAJOR" -lt 6 ]; then
    echo ""
    echo "  ✗ Swift 6.0+ required (found Swift $SWIFT_MAJOR)"
    echo ""
    if [[ "$DEV_DIR" == *"CommandLineTools"* ]] && [ -d "/Applications/Xcode.app" ]; then
        echo "    Xcode is installed but xcode-select points to old Command Line Tools."
        echo "    Fix with:"
        echo "      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    elif [ -d "/Applications/Xcode.app" ]; then
        echo "    Update Xcode from the App Store."
    else
        echo "    Install Xcode from the App Store, then run:"
        echo "      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    fi
    echo ""
    echo "    Then re-run: ./build.sh"
    echo ""
    exit 1
fi

# ── Build ────────────────────────────────────────────────────────────────────

echo ""
echo "  Building release binary..."
echo "  (first build fetches dependencies — may take ~60s)"
echo ""

BUILD_LOG=$(mktemp)
swift build -c release 2>&1 | tee "$BUILD_LOG" | while IFS= read -r line; do
    echo "    $line"
done

if [ ! -f ".build/release/$APP_NAME" ]; then
    echo ""
    # Check for the specific PackageDescription mismatch error
    if grep -q "PackageDescription.Package.__allocating_init" "$BUILD_LOG"; then
        echo "  ✗ Build failed — Swift Package Manager library mismatch detected."
        echo ""
        echo "    Your Command Line Tools have a mismatched Swift compiler and"
        echo "    PackageDescription library. This is a known Apple toolchain issue."
        echo ""
        echo "    Fix options (try in order):"
        echo ""
        echo "    Option 1 — Reinstall Command Line Tools:"
        echo "      sudo rm -rf /Library/Developer/CommandLineTools"
        echo "      xcode-select --install"
        echo "      (wait for download + install to finish, then re-run ./build.sh)"
        echo ""
        echo "    Option 2 — If you have Xcode installed:"
        echo "      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        echo ""
        echo "    Option 3 — Install Xcode from the App Store (most reliable)"
        echo ""
    else
        echo "  ✗ Build failed — see errors above"
    fi
    rm -f "$BUILD_LOG"
    exit 1
fi
rm -f "$BUILD_LOG"

echo ""
echo "  ✓ Build complete"

# ── Package .app bundle ──────────────────────────────────────────────────────

echo "  Packaging $APP_BUNDLE..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy app icon
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
fi

# Copy SPM resource bundle (contains default-services.json)
RESOURCE_BUNDLE=".build/release/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

# Copy Sparkle framework (use ditto to avoid ._AppleDouble files)
SPARKLE_FW=$(find .build/artifacts -name "Sparkle.framework" -type d 2>/dev/null | head -1)
if [ -n "$SPARKLE_FW" ] && [ -d "$SPARKLE_FW" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
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
</dict>
</plist>
PLIST

# Ad-hoc codesign with entitlements
codesign --force --deep --sign - \
    --entitlements TravelRunner.entitlements \
    "$APP_BUNDLE" 2>/dev/null

echo "  ✓ $APP_BUNDLE ready"

# ── Optional: install to /Applications ───────────────────────────────────────

if $INSTALL; then
    echo ""
    echo "  Installing to /Applications..."
    rm -rf "/Applications/$APP_BUNDLE"
    cp -R "$APP_BUNDLE" "/Applications/"
    echo "  ✓ Installed at /Applications/$APP_BUNDLE"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "  ┌──────────────────────────────────────────────┐"
echo "  │  To launch:                                   │"
echo "  │    open $APP_BUNDLE                     │"
echo "  │                                               │"
echo "  │  Or double-click $APP_BUNDLE in Finder  │"
echo "  │                                               │"
echo "  │  On first launch, a setup wizard will ask     │"
echo "  │  for your repo paths. You can drag your       │"
echo "  │  Codebases folder to auto-detect them.        │"
echo "  └──────────────────────────────────────────────┘"
echo ""

# ── Optional: launch immediately ─────────────────────────────────────────────

if $RUN; then
    echo "  Launching..."
    open "$APP_BUNDLE"
fi
