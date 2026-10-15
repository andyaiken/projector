#!/bin/bash
# Builds a Release Prospect.app from clean and packages it for another Mac.
#
#   tools/package.sh              signed ad hoc
#   tools/package.sh --notarise   signed with the Developer ID and notarised
#
# Writes dist/Prospect-<version>.zip and dist/Prospect-<version>.dmg. Either
# one carries the app intact on a thumb drive formatted for Windows, which a
# bare .app doesn't always survive.
#
# Signed ad hoc, the app opens when copied from a thumb drive, but a
# downloaded, emailed or AirDropped copy is blocked until it is allowed in
# System Settings › Privacy & Security. Notarised, it opens on any Mac with no
# warnings. Notarising needs, once per Mac:
#
#   - the team's Developer ID Application certificate in the keychain
#   - the notarisation password saved as a keychain profile, with
#     xcrun notarytool store-credentials prospect-notary --apple-id <Apple ID> --team-id 3G846V4G68
#
# PROSPECT_SIGN_IDENTITY and PROSPECT_NOTARY_PROFILE override the certificate
# and the profile.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/dist"
derived="$root/DerivedData"
team="3G846V4G68"
identity=""
profile=""

case "${1:-}" in
    "") ;;
    --notarise | --notarize)
        identity="${PROSPECT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
            sed -n "s/.*\"\(Developer ID Application: .* ($team)\)\"/\1/p" | head -1)}"
        profile="${PROSPECT_NOTARY_PROFILE:-prospect-notary}"
        if [[ -z "$identity" ]]; then
            echo "No Developer ID Application certificate for team $team is in the keychain." >&2
            echo "Create one in Xcode: Settings › Accounts › Manage Certificates… › + › Developer ID Application." >&2
            exit 1
        fi
        # Checked before the build rather than after it.
        if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
            echo "The notarisation profile \"$profile\" isn't saved, or Apple refused it. Save it with:" >&2
            echo "  xcrun notarytool store-credentials $profile --apple-id <your Apple ID> --team-id $team" >&2
            echo "It asks for an app-specific password, made at account.apple.com › Sign-In and Security." >&2
            exit 1
        fi
        ;;
    *)
        echo "Usage: tools/package.sh [--notarise]" >&2
        exit 1
        ;;
esac

step() { printf '\n== %s\n' "$1"; }

step "Building Release"
xcodebuild -project "$root/Prospect.xcodeproj" -scheme Prospect -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$derived" -quiet clean build
built="$derived/Build/Products/Release/Prospect.app"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$built/Contents/Info.plist")"
name="Prospect-$version"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/Prospect.app"
ditto "$built" "$app"

# Submits a file to Apple and waits for the verdict, printing Apple's log if
# it is refused.
notarise() {
    local output id
    output="$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait 2>&1)" || true
    echo "$output"
    if ! grep -q "status: Accepted" <<<"$output"; then
        id="$(awk '/^  id:/ { print $2; exit }' <<<"$output")"
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$profile" >&2
        echo "Notarisation of $(basename "$1") was refused." >&2
        exit 1
    fi
}

if [[ -n "$identity" ]]; then
    step "Signing with $identity"
    # Re-signing without --entitlements leaves none, which is what Prospect
    # needs: it isn't sandboxed and asks for no permissions.
    codesign --force --options runtime --timestamp --sign "$identity" "$app"

    step "Notarising the app"
    ditto -c -k --keepParent "$app" "$work/submit.zip"
    notarise "$work/submit.zip"
    xcrun stapler staple "$app"
fi

step "Checking the app"
codesign --verify --deep --strict "$app"
echo "Signature verifies. Runs on: $(lipo -archs "$app/Contents/MacOS/Prospect")."

mkdir -p "$dist"
rm -f "$dist/$name.zip" "$dist/$name.dmg"

step "Making $name.zip"
ditto -c -k --keepParent "$app" "$dist/$name.zip"

step "Making $name.dmg"
# The disk image opens to the app beside a link to Applications, to drag onto.
mkdir "$work/image"
ditto "$app" "$work/image/Prospect.app"
ln -s /Applications "$work/image/Applications"
hdiutil create -quiet -volname "Prospect $version" -srcfolder "$work/image" -fs HFS+ -format UDZO "$dist/$name.dmg"

if [[ -n "$identity" ]]; then
    codesign --force --timestamp --sign "$identity" "$dist/$name.dmg"
    step "Notarising the disk image"
    notarise "$dist/$name.dmg"
    xcrun stapler staple "$dist/$name.dmg"
fi

step "Done"
for f in "$dist/$name.zip" "$dist/$name.dmg"; do
    printf '%6s  %s\n' "$(du -h "$f" | cut -f1)" "${f#"$root"/}"
done
if spctl --assess --type execute "$app" 2>/dev/null; then
    echo "Gatekeeper accepts the app: it opens on any Mac running macOS 26 or later."
else
    echo "Signed ad hoc, not notarised: it opens when copied from a thumb drive, but a"
    echo "downloaded, emailed or AirDropped copy needs Open Anyway in System Settings ›"
    echo "Privacy & Security. Needs macOS 26 or later."
fi
