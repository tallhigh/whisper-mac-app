#!/usr/bin/env bash
# Writes the Sparkle appcast for one release — docs/DECISIONS.md → ADR-020.
#
#   scripts/make_appcast.sh 1.1.1
#
# Deliberately not `generate_appcast`: that tool scans a directory and infers a whole feed
# from whatever archives it finds, which with one .dmg per release in dist/ means guessing at
# what we already know exactly. `sign_update` gives the signature and the length, and the
# rest of the item is the version we are releasing.
#
# A one-item feed is all Sparkle needs: it compares the newest item with the running build.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VERSION="${1:-$(marketing_version)}"
BUILD="$(build_number)"
DMG="$DIST/WhisperTranscriber-$VERSION.dmg"
SIGN_UPDATE="$ROOT/vendor/sparkle/bin/sign_update"
OUT="$DIST/appcast.xml"

[[ -f "$DMG" ]] || die "no dmg to describe: $DMG — run 'make dmg' first"
[[ -x "$SIGN_UPDATE" ]] || die "Sparkle's tools are missing — run 'make bootstrap'"

# The public key baked into the app has to be the counterpart of the private key in the
# keychain, or every installed copy refuses every update — a failure that would only show up
# on someone else's machine. Checked against the *built* bundle, not against project.yml.
GENERATE_KEYS="$ROOT/vendor/sparkle/bin/generate_keys"
if [[ -x "$GENERATE_KEYS" && -d "$APP" ]]; then
  KEY_IN_KEYCHAIN="$("$GENERATE_KEYS" -p 2>/dev/null | tail -1 | tr -d '[:space:]')"
  KEY_IN_APP="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" \
    2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$KEY_IN_KEYCHAIN" && -n "$KEY_IN_APP" && "$KEY_IN_KEYCHAIN" != "$KEY_IN_APP" ]]; then
    die "SUPublicEDKey in the bundle is not the keychain key's counterpart — updates would all be refused"
  fi
fi

# The private half lives in the keychain and nowhere else; sign_update finds it there. Without
# it an update would be refused everywhere, so a missing key stops the release rather than
# producing an unsigned feed.
say "signing the dmg for Sparkle"
SIGNATURE_LINE="$("$SIGN_UPDATE" "$DMG")" \
  || die "sign_update failed — is the EdDSA key in the keychain? See docs/BUILD_AND_RELEASE.md"

# sign_update prints the two attributes ready to paste:
#   sparkle:edSignature="…" length="…"
[[ "$SIGNATURE_LINE" == *"sparkle:edSignature="* ]] \
  || die "sign_update produced no signature: $SIGNATURE_LINE"

DOWNLOAD_URL="https://github.com/tallhigh/whisper-mac-app/releases/download/v$VERSION/$(basename "$DMG")"
PUBLISHED="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
MINIMUM_OS="$(awk -F'"' '/macOS:/ { print $2 }' "$ROOT/app/project.yml" | head -1)"
: "${MINIMUM_OS:=14.4}"

# The release notes already exist as Markdown; Sparkle wants HTML or plain text, and a
# <description> in CDATA keeps it readable in the update window without a converter.
NOTES_FILE="$DIST/RELEASE_NOTES.md"
if [[ -f "$NOTES_FILE" ]]; then
  NOTES="$(cat "$NOTES_FILE")"
else
  NOTES="Version $VERSION"
fi

say "writing $(basename "$OUT")"
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Whisper Transcriber</title>
    <link>https://github.com/tallhigh/whisper-mac-app</link>
    <description>Updates for Whisper Transcriber</description>
    <language>en</language>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUBLISHED</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[
$NOTES
      ]]></description>
      <enclosure url="$DOWNLOAD_URL" type="application/octet-stream" $SIGNATURE_LINE />
    </item>
  </channel>
</rss>
XML

# A feed that doesn't parse would be discovered by users, not by us.
xmllint --noout "$OUT" || die "the generated appcast is not valid XML"

# And a signature that doesn't verify would be discovered by them too. The one in the feed is
# checked against the dmg it claims to describe.
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUT")"
[[ -n "$SIGNATURE" ]] || die "no signature ended up in the appcast"
"$SIGN_UPDATE" --verify "$DMG" "$SIGNATURE" >/dev/null \
  || die "the signature in the appcast does not verify against $(basename "$DMG")"
say "signature verified"

say "appcast ready: $OUT"
