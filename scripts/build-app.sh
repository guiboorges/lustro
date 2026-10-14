#!/bin/zsh
# Builds Lustro.app into ./build. Usage: scripts/build-app.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
APP="build/Lustro.app"

# Prefer full Xcode when present (needed for SwiftUI and Swift Testing).
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Folders such as ~/Documents can tag build products with Finder metadata that codesign rejects.
xattr -cr .build 2>/dev/null || true
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
xattr -cr "$BIN_DIR" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Lustro" "$APP/Contents/MacOS/Lustro"
# SwiftPM resource bundle (rules.json) must sit next to the executable's Resources.
cp -R "$BIN_DIR/Lustro_LustroCore.bundle" "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Bundled typeface (Plus Jakarta Sans, SIL Open Font License), registered via ATSApplicationFontsPath.
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/*.ttf Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Lustro</string>
  <key>CFBundleIdentifier</key><string>io.github.guiboorges.lustro</string>
  <key>CFBundleName</key><string>Lustro</string>
  <key>CFBundleDisplayName</key><string>Lustro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# Signing, in order of preference:
#   SIGN_IDENTITY=…              e.g. a Developer ID for releases
#   "Lustro Local Signing"       stable local identity (scripts/create-signing-identity.sh), so macOS keeps
#                                permissions such as Full Disk Access across rebuilds
#   ad-hoc ("-")                 works anywhere, but permissions must be granted again after each build
if [ -z "${SIGN_IDENTITY:-}" ] && security find-certificate -c "Lustro Local Signing" >/dev/null 2>&1; then
    SIGN_IDENTITY="Lustro Local Signing"
fi
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($VERSION)"
