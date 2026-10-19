#!/bin/sh
# Compile le cœur Rust (bibliothèque statique), l'app Swift qui le lie et
# l'outil Apple Intelligence, emballe le tout dans Diktation.app et le signe.
# La signature (certificat Developer ID s'il existe, sinon ad hoc) garde
# les autorisations Micro et Accessibilité d'un build à l'autre.
set -e
cd "$(dirname "$0")"
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"
cargo build --release
# Bibliothèques système demandées par le cœur (whisper.cpp/Metal, cpal,
# objc2) : `cargo rustc --release --lib --crate-type staticlib -- --print native-static-libs`.
LIBS="-framework AppKit -framework CoreGraphics -framework QuartzCore -framework Foundation \
  -framework CoreFoundation -framework Accelerate -framework Metal -framework MetalKit \
  -framework AudioToolbox -framework CoreAudio -framework ApplicationServices -lc++ -liconv -lobjc"
# Interface (SwiftUI).
rm -f target/Diktation
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  -import-objc-header app/diktation.h app/Sources/*.swift \
  -L target/release -ldiktation $LIBS -o target/Diktation 2>&1 | grep -v "^ld: warning" || true
test -x target/Diktation
# Outil Swift qui joint le modèle de langage d'Apple Intelligence
# (reformulation, mode commande).
swiftc -O -swift-version 5 llm/main.swift -o target/diktation-llm
APP=Diktation.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp target/Diktation "$APP/Contents/MacOS/Diktation"
cp target/diktation-llm "$APP/Contents/MacOS/diktation-llm"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Diktation</string>
  <key>CFBundleDisplayName</key><string>Diktation</string>
  <key>CFBundleIdentifier</key><string>dev.local.diktation</string>
  <key>CFBundleExecutable</key><string>Diktation</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>Diktation écoute le micro pendant que vous dictez. L'audio reste sur ce Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>Diktation colle le texte dicté dans l'app active.</string>
</dict></plist>
PLIST
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
if [ -n "$IDENTITY" ]; then
  # Hardened runtime + horodatage : requis pour la notarisation (release.sh).
  SIGN="--options runtime --timestamp --entitlements app/Diktation.entitlements"
else
  SIGN=""
fi
codesign --force $SIGN --sign "${IDENTITY:--}" --identifier dev.local.diktation.llm "$APP/Contents/MacOS/diktation-llm"
codesign --force $SIGN --sign "${IDENTITY:--}" --identifier dev.local.diktation "$APP"
echo "OK → $(pwd)/$APP (signé : ${IDENTITY:-ad hoc})"
