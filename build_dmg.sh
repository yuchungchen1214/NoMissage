#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/NoMissage.app"
DMG_PATH="$ROOT_DIR/dist/NoMissage-macos-arm.dmg"
STAGING_DIR="$(mktemp -d /private/tmp/NoMissage-dmg.XXXXXX)"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/scripts/build_app.sh"

cp -R "$APP_DIR" "$STAGING_DIR/NoMissage.app"

mkdir -p "$ROOT_DIR/dist"
rm -f "$DMG_PATH"
create-dmg \
    --volname "NoMissage" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon-size 100 \
    --icon "NoMissage.app" 200 150 \
    --icon "Applications" 600 150 \
    --background "$ROOT_DIR/AppResources/dmg-background.png" \
    --hide-extension "NoMissage.app" \
    --app-drop-link 600 150 \
    "$DMG_PATH" \
    "$STAGING_DIR"

echo "Built: $DMG_PATH"
