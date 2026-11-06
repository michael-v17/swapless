#!/bin/bash
# Builds Swapless as a code-signed .app bundle (copied from TypeFlow's make-app.sh).
#
# Usage:  ./scripts/make-app.sh [debug|release] [--no-install] [--adhoc]
#
# By default this also installs the bundle to /Applications and relaunches it, so a rebuild
# always updates the app you actually run. --no-install only builds the repo-root bundle.
# --adhoc skips the identity lookup and signs with "-" (the unattended run always passes it).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
INSTALL=1
ADHOC=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --no-install)  INSTALL=0 ;;
        --install)     INSTALL=1 ;;
        --adhoc)       ADHOC=1 ;;
        *) echo "unknown argument: $arg (expected debug|release|--no-install|--adhoc)" >&2; exit 2 ;;
    esac
done
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Swapless"

APP="Swapless.app"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Swapless"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>Swapless</string>
    <key>CFBundleDisplayName</key>        <string>Swapless</string>
    <key>CFBundleIdentifier</key>         <string>com.michaelv.swapless</string>
    <key>CFBundleExecutable</key>         <string>Swapless</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>            <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>     <string>27.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign with the stable self-signed identity if present (and not --adhoc), so future TCC grants
# persist across rebuilds. Create the identity once with scripts/make-cert.sh (human-only).
IDENTITY="Swapless Self-Signed"
if [ "$ADHOC" -eq 0 ] && security find-identity -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier com.michaelv.swapless "$APP"
    echo "Built $APP ($CONFIG), signed with '$IDENTITY'."
else
    codesign --force --sign - --identifier com.michaelv.swapless "$APP"
    echo "Built $APP ($CONFIG), AD-HOC signed."
fi

if [ "$INSTALL" -eq 1 ]; then
    DEST="/Applications/Swapless.app"
    PATTERN='^/Applications/Swapless\.app/Contents/MacOS/Swapless( |$)'
    # Stop the installed app by its exact argv[0] only; it flushes history on SIGTERM.
    pkill -U "$(id -u)" -f "$PATTERN" || true
    for _ in $(seq 1 50); do
        pgrep -U "$(id -u)" -f "$PATTERN" >/dev/null || break
        sleep 0.1
    done
    if OLD="$(pgrep -U "$(id -u)" -f "$PATTERN")"; then
        echo "old Swapless still running (pid $(echo "$OLD" | head -1)); not replacing" >&2
        exit 1  # never SIGKILL
    fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Installed to $DEST and relaunched."
else
    echo "Skipped install (--no-install). Launch the local bundle with: open $APP"
fi
