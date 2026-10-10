#!/bin/zsh
# Builds TrackCut.app into build/
#
# The version comes from TRACKCUT_VERSION (release.sh sets it), else from the latest v* tag. It is used
# for both CFBundleShortVersionString and CFBundleVersion, which Sparkle compares against the feed.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${TRACKCUT_VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)}"
VERSION="${${VERSION#v}:-0.0.0}"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "error: version '$VERSION' is not of the form X.Y.Z" >&2
    exit 1
fi

# SwiftPM links with --sysroot only, so clang records the deployment target (15.0) as the SDK version.
# AppKit picks the design from that version, and would give the app the pre-Liquid Glass look. Passing
# -isysroot to the link step records the SDK's real version.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
#
# The rpath lets the binary find Sparkle.framework in Contents/Frameworks.
swift build -c release -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/TrackCut"
APP="build/TrackCut.app"

# Fail rather than ship the old look if the flags above stop working
RECORDED_SDK="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "sdk" { print $2; exit }')"
if (( ${${RECORDED_SDK%%.*}:-0} < 26 )); then
    echo "error: the binary records SDK ${RECORDED_SDK:-(none)}, but the Liquid Glass design needs 26 or later" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/TrackCut"
# ditto keeps the framework's symlinks and Sparkle's own signature on it and its helpers
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>CFBundleName</key><string>TrackCut</string>
    <key>CFBundleDisplayName</key><string>TrackCut</string>
    <key>CFBundleIdentifier</key><string>com.9tmr.TrackCut</string>
    <key>CFBundleExecutable</key><string>TrackCut</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Sparkle. release.sh uploads appcast.xml to every release, signed with the private half of
         SUPublicEDKey, which is kept in the maintainer's login Keychain (account com.9tmr.TrackCut) -->
    <key>SUFeedURL</key><string>https://github.com/tamura09/trackcut/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>uJ5tLnIjCqBKZz5NcihufwCW4oVcW3xweHln0VOYhuo=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
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

# Signs the app only: Sparkle.framework keeps the signature it ships with
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION)"
