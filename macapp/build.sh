#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/TokenTracker.app"
CONTENTS="$APP/Contents"
WORK="$(mktemp -d /tmp/tokentracker-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

command -v swiftc >/dev/null || { printf '%s\n' 'swiftc is required (install Apple Command Line Tools).' >&2; exit 1; }
SDK="$(xcrun --show-sdk-path)"
SOURCES=("$ROOT"/macapp/Sources/*.swift)
mkdir -p "$DIST"

compile() {
    local arch="$1"
    swiftc -O -swift-version 5 -sdk "$SDK" -target "$arch-apple-macosx12.0" \
        -module-cache-path "$WORK/module-cache" \
        -framework AppKit -framework WebKit -framework ServiceManagement \
        "${SOURCES[@]}" -o "$WORK/TokenTracker-$arch"
}

printf '%s\n' 'Building arm64 and x86_64…'
arm_ok=false
intel_ok=false
if compile arm64; then arm_ok=true; fi
if compile x86_64; then intel_ok=true; fi
if $arm_ok && $intel_ok; then
    lipo -create "$WORK/TokenTracker-arm64" "$WORK/TokenTracker-x86_64" -output "$WORK/TokenTracker"
else
    arch="$(uname -m)"
    printf 'Universal build unavailable; using %s.\n' "$arch" >&2
    if [[ ! -x "$WORK/TokenTracker-$arch" ]]; then compile "$arch"; fi
    cp "$WORK/TokenTracker-$arch" "$WORK/TokenTracker"
fi

# Only replace the output bundle after compilation succeeds.
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$WORK/TokenTracker" "$CONTENTS/MacOS/TokenTracker"
cp "$ROOT/app.py" "$ROOT/prices.json" "$CONTENTS/Resources/"
for folder in tracker web; do
    rsync -a --exclude='__pycache__' --exclude='*.pyc' --exclude='*.pyo' \
        "$ROOT/$folder/" "$CONTENTS/Resources/$folder/"
done

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.dh-west-coder.tokentracker</string>
    <key>CFBundleName</key><string>TokenTracker</string>
    <key>CFBundleDisplayName</key><string>Token Tracker</string>
    <key>CFBundleExecutable</key><string>TokenTracker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
        <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
    </dict>
</dict>
</plist>
PLIST

if [[ -f "$ROOT/macapp/AppIcon.icns" ]]; then
    cp "$ROOT/macapp/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$CONTENTS/Info.plist"
fi
plutil -lint "$CONTENTS/Info.plist"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$WORK/dmg"
cp -R "$APP" "$WORK/dmg/"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname 'TokenTracker' -srcfolder "$WORK/dmg" -ov -format UDZO "$DIST/TokenTracker.dmg"
printf '\nBuilt %s\nBuilt %s\n' "$APP" "$DIST/TokenTracker.dmg"
