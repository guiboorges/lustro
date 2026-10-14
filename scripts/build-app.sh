#!/bin/zsh
# Builds Lustro.app into ./build. Usage: scripts/build-app.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
# The version comes from the release tag and is written into Info.plist, so it may only be a version.
[[ "$VERSION" =~ '^[0-9A-Za-z.+-]+$' ]] || { echo "error: invalid version: $VERSION" >&2; exit 1; }
APP="build/Lustro.app"

# Prefer full Xcode when present (needed for SwiftUI and Swift Testing).
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Folders such as ~/Documents can tag build products with Finder metadata that codesign rejects.
xattr -cr .build 2>/dev/null || true
# SNAPSHOTS=1 compiles in the screenshot helper (DevSnapshot). Never set it for builds people install.
FLAGS=(-c release --arch arm64 --arch x86_64)
[[ "${SNAPSHOTS:-}" == 1 ]] && FLAGS+=(-Xswiftc -DLUSTRO_SNAPSHOTS)
swift build "${FLAGS[@]}"
BIN_DIR="$(swift build "${FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
xattr -cr "$BIN_DIR" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Lustro" "$APP/Contents/MacOS/Lustro"
# SwiftPM resource bundle (rules.json) must sit next to the executable's Resources.
cp -R "$BIN_DIR/Lustro_LustroCore.bundle" "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Translations (Localization/*.json → <language>.lproj/Localizable.strings).
python3 scripts/build-localization.py "$APP/Contents/Resources"
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
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>pt-BR</string><string>pt-PT</string><string>pt</string></array>
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
  <key>NSAppleEventsUsageDescription</key><string>Lustro asks Finder to move apps installed by the App Store to the Trash. Finder then asks for your password.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature by default. It changes on every build, so macOS asks for permissions such as Full Disk Access
# again after an update. That is deliberate: a stable self-signed identity whose key codesign can use without a
# prompt would let any program in your account sign itself as Lustro and inherit those permissions.
# Releases can pass a Developer ID: SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
xattr -cr "$APP" 2>/dev/null || true
# Hardened runtime: macOS ignores DYLD_* variables and refuses unsigned libraries, so no other program can
# load its code into Lustro and borrow the Full Disk Access granted to it.
# Finder metadata can reappear on files under ~/Documents while signing; clear it and retry once.
# The only entitlement lets Lustro ask Finder to trash apps installed by the App Store (see FinderTrash.swift).
SIGN=(codesign --force --deep --options runtime --entitlements Resources/Lustro.entitlements --sign "${SIGN_IDENTITY:--}" "$APP")
"${SIGN[@]}" || { xattr -cr "$APP"; "${SIGN[@]}"; }
[[ "$(codesign -dv "$APP" 2>&1)" == *"flags="*"runtime"* ]] || { echo "error: $APP is not signed with the hardened runtime" >&2; exit 1; }
echo "Built $APP ($VERSION)"
