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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TrackCut"
# ditto keeps the framework's symlinks and Sparkle's own signature on it and its helpers
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Both targets look their strings up in the main bundle, so the tables go into the app's own Resources.
# English is the text in the code; en.lproj only adds singular forms.
for lproj in Localizations/*.lproj; do
    ditto "$lproj" "$APP/Contents/Resources/${lproj:t}"
    plutil -convert binary1 "$APP/Contents/Resources/${lproj:t}"/*
done

# The icon is an Icon Composer file. actool turns it into Assets.car, which macOS 26 and later draw with
# Liquid Glass, and AppIcon.icns for older systems. actool ships with Xcode only, so fall back to
# Xcode.app when the Command Line Tools are selected.
if ! xcrun --find actool >/dev/null 2>&1 && [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 15.0 --app-icon AppIcon \
    --output-partial-info-plist build/AppIcon-partial.plist >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ja</string>
    </array>
    <key>CFBundleName</key><string>TrackCut</string>
    <key>CFBundleDisplayName</key><string>TrackCut</string>
    <key>CFBundleIdentifier</key><string>com.9tmr.TrackCut</string>
    <key>CFBundleExecutable</key><string>TrackCut</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
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
        <!-- A folder dropped on the Dock icon: its audio files are joined -->
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>TrackCut Project</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.9tmr.trackcut.project</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.9tmr.trackcut.project</string>
            <key>UTTypeDescription</key><string>TrackCut Project</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.json</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>trackcut</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Signs the app only: Sparkle.framework keeps the signature it ships with
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION)"
