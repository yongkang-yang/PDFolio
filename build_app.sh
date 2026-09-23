#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PDFolio"
APP="$ROOT/$APP_NAME.app"
VERSION="0.1.0"
BUILD="1"

INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL=0 ;;
        *) echo "usage: $0 [--no-install]" >&2; exit 2 ;;
    esac
done

cd "$ROOT"
swift build -c release --product "$APP_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.yongkang.pdfolio</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Local-only PDF organizer. Your files never leave your Mac.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>PDF Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.adobe.pdf</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.image</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Sign with a stable identity so macOS privacy grants (Accessibility, etc.)
# survive rebuilds; an ad-hoc signature changes every build and TCC treats
# each one as a new app. Identities are matched by SHA-1 hash because two
# certificates with the same common name make codesign refuse an ambiguous
# match. Override with CODESIGN_IDENTITY.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | awk '/Developer ID Application/ {print $2; exit}' || true)"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | awk '/Apple Development/ {print $2; exit}' || true)"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "warning: no signing identity found; ad-hoc signing. Privacy grants will reset on every rebuild." >&2
fi

/usr/bin/codesign --force --deep --sign "$IDENTITY" "$APP"

echo
echo "Built: $APP"

# By default the build is installed over /Applications/PDFolio.app, the copy
# that is actually launched: a bundle left only in the repo meant the running
# app silently stayed older than every fix. --no-install skips it.
if [ "$INSTALL" = 0 ]; then
    exit 0
fi

INSTALL_DIR="/Applications/PDFolio.app"
echo "==> Installing to $INSTALL_DIR"

# Quit a running copy and wait for it to exit before replacing its bundle,
# then relaunch only if something was running before.
WAS_RUNNING=0
if pgrep -xq "PDFolio"; then
    WAS_RUNNING=1
    osascript -e 'quit app id "com.yongkang.pdfolio"' >/dev/null 2>&1 || true
    for _ in $(seq 50); do
        pgrep -xq "PDFolio" || break
        sleep 0.1
    done
    if pgrep -xq "PDFolio"; then
        echo "PDFolio did not quit; not installing" >&2
        exit 1
    fi
fi

rm -rf "$INSTALL_DIR"
ditto "$APP" "$INSTALL_DIR"
echo "    installed $INSTALL_DIR"

if [ "$WAS_RUNNING" = 1 ]; then
    open "$INSTALL_DIR"
    echo "    relaunched"
else
    echo "  run:  open $INSTALL_DIR"
fi
