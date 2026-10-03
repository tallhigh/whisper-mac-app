#!/usr/bin/env bash
# Downloads Sparkle's command-line tools and verifies the archive's sha256.
#
# Only the tools land here — `generate_keys` to create the EdDSA key pair once, and
# `sign_update` to sign each release's .dmg. The framework that ships inside the app comes
# from Swift Package Manager instead (app/project.yml), so that Xcode embeds and signs it
# along with its helper apps; getting that right by hand is the part Sparkle exists to do.
#
# Nothing fetched here ever goes into the .app, and vendor/ is not committed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"

DEST="$ROOT/vendor/sparkle"
ASSET="Sparkle-${SPARKLE_VERSION}.tar.xz"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/${ASSET}"

if [[ -x "$DEST/bin/sign_update" ]] && [[ -f "$DEST/.version" ]] \
  && [[ "$(cat "$DEST/.version")" == "$SPARKLE_VERSION" ]]; then
  echo "Sparkle ${SPARKLE_VERSION} tools are already in place: $DEST/bin"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "downloading Sparkle ${SPARKLE_VERSION} tools…"
curl -fsSL --retry 3 -o "$WORK/$ASSET" "$URL"

echo "verifying sha256…"
ACTUAL="$(shasum -a 256 "$WORK/$ASSET" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SPARKLE_SHA256" ]]; then
  echo "error: sha256 mismatch for $ASSET" >&2
  echo "  expected: $SPARKLE_SHA256" >&2
  echo "  actual:   $ACTUAL" >&2
  echo "  if the version was bumped on purpose, update SPARKLE_SHA256 in scripts/versions.env" >&2
  exit 1
fi

tar -xJf "$WORK/$ASSET" -C "$WORK"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$WORK/bin" "$DEST/bin"
printf '%s\n' "$SPARKLE_VERSION" > "$DEST/.version"
xattr -cr "$DEST" 2>/dev/null || true

echo "ready: $DEST/bin ($(ls "$DEST/bin" | tr '\n' ' '))"
