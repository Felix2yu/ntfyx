#!/bin/bash
set -e

echo "Building ntfyx app bundle..."

# Build the executable. `-disable-sandbox` is required for the @Observable macro
# plugin when building under a restricted (sandboxed) SwiftPM environment.
swift build -c release -Xswiftc -disable-sandbox

# Create app bundle structure
APP_NAME="ntfyx"
APP_BUNDLE="$APP_NAME.app"
BUILD_DIR=".build/release"

rm -rf "$BUILD_DIR/$APP_BUNDLE"
mkdir -p "$BUILD_DIR/$APP_BUNDLE/Contents/MacOS"
mkdir -p "$BUILD_DIR/$APP_BUNDLE/Contents/Resources"

# Copy executables. `ntfyx` is the menu-bar GUI (and `serve` daemon); `ntfyxctl` is the
# auth/sync/init command line tool shipped alongside it inside the bundle.
cp "$BUILD_DIR/$APP_NAME" "$BUILD_DIR/$APP_BUNDLE/Contents/MacOS/"
cp "$BUILD_DIR/ntfyxctl" "$BUILD_DIR/$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist
cp "Resources/Info.plist" "$BUILD_DIR/$APP_BUNDLE/Contents/"

# Copy icon
cp "Resources/ntfyx.icns" "$BUILD_DIR/$APP_BUNDLE/Contents/Resources/"

# Copy SwiftPM resource bundles (Localizable.xcstrings compiles into NtfyxCore's bundle;
# without it the app has no translation tables and every string falls back to Chinese).
for bundle in "$BUILD_DIR"/*.bundle; do
    [ -d "$bundle" ] || continue
    rm -rf "$BUILD_DIR/$APP_BUNDLE/Contents/Resources/$(basename "$bundle")"
    cp -R "$bundle" "$BUILD_DIR/$APP_BUNDLE/Contents/Resources/"
    echo "Bundled resources: $(basename "$bundle")"
done

# Ad-hoc sign the app bundle (required for notifications to work)
echo "Signing app bundle..."
codesign --force --deep --sign - "$BUILD_DIR/$APP_BUNDLE"

echo "✅ App bundle created at: $BUILD_DIR/$APP_BUNDLE"
echo ""
echo "To install:"
echo "  sudo cp -r $BUILD_DIR/$APP_BUNDLE /Applications/"
echo ""
echo "To run as a Dock app (opens the notification history window):"
echo "  open $BUILD_DIR/$APP_BUNDLE"
echo ""
echo "To run as a background service (menu bar only, no Dock icon):"
echo "  $BUILD_DIR/$APP_BUNDLE/Contents/MacOS/$APP_NAME serve"
echo ""
echo "The command line tool lives next to it:"
echo "  $BUILD_DIR/$APP_BUNDLE/Contents/MacOS/ntfyxctl auth list"
