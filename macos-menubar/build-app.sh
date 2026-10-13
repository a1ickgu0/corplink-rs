#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$ROOT/dist/CorpLink.app"
CORE="$ROOT/../target/release/corplink-rs"
if [ ! -x "$CORE" ]; then
    echo "Missing release binary: $CORE" >&2
    echo "Build corplink-rs before packaging the menu bar app." >&2
    exit 1
fi
swift build -c release --package-path "$ROOT"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/.build/release/corplink-menubar" "$APP/Contents/MacOS/corplink-menubar"
cp "$CORE" "$APP/Contents/Resources/corplink-rs"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>corplink-menubar</string>
    <key>CFBundleIdentifier</key><string>work.corplink.menubar</string>
    <key>CFBundleName</key><string>CorpLink</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
echo "Created $APP"
