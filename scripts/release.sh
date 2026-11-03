#!/bin/bash
# Publishes a new version that existing installs pick up through Sparkle.
#
#   scripts/release.sh <version> <release-notes.md>
#
# 1. bumps the version in Resources/Info.plist and builds build/Mirra.app
# 2. zips it and signs the zip with the EdDSA key (checked against the app's public key)
# 3. commits, pushes, and creates the GitHub release with Mirra.zip attached
# 4. adds the release to docs/appcast.xml and pushes it (GitHub Pages serves the feed)
#
# The private key lives outside the repo: $MIRRA_SPARKLE_KEY or ~/.config/mirra/sparkle_ed25519.pem.
# Back it up — without it, existing installs can't be updated.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: release.sh <version> <notes.md>}
NOTES=${2:?usage: release.sh <version> <notes.md>}
REPO=Hanqing/Mirra
KEY=${MIRRA_SPARKLE_KEY:-$HOME/.config/mirra/sparkle_ed25519.pem}
OPENSSL=${OPENSSL:-/opt/homebrew/bin/openssl}
PLIST=Resources/Info.plist

[ -f "$KEY" ] || { echo "error: signing key not found: $KEY" >&2; exit 1; }
[ -f "$NOTES" ] || { echo "error: release notes not found: $NOTES" >&2; exit 1; }
"$OPENSSL" version | grep -q "^OpenSSL [3-9]" || { echo "error: needs OpenSSL 3+ for Ed25519 ($OPENSSL)" >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "error: commit or stash your changes first" >&2; exit 1; }
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "error: v$VERSION already exists" >&2; exit 1
fi

# 1. Version and build
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
./scripts/build-app.sh

# 2. Zip and sign
ZIP=build/Mirra.zip
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Mirra.app "$ZIP"
"$OPENSSL" pkeyutl -sign -inkey "$KEY" -rawin -in "$ZIP" -out build/Mirra.zip.sig
SIGNATURE=$(base64 < build/Mirra.zip.sig | tr -d '\n')
LENGTH=$(stat -f%z "$ZIP")

# Verify against the public key the app ships with, exactly as Sparkle will.
PUBLIC=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST")
python3 -c "import base64,sys; sys.stdout.buffer.write(bytes.fromhex('302a300506032b6570032100') + base64.b64decode('$PUBLIC'))" > build/public.der
"$OPENSSL" pkeyutl -verify -pubin -keyform DER -inkey build/public.der -rawin -in "$ZIP" -sigfile build/Mirra.zip.sig >/dev/null \
  || { echo "error: signature does not match SUPublicEDKey" >&2; exit 1; }
echo "Signed $ZIP ($LENGTH bytes)"

# 3. Commit, push, release
git commit -q -am "Release $VERSION"
git push -q
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Mirra $VERSION" --notes-file "$NOTES"

# 4. Appcast
python3 scripts/appcast.py --version "$VERSION" --build "$BUILD" \
  --url "https://github.com/$REPO/releases/download/v$VERSION/Mirra.zip" \
  --length "$LENGTH" --signature "$SIGNATURE" --notes "$NOTES"
git add docs/appcast.xml
git commit -q -m "Appcast: Mirra $VERSION"
git push -q
echo "Released Mirra $VERSION. GitHub Pages updates the feed in a minute or two."
