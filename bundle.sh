#!/bin/zsh

# Build script that packages Cpuline as a macOS .app bundle
# This script:
# 1. Builds the project in release mode (universal: arm64 + x86_64)
# 2. Wraps the binary in .build/Cpuline.app with its icon (make-icon.swift)
# 3. Bakes the git commit count into Info.plist as the build number
# 4. Ad-hoc signs the bundle

set -e

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

APP_NAME="Cpuline"
APP_DIR=".build/$APP_NAME.app"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"  # 0 before the first commit
ARCHS=(--arch arm64 --arch x86_64)  # universal, so the app also runs on Intel Macs

echo "🔨 Building in release mode..."
swift build --configuration release ${ARCHS[@]}

echo "📦 Creating $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$(swift build --configuration release ${ARCHS[@]} --show-bin-path)/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "🎨 Rendering app icon..."
rm -rf .build/AppIcon.iconset
swift make-icon.swift .build/AppIcon.iconset
iconutil --convert icns .build/AppIcon.iconset --output "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>org.camerlo.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.$BUILD_NUMBER</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "🔏 Signing..."
codesign --force --sign - "$APP_DIR"

echo "✅ Built $SCRIPT_DIR/$APP_DIR"
echo "   Run: open $APP_DIR    Install: cp -R $APP_DIR /Applications/"
