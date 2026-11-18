#!/bin/bash
set -euo pipefail

# ── travel-runner smoke test ────────────────────────────────────────────────
# Launches a built app the way a new teammate's Mac would: an empty home folder,
# a bare PATH, no config. release.sh runs it before a release is notarized.
#
# Usage:
#   scripts/smoke.sh <App.app> [expected-version]
#
# It checks:
#   1. First run (no services.json): the control API answers, reports the version
#      of the bundle and "configured": false, and /api/preflight answers with a
#      Node check that has a result (it must not hang).
#   2. A config for Tests/Fixtures/mini-monorepo (a copy): "configured": true,
#      and the booking portal is in the service list, stopped.
#
# It starts no service and no database step. The app gets its own config folder
# and control port (TRAVEL_RUNNER_CONFIG_DIR, TRAVEL_RUNNER_CONTROL_PORT), and
# CFFIXED_USER_HOME moves every "~" of the app to a temporary folder, so the
# real config, logs, issues and preferences are not touched.
#
# One copy of the app runs at a time. Quit an installed copy of the same app
# first; the script says so when it finds one.
# ────────────────────────────────────────────────────────────────────────────

APP="${1:?Usage: scripts/smoke.sh <App.app> [expected-version]}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$SCRIPT_DIR/../Tests/Fixtures/mini-monorepo"
PLIST="$APP/Contents/Info.plist"

fail() {
    echo "  ✗ smoke: $1"
    if [ -n "${LOG:-}" ] && [ -s "$LOG" ]; then
        echo "    Last lines of the app's output:"
        tail -15 "$LOG" | sed 's/^/      /'
    fi
    exit 1
}

[ -f "$PLIST" ] || fail "$APP is not an app bundle (no Contents/Info.plist)"
[ -d "$FIXTURE" ] || fail "the fixture $FIXTURE is missing"
EXECUTABLE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
EXPECTED_VERSION="${2:-$BUNDLE_VERSION}"
[ -x "$EXECUTABLE" ] || fail "$EXECUTABLE is not there"
[ "$BUNDLE_VERSION" = "$EXPECTED_VERSION" ] \
    || fail "the bundle says version $BUNDLE_VERSION, expected $EXPECTED_VERSION"

WORK="$(mktemp -d)"
LOG="$WORK/app.log"
APP_PID=""

stop_app() {
    [ -n "$APP_PID" ] || return 0
    kill "$APP_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do
        kill -0 "$APP_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -9 "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
}

cleanup() {
    stop_app
    rm -rf "$WORK"
}
trap cleanup EXIT

# A port that nothing listens on now.
PORT=""
for _ in $(seq 1 30); do
    CANDIDATE=$((20000 + RANDOM % 20000))
    if ! nc -z 127.0.0.1 "$CANDIDATE" >/dev/null 2>&1; then
        PORT="$CANDIDATE"
        break
    fi
done
[ -n "$PORT" ] || fail "found no free port for the control API"
API="http://127.0.0.1:$PORT"

mkdir -p "$WORK/home" "$WORK/tmp"

# launch <config folder>
launch() {
    : > "$LOG"
    env -i \
        HOME="$WORK/home" CFFIXED_USER_HOME="$WORK/home" TMPDIR="$WORK/tmp" \
        PATH=/usr/bin:/bin \
        TRAVEL_RUNNER_SMOKE=1 \
        TRAVEL_RUNNER_CONFIG_DIR="$1" \
        TRAVEL_RUNNER_CONTROL_PORT="$PORT" \
        "$EXECUTABLE" >"$LOG" 2>&1 &
    APP_PID=$!

    for _ in $(seq 1 150); do
        if curl -s --max-time 2 "$API/api/status" >/dev/null 2>&1; then return 0; fi
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            local code=0
            wait "$APP_PID" || code=$?
            APP_PID=""
            if [ "$code" = "75" ]; then
                fail "another copy of this app runs. Quit it (menu bar icon → Quit), then run this again."
            fi
            fail "the app ended at launch (exit $code)"
        fi
        sleep 0.2
    done
    fail "the control API did not answer on $API in 30 seconds"
}

# field <json> <key path>: one value of a JSON text, or nothing.
field() {
    printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null || true
}

# get <path> <seconds>
get() {
    curl -s --max-time "$2" "$API$1" || fail "GET $1 did not answer in $2 seconds"
}

# ── 1. First run: no config ─────────────────────────────────────────────────
echo "  smoke [1/2] first run with an empty home folder..."
mkdir -p "$WORK/config-empty"
launch "$WORK/config-empty"

STATUS="$(get /api/status 5)"
[ "$(field "$STATUS" version)" = "$EXPECTED_VERSION" ] \
    || fail "/api/status reports version '$(field "$STATUS" version)', expected $EXPECTED_VERSION"
[ "$(field "$STATUS" configured)" = "false" ] \
    || fail "/api/status must report \"configured\": false without a services.json: $STATUS"
[ "$(field "$STATUS" build_kind)" != "" ] || fail "/api/status has no build_kind: $STATUS"

# Each check has its own time limit in the app, so this answer always comes.
PREFLIGHT="$(get /api/preflight 45)"
NODE_ID="$(field "$PREFLIGHT" checks.0.id)"
NODE_STATUS="$(field "$PREFLIGHT" checks.0.status)"
[ "$NODE_ID" = "node" ] || fail "/api/preflight has no Node check first: $PREFLIGHT"
case "$NODE_STATUS" in
    passed|warning|failed) ;;
    *) fail "the Node check has no result ('$NODE_STATUS'): $PREFLIGHT" ;;
esac
echo "    ✓ version $EXPECTED_VERSION, not configured, Node check: $NODE_STATUS ($(field "$PREFLIGHT" checks.0.detail))"
stop_app

# ── 2. A config for the fixture ─────────────────────────────────────────────
echo "  smoke [2/2] a config for the mini monorepo..."
cp -R "$FIXTURE" "$WORK/mono"
mkdir -p "$WORK/config-mini"
cat > "$WORK/config-mini/services.json" << JSON
{
  "paths": {
    "monorepo": "$WORK/mono",
    "universal_login": "$WORK/universal-login",
    "stream_services": "$WORK/stream-services",
    "load_test": "$WORK/load-test"
  },
  "services": []
}
JSON
launch "$WORK/config-mini"

STATUS="$(get /api/status 5)"
[ "$(field "$STATUS" configured)" = "true" ] \
    || fail "/api/status must report \"configured\": true with a services.json: $STATUS"
PORTAL_PHASE="$(field "$STATUS" services.travel-portal.phase)"
[ -n "$PORTAL_PHASE" ] || fail "the booking portal is not in the service list: $STATUS"
[ "$(field "$STATUS" services.travel-portal.pid)" = "nil" ] \
    || fail "the smoke launch must start no service: $STATUS"
echo "    ✓ configured, booking portal: $PORTAL_PHASE, nothing started"
stop_app

echo "  ✓ smoke passed"
