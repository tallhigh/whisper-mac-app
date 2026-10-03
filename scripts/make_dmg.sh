#!/usr/bin/env bash
# Builds a signed .dmg from the notarized .app, notarizes it and runs it past Gatekeeper.
#
# The order matters: the .app's ticket must be stapled BEFORE the dmg is created.
# When the user copies the app out of the dmg into Applications, Gatekeeper can't verify
# offline unless the .app has a ticket of its own.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_tool hdiutil
require_tool codesign
require_tool spctl

[[ -d "$APP" ]] || die "no .app: $APP — run 'make archive' first"

if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
  die "the .app is not notarized. Run 'make notarize' first."
fi

DMG="$(dmg_path)"
STAGE="$DIST/dmg-stage"

say "preparing the dmg: $(basename "$DMG")"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
# ditto doesn't break the signature; cp -R can drop some xattrs.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Whisper Transcriber" \
  -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

say "signing the dmg"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

"$ROOT/scripts/notarize.sh" "$DMG"

# spctl writes its details to stderr; we capture the output into a variable and search
# there (cutting the pipe with `grep -q` produces a false failure under pipefail).
gatekeeper_accepts() {
  local output
  output="$(spctl -a -vvv "$@" 2>&1 || true)"
  printf '%s\n' "$output" >&2
  [[ "$output" == *accepted* ]]
}

say "Gatekeeper check"
gatekeeper_accepts -t install "$DMG" || die "the dmg did not pass Gatekeeper"

# Clean-machine test: mark the file as if it had been downloaded and ask Gatekeeper again.
# Skip this step and the user can get the "app is damaged and can't be opened" error.
say "quarantine (downloaded-file) test"
QUARANTINED="$DIST/quarantine-test.dmg"
MOUNT=""
cleanup_quarantine_test() {
  [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  [[ -n "$MOUNT" ]] && rm -rf "$MOUNT"
  rm -f "$QUARANTINED"
}
trap cleanup_quarantine_test EXIT

cp "$DMG" "$QUARANTINED"
xattr -w com.apple.quarantine "0081;00000000;Safari;" "$QUARANTINED"
gatekeeper_accepts -t install "$QUARANTINED" || die "the quarantined dmg did not pass Gatekeeper"

MOUNT="$(mktemp -d)"
hdiutil attach "$QUARANTINED" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
gatekeeper_accepts -t exec "$MOUNT/$(basename "$APP")" \
  || die "the app inside the dmg did not pass Gatekeeper"

SIZE_MB=$(( $(stat -f%z "$DMG") / 1024 / 1024 ))
say "dmg ready: $(basename "$DMG") — ${SIZE_MB} MB"
# Expected ~25-40 MB. Larger than that means the runtime or a model got into the bundle.
if (( SIZE_MB > 50 )); then
  die "the dmg exceeded 50 MB (${SIZE_MB} MB) — audit the Copy Bundle Resources phase"
fi
