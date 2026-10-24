#!/bin/bash
# Builds dist/SFTPDrive.zip – the "SFTP Drive.app" app + the guide + the uninstaller.
#
# Run: double-click in Finder, or ./build.command in Terminal.
# Needs: an Apple-silicon Mac and the Xcode Command Line Tools (xcode-select --install).
#
# What ends up inside the app:
#   Contents/MacOS/SFTPDrive                       menu-bar app            (src/app/main.swift)
#   Contents/PlugIns/SFTPDriveFinder.appex         Finder menu             (src/app/finder.swift)
#   Contents/Resources/sftpdrive                   sync engine (bash)      (src/sftpdrive)
#   Contents/Resources/sftpdrive-tag               Finder tags             (src/app/tag.swift)
#   Contents/Resources/AppIcon.icns                icon                    (src/app/make-icon.swift)

cd "$(dirname "$0")" || exit 1
set -e
SRC=src
OUT=dist
BUILD=$(mktemp -d)
APP="$BUILD/SFTPDrive/SFTP Drive.app"
TARGET=arm64-apple-macos13.0

echo "▸ Menu-bar app…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target "$TARGET" -o "$APP/Contents/MacOS/SFTPDrive" "$SRC/app/main.swift" -framework AppKit
cp "$SRC/app/Info.plist" "$APP/Contents/Info.plist"

echo "▸ Finder extension…"
X="$APP/Contents/PlugIns/SFTPDriveFinder.appex"
mkdir -p "$X/Contents/MacOS"
# -parse-as-library: the extension has no main – without it global variables would not be initialised
swiftc -O -parse-as-library -module-name SFTPDriveFinder -application-extension -target "$TARGET" \
  -Xlinker -e -Xlinker _NSExtensionMain -framework FinderSync -framework Cocoa \
  -o "$X/Contents/MacOS/SFTPDriveFinder" "$SRC/app/finder.swift"
cp "$SRC/app/finder-Info.plist" "$X/Contents/Info.plist"

echo "▸ Script and tag helper…"
cp "$SRC/sftpdrive" "$APP/Contents/Resources/sftpdrive"
chmod +x "$APP/Contents/Resources/sftpdrive"
swiftc -O -target "$TARGET" -o "$APP/Contents/Resources/sftpdrive-tag" "$SRC/app/tag.swift"

echo "▸ Icon…"
swiftc -O -o "$BUILD/make-icon" "$SRC/app/make-icon.swift" -framework AppKit
"$BUILD/make-icon" "$BUILD/icon.png"
mkdir "$BUILD/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$BUILD/AppIcon.iconset"

echo "▸ Signing (ad-hoc)…"
# Order matters: nested parts first, the extension with its sandbox entitlements,
# the app last – without --deep, otherwise the extension would lose its entitlements.
codesign --force -s - "$APP/Contents/Resources/sftpdrive-tag"
codesign --force -s - --entitlements "$SRC/app/finder.entitlements" "$X"
codesign --force -s - "$APP"

echo "▸ ZIP…"
cp "$SRC/package/"* "$BUILD/SFTPDrive/"
find "$BUILD/SFTPDrive" -exec xattr -c {} + 2>/dev/null || true
mkdir -p "$OUT"
rm -f "$OUT/SFTPDrive.zip"
(cd "$BUILD" && ditto -c -k --norsrc --noextattr --keepParent SFTPDrive "$OLDPWD/$OUT/SFTPDrive.zip")
rm -rf "$BUILD"
echo "✔ Done: $OUT/SFTPDrive.zip"
