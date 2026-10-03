#!/usr/bin/env bash
# Notarizes the given .app or .dmg and staples the ticket.
#
#   scripts/notarize.sh dist/export/WhisperTranscriber.app
#   scripts/notarize.sh dist/WhisperTranscriber-0.1.0.dmg
#
# An .app can't be submitted directly; it is zipped with ditto and submitted, then the
# ticket is stapled to the .app. A dmg is submitted as it is.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TARGET="${1:-$APP}"
[[ -e "$TARGET" ]] || die "no file to notarize: $TARGET"

require_tool xcrun
require_notary_profile

submit() {
  local payload="$1"
  say "submitting for notarization: $(basename "$payload")"
  local output
  if ! output="$(xcrun notarytool submit "$payload" \
      --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"; then
    echo "$output" >&2
    local id
    id="$(echo "$output" | awk '/id:/ { print $2; exit }')"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization failed"
  fi
  echo "$output"

  # --wait can exit zero while the status is "Invalid".
  if ! echo "$output" | grep -q "status: Accepted"; then
    local id
    id="$(echo "$output" | awk '/id:/ { print $2; exit }')"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization was not accepted"
  fi
}

case "$TARGET" in
  *.app)
    ZIP="$DIST/$(basename "$TARGET" .app).zip"
    say "preparing the zip (notarytool does not accept an .app directory directly)"
    rm -f "$ZIP"
    # ditto: the only correct way that preserves the signature and the symlinks.
    ditto -c -k --keepParent "$TARGET" "$ZIP"
    submit "$ZIP"
    rm -f "$ZIP"
    ;;
  *.dmg)
    submit "$TARGET"
    ;;
  *)
    die "unsupported target: $TARGET (must be an .app or a .dmg)"
    ;;
esac

say "stapling the ticket"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
say "notarization ok: $(basename "$TARGET")"
