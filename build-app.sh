#!/bin/zsh
# Builds TrackCut.app into build/
set -euo pipefail
cd "$(dirname "$0")"

# SwiftPM links with --sysroot only, so clang records the deployment target (15.0) as the SDK version.
# AppKit picks the design from that version, and would give the app the pre-Liquid Glass look. Passing
# -isysroot to the link step records the SDK's real version.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
swift build -c release -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK"
BIN="$(swift build -c release --show-bin-path)/TrackCut"
APP="build/TrackCut.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TrackCut"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>CFBundleName</key><string>TrackCut</string>
    <key>CFBundleDisplayName</key><string>TrackCut</string>
    <key>CFBundleIdentifier</key><string>wtf.tmrh.TrackCut</string>
    <key>CFBundleExecutable</key><string>TrackCut</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Audio</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.xiph.flac</string>
                <string>public.mpeg-4-audio</string>
                <string>com.microsoft.waveform-audio</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
