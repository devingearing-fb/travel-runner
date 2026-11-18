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
# Usage (RELEASING.md has the whole procedure):
#   ./release.sh 0.2.0                       Build + smoke test + sign + notarize + publish to the canary feed
#   ./release.sh 0.2.0 --draft               Same but creates a draft release that nobody sees
#   ./release.sh --promote 0.2.0             Give a canary release to every teammate
#   ./release.sh --pull 0.2.0                Take a release back
#   ./release.sh --rollback-to v0.1.9 0.2.1  Release the source of an older tag under a new number
#   FLAVOR=hackathon ./release.sh 1.0.0      Release Travel Runner Hackathon
#
# The two apps release to the same repository. The standard app reads the appcast of
# the release that GitHub marks as latest. A new standard release is a prerelease, so
# it is not the latest: only a copy on the canary channel sees it, through the fixed
# release "canary-appcast". --promote makes it the latest release. A hackathon release
# is never marked as latest (tag hackathon-v<version>), and its app reads the appcast
# of the fixed release "hackathon-appcast", which each hackathon release replaces.
#
# The script first makes sure that the release can finish (signing identity, notary
# access, GitHub access, a clean tree that is on the remote), then runs the tests and
# scripts/clean-shell-check.sh: the first database step of the monolith must pass with
# only the README's tools. The monolith is TR_MONOLITH_DIR, or fb-travel-monolith
# (fb-travel-monolith-hackathon for the hackathon app) next to this repo.
# After the build it runs scripts/smoke.sh on the app: a release that cannot start on
# a clean Mac stops here, before it is notarized.
# SKIP_TESTS=1 skips the tests and the clean-shell check, for a --draft only.
#
# The appcast item carries the release notes, which Sparkle shows in its update
# window: the subjects of the commits since the last full release, or the lines of
# RELEASE_NOTES=<file> (one change per line). It also lists the released versions,
# so an old copy can say how many versions behind it is.
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

USAGE="Usage: ./release.sh <version> [--draft] | --promote <version> | --pull <version> | --rollback-to <tag> <new-version>"

fail() {
    echo "  ✗ $1"
    exit 1
}

# What to do: build (the default), promote or pull. A rollback is a build from an older tag.
MODE="build"
DRAFT=false
ROLLBACK_TAG=""
case "${1:-}" in
    --promote)
        MODE="promote"
        VERSION="${2:?$USAGE}"
        [ $# -eq 2 ] || fail "$USAGE"
        ;;
    --pull)
        MODE="pull"
        VERSION="${2:?$USAGE}"
        [ $# -eq 2 ] || fail "$USAGE"
        ;;
    --rollback-to)
        ROLLBACK_TAG="${2:?$USAGE}"
        VERSION="${3:?$USAGE}"
        [ $# -eq 3 ] || fail "$USAGE"
        ;;
    ""|-*)
        fail "$USAGE"
        ;;
    *)
        VERSION="$1"
        case "${2:-}" in
            "") ;;
            --draft) DRAFT=true ;;
            *) fail "$USAGE" ;;
        esac
        [ $# -le 2 ] || fail "$USAGE"
        ;;
esac
# Sparkle and the runner's own checks compare three plain numbers.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "'$VERSION' is not a version (x.y.z)"

# A rollback builds in another folder: keep the path of the notes file absolute.
if [ -n "${RELEASE_NOTES:-}" ] && [ "$MODE" = "build" ]; then
    [ -f "$RELEASE_NOTES" ] || fail "RELEASE_NOTES: no file at $RELEASE_NOTES"
    RELEASE_NOTES="$(cd "$(dirname "$RELEASE_NOTES")" && pwd)/$(basename "$RELEASE_NOTES")"
fi

BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
ZIP_NAME="${PRODUCT_NAME}-${VERSION}.zip"
# One fixed release for each feed that is not "the latest release". It holds the newest appcast.
CANARY_FEED_TAG="canary-appcast"
if [ "$FLAVOR" = "hackathon" ]; then
    TAG="hackathon-v${VERSION}"
    TAG_PATTERN='^hackathon-v[0-9]+\.[0-9]+\.[0-9]+$'
    FEED_TAG="hackathon-appcast"
    FEED_URL="https://github.com/$GITHUB_REPO/releases/download/$FEED_TAG/appcast.xml"
else
    TAG="v${VERSION}"
    TAG_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+$'
    FEED_TAG="$CANARY_FEED_TAG"
    FEED_URL="https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"
fi

can_release() {
    [ "$(gh api "repos/$GITHUB_REPO" --jq .permissions.push 2>/dev/null)" = "true" ] \
        || fail "The active gh account cannot release to $GITHUB_REPO (gh auth switch --user <owner>)"
}

# The tag of the release that GitHub marks as latest: the feed of every standard app.
latest_tag() {
    gh api "repos/$GITHUB_REPO/releases/latest" --jq .tag_name 2>/dev/null || true
}

# release_field <tag> <jq expression>
release_field() {
    gh release view "$1" --repo "$GITHUB_REPO" --json isDraft,isPrerelease,assets --jq "$2"
}

# The newest full release of this app that is not <tag>. Empty when there is none.
previous_release() {
    gh release list --repo "$GITHUB_REPO" --exclude-drafts --exclude-pre-releases --limit 100 \
        --json tagName --jq '.[].tagName' \
        | grep -E "$TAG_PATTERN" | grep -vx "$1" | sort -t. -k1,1V -k2,2n -k3,3n | tail -1 || true
}

# The versions of the full releases of this app and <version>, oldest first, on one
# line. The app counts the versions between its own and the newest from this list.
released_versions() {
    {
        gh release list --repo "$GITHUB_REPO" --exclude-drafts --exclude-pre-releases --limit 100 \
            --json tagName --jq '.[].tagName' \
            | grep -E "$TAG_PATTERN" | sed -E 's/^(hackathon-)?v//' || true
        echo "$1"
    } | sort -u -t. -k1,1n -k2,2n -k3,3n | tail -50 | tr '\n' ' ' | sed 's/ $//'
}

# The release notes of the appcast item as HTML: one list item per line of the
# notes, escaped, and a link to the release on GitHub.
release_notes_html() {
    local lines=""
    if [ -n "${RELEASE_NOTES:-}" ]; then
        lines="$(grep -v '^[[:space:]]*$' "$RELEASE_NOTES" || true)"
    elif [ -n "$ROLLBACK_TAG" ]; then
        lines="The source of $ROLLBACK_TAG, released again as $VERSION."
    else
        local previous
        previous="$(previous_release "$TAG")"
        if [ -n "$previous" ] && git rev-parse --quiet --verify "refs/tags/$previous" >/dev/null; then
            lines="$(git log --no-merges --pretty=format:%s "$previous..$RELEASE_COMMIT" | head -40)"
        fi
    fi
    if [ -n "$lines" ]; then
        echo "<ul>"
        printf '%s\n' "$lines" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
            -e 's/^[[:space:]]*[-*][[:space:]]*//' -e 's/^/<li>/' -e 's/$/<\/li>/'
        echo "</ul>"
    fi
    echo "<p><a href=\"https://github.com/$GITHUB_REPO/releases/tag/$TAG\">All changes in $TAG</a></p>"
}

# Puts the appcast of release <tag> on the fixed feed release.
point_feed_at() {
    local dir
    dir="$(mktemp -d)"
    gh release download "$1" --repo "$GITHUB_REPO" --pattern appcast.xml --dir "$dir" \
        || fail "$1 has no appcast.xml"
    gh release upload "$FEED_TAG" "$dir/appcast.xml" --repo "$GITHUB_REPO" --clobber
    rm -rf "$dir"
}

# ── Promote: the canary release becomes the release that every teammate gets ──
if [ "$MODE" = "promote" ]; then
    [ "$FLAVOR" = "standard" ] \
        || fail "The hackathon app has one feed and no canary: its release is live when release.sh ends."
    can_release
    gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1 || fail "$TAG is not released."
    [ "$(release_field "$TAG" .isDraft)" = "false" ] \
        || fail "$TAG is a draft. Publish it on GitHub first (as a prerelease)."
    # The installed apps read appcast.xml from the latest release. Without it they see no update at all.
    for asset in appcast.xml "$ZIP_NAME"; do
        release_field "$TAG" '.assets[].name' | grep -qx "$asset" || fail "$TAG has no $asset. Do not promote it."
    done
    gh release edit "$TAG" --repo "$GITHUB_REPO" --prerelease=false --latest
    LATEST="$(latest_tag)"
    [ "$LATEST" = "$TAG" ] || fail "GitHub marks '$LATEST' as the latest release, not $TAG. Fix it on GitHub now."
    echo "  ✓ $TAG is the latest release. Every Travel Runner sees it at its next update check."
    exit 0
fi

# ── Pull: take a release back ───────────────────────────────────────────────
# A copy that already installed it keeps it: Sparkle never installs an older version.
# Move those copies forward with --rollback-to.
if [ "$MODE" = "pull" ]; then
    can_release
    gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1 || fail "$TAG is not released."
    PREVIOUS="$(previous_release "$TAG")"
    [ -n "$PREVIOUS" ] || fail "There is no older full release to go back to. Fix forward with a new version."
    gh release edit "$TAG" --repo "$GITHUB_REPO" --prerelease --latest=false
    if [ "$FLAVOR" = "standard" ]; then
        gh release edit "$PREVIOUS" --repo "$GITHUB_REPO" --latest
        LATEST="$(latest_tag)"
        [ "$LATEST" = "$PREVIOUS" ] \
            || fail "GitHub marks '$LATEST' as the latest release, not $PREVIOUS. Fix it on GitHub now."
    fi
    # The fixed feed must not offer the pulled version either.
    if gh release view "$FEED_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        point_feed_at "$PREVIOUS"
    fi
    echo "  ✓ $TAG is pulled. New update checks get $PREVIOUS."
    echo "    Copies that already have ${VERSION} keep it. To move them, release the older source"
    echo "    under a new number: ./release.sh --rollback-to $PREVIOUS <new-version>"
    exit 0
fi

# ── Rollback: build the source of an older tag as a new version ─────────────
# The build runs in a separate worktree of that tag. This checkout is not changed.
SMOKE_SCRIPT="$SCRIPT_DIR/scripts/smoke.sh"
CLEAN_SHELL_SCRIPT="$SCRIPT_DIR/scripts/clean-shell-check.sh"
if [ "$FLAVOR" = "hackathon" ]; then
    MONOLITH_DIR="${TR_MONOLITH_DIR:-$SCRIPT_DIR/../fb-travel-monolith-hackathon}"
else
    MONOLITH_DIR="${TR_MONOLITH_DIR:-$SCRIPT_DIR/../fb-travel-monolith}"
fi
if [ -n "$ROLLBACK_TAG" ]; then
    git rev-parse --verify --quiet "refs/tags/$ROLLBACK_TAG" >/dev/null || fail "There is no tag $ROLLBACK_TAG."
    ROLLBACK_DIR="$(mktemp -d)/travel-runner-$ROLLBACK_TAG"
    git worktree add --detach "$ROLLBACK_DIR" "$ROLLBACK_TAG" >/dev/null
    trap 'cd "$SCRIPT_DIR"; git worktree remove --force "$ROLLBACK_DIR" 2>/dev/null || true' EXIT
    cd "$ROLLBACK_DIR"
    echo "  Building the source of $ROLLBACK_TAG as $TAG"
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

# The tests are skipped only for a draft: nobody gets a draft.
if [ "${SKIP_TESTS:-0}" = "1" ] && ! $DRAFT; then
    fail "SKIP_TESTS=1 is for a --draft only. A release that teammates get runs the tests."
fi

security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID" \
    || fail "Signing identity $DEVELOPER_ID is not in the keychain"

# Apple returns 403 here when a program agreement waits for the account holder.
NOTARY_CHECK=$(xcrun notarytool history --keychain-profile "$NOTARIZE_PROFILE" 2>&1) \
    || fail "Notary service refused the '$NOTARIZE_PROFILE' credentials: $NOTARY_CHECK
    For 'A required agreement is missing or has expired': the account holder must accept
    the agreement at https://developer.apple.com/account. It can take five minutes to apply."

can_release

gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1 \
    && fail "$TAG is already released. Use the next version number."

[ -f "$ICON_FILE" ] || fail "$ICON_FILE is missing (./generate-icon.swift $FLAVOR)"

# The standard app reads its updates from the latest release. If that is a hackathon
# release or a feed release now, the state is already wrong: stop before anything is published.
LATEST_BEFORE="$(latest_tag)"
case "$LATEST_BEFORE" in
    hackathon-*|*-appcast) fail "GitHub marks $LATEST_BEFORE as the latest release. Fix it first: the standard app reads its updates from the latest release." ;;
esac

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
        fail "Tests failed. Fix them. (SKIP_TESTS=1 works for a --draft only.)"
    fi
    rm -f "$TEST_LOG"

    # A teammate's Mac has only the README's tools. Pull dev and run pnpm install in
    # the monolith first, so the check reads the scripts that teammates get.
    echo "  Running the clean-shell check..."
    "$CLEAN_SHELL_SCRIPT" "$MONOLITH_DIR" \
        || fail "The clean-shell check failed. A teammate's first Start fails the same way. Fix it first."
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
    <key>TRGitCommit</key>
    <string>$(git rev-parse --short "$RELEASE_COMMIT")</string>
    <key>TRBuildKind</key>
    <string>release</string>
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

# ── 3b. Smoke test ──────────────────────────────────────────────────────────
# The signed app starts with an empty home folder and a bare PATH, and must answer.
# It runs before the notarization: a version number that Apple has seen cannot be used again.
# A tag from before the smoke test (older than 0.14.0) cannot pass it; SKIP_SMOKE=1 is
# for a rollback to such a tag only.
if [ -n "$ROLLBACK_TAG" ] && [ "${SKIP_SMOKE:-0}" = "1" ]; then
    echo "  ! Smoke test skipped (SKIP_SMOKE=1, rollback to $ROLLBACK_TAG)"
else
    [ "${SKIP_SMOKE:-0}" != "1" ] || fail "SKIP_SMOKE=1 is for --rollback-to only."
    "$SMOKE_SCRIPT" "$APP_BUNDLE" "$VERSION"
fi

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
RELEASE_NOTES_HTML="$(release_notes_html)"
RELEASED_VERSIONS="$(released_versions "$VERSION")"

cat > appcast.xml << APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/"
     xmlns:travelrunner="https://github.com/$GITHUB_REPO">
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
      <description><![CDATA[
$RELEASE_NOTES_HTML
      ]]></description>
      <travelrunner:releasedVersions>$RELEASED_VERSIONS</travelrunner:releasedVersions>
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

# Replaces appcast.xml on the fixed feed release, or makes that release.
publish_feed() {
    if gh release view "$FEED_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        gh release upload "$FEED_TAG" appcast.xml --repo "$GITHUB_REPO" --clobber
    else
        gh release create "$FEED_TAG" appcast.xml \
            --repo "$GITHUB_REPO" \
            --title "$1" \
            --target "$RELEASE_COMMIT" \
            --notes "$2" \
            --prerelease \
            --latest=false
    fi
}

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
        publish_feed "$DISPLAY_NAME update feed" \
            "The update feed of Travel Runner Hackathon. Each hackathon release replaces appcast.xml here. Do not delete this release."
    fi
else
    # A prerelease is never the latest release, so no installed copy sees it yet.
    # Only a copy on the canary channel does, through the canary feed.
    gh release create "$TAG" \
        "$ZIP_NAME" \
        appcast.xml \
        --repo "$GITHUB_REPO" \
        --title "Travel Runner v${VERSION}" \
        --target "$RELEASE_COMMIT" \
        --generate-notes \
        --prerelease \
        --latest=false \
        $DRAFT_FLAG

    if ! $DRAFT; then
        publish_feed "Travel Runner canary feed" \
            "The update feed of the canary channel of Travel Runner. Each release replaces appcast.xml here; --promote gives the release to everyone. Do not delete this release."
    fi
fi

# Neither app's release may change what the standard app reads.
LATEST="$(latest_tag)"
[ "$LATEST" = "$LATEST_BEFORE" ] \
    || fail "GitHub now marks '$LATEST' as the latest release (before: '$LATEST_BEFORE'). Fix it now: the standard app reads its updates from the latest release."
echo "  ✓ Latest release is still ${LATEST:-none} (the feed of the standard app)"

# Cleanup
rm -f appcast.xml

echo ""
echo "  ╔═══════════════════════════════════════════════════════╗"
echo "  ║  Release ${TAG} complete!"
echo "  ║  https://github.com/$GITHUB_REPO/releases  ║"
echo "  ╚═══════════════════════════════════════════════════════╝"
if [ "$FLAVOR" = "standard" ] && ! $DRAFT; then
    echo "  Only the canary channel has it now. After the soak: ./release.sh --promote $VERSION"
fi
echo ""
