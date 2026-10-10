#!/bin/zsh
# Builds, signs and publishes a TrackCut release on GitHub.
#
#   ./release.sh <version> <release-notes.md> [--no-publish]
#
# Leaves build/TrackCut-<version>-arm64.zip and build/appcast.xml, then creates the v<version> release
# on the commit at origin/main with both attached. The app's Sparkle feed is the appcast.xml of the
# latest release, so publishing the release is what offers the update to users.
#
# The release notes (Markdown) become both the GitHub release body and the notes Sparkle shows.
# --no-publish stops after writing the files, for checking them or testing an update locally.
#
# The archive and the appcast are signed with the EdDSA key in the login Keychain (account
# com.9tmr.TrackCut), whose public half is SUPublicEDKey in build-app.sh.
set -euo pipefail
cd "$(dirname "$0")"

REPO="tamura09/trackcut"
KEY_ACCOUNT="com.9tmr.TrackCut"
MIN_SYSTEM_VERSION="15.0.0"

usage() {
    echo "usage: $0 <version> <release-notes.md> [--no-publish]" >&2
    exit 2
}
(( $# >= 2 && $# <= 3 )) || usage
VERSION="$1"
NOTES="$2"
PUBLISH=1
if (( $# == 3 )); then
    [[ "$3" == "--no-publish" ]] || usage
    PUBLISH=0
fi
TAG="v$VERSION"

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "error: version '$VERSION' is not of the form X.Y.Z" >&2
    exit 1
fi
if [[ ! -s "$NOTES" ]]; then
    echo "error: release notes '$NOTES' are missing or empty" >&2
    exit 1
fi
# The notes go into a CDATA section, which this would end early
if grep -q ']]>' "$NOTES"; then
    echo "error: the release notes contain ']]>'" >&2
    exit 1
fi

# Sparkle's signing tool comes with the package
swift package resolve
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"

if (( PUBLISH )); then
    # Release exactly what is on main, so the tag, the archive and the source match
    git fetch --quiet origin main --tags
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "error: the working tree has uncommitted changes" >&2
        exit 1
    fi
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
        echo "error: HEAD is not origin/main; check out the commit to release" >&2
        exit 1
    fi
    if git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
        echo "error: tag $TAG already exists" >&2
        exit 1
    fi
    LATEST="$(gh release view --repo "$REPO" --json tagName --jq .tagName 2>/dev/null || true)"
    if [[ -n "$LATEST" && "$(printf '%s\n' "$VERSION" "${LATEST#v}" | sort -V | tail -1)" == "${LATEST#v}" ]]; then
        echo "error: $VERSION is not newer than the latest release $LATEST" >&2
        exit 1
    fi
fi

TRACKCUT_VERSION="$VERSION" ./build-app.sh

APP="build/TrackCut.app"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/TrackCut")"
if [[ "$ARCHS" != "arm64" ]]; then
    echo "error: expected an arm64-only binary, got: $ARCHS" >&2
    exit 1
fi

# A key that does not match the app's SUPublicEDKey would publish an update every install rejects
KEYCHAIN_KEY="$(.build/artifacts/sparkle/Sparkle/bin/generate_keys --account "$KEY_ACCOUNT" -p)"
BUNDLE_KEY="$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist")"
if [[ "$KEYCHAIN_KEY" != "$BUNDLE_KEY" ]]; then
    echo "error: the Keychain key ($KEYCHAIN_KEY) does not match SUPublicEDKey ($BUNDLE_KEY)" >&2
    exit 1
fi

ZIP_NAME="TrackCut-$VERSION-arm64.zip"
ZIP="build/$ZIP_NAME"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"

# Prints `sparkle:edSignature="..." length="..."` for the enclosure
ENCLOSURE_ATTRS="$("$SIGN_UPDATE" --account "$KEY_ACCOUNT" "$ZIP")"

APPCAST="build/appcast.xml"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>TrackCut</title>
        <link>https://github.com/$REPO</link>
        <item>
            <title>TrackCut $VERSION</title>
            <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases</sparkle:fullReleaseNotesLink>
            <description sparkle:format="markdown"><![CDATA[
$(cat "$NOTES")
]]></description>
            <enclosure url="https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME" type="application/octet-stream" $ENCLOSURE_ATTRS />
        </item>
    </channel>
</rss>
XML
# Embeds the feed's signature, which SURequireSignedFeed makes the app check
"$SIGN_UPDATE" --account "$KEY_ACCOUNT" "$APPCAST"
"$SIGN_UPDATE" --verify --account "$KEY_ACCOUNT" "$APPCAST"

echo "Archive: $ZIP"
echo "SHA-256: $SHA256"
echo "Feed:    $APPCAST"

if (( ! PUBLISH )); then
    exit 0
fi

BODY="build/release-notes-$VERSION.md"
{
    cat "$NOTES"
    printf '\nSHA-256 of `%s`: `%s`\n' "$ZIP_NAME" "$SHA256"
} > "$BODY"

printf 'Publish %s from %s to %s? [y/N] ' "$TAG" "$(git rev-parse --short HEAD)" "$REPO"
read -r ANSWER
if [[ "$ANSWER" != [yY] ]]; then
    echo "Not published. The files are left in build/." >&2
    exit 1
fi

gh release create "$TAG" "$ZIP" "$APPCAST" \
    --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "TrackCut $VERSION" --notes-file "$BODY" --latest

echo
echo "Released $TAG. Update Casks/trackcut.rb in tamura09/homebrew-tap:"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA256\""
