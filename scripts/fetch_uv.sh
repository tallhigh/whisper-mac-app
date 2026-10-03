#!/usr/bin/env bash
# Downloads the embedded uv binary, verifies its sha256 and puts it where the bundle
# copies it from. Only `uv` is fetched; `uvx` isn't needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"

ARCH="aarch64-apple-darwin"
ASSET="uv-${ARCH}.tar.gz"
BASE="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"
DEST="$ROOT/app/WhisperTranscriber/Resources/bin/uv"

if [[ -x "$DEST" ]] && "$DEST" --version 2>/dev/null | grep -q "uv ${UV_VERSION}"; then
  echo "uv ${UV_VERSION} is already in place: $DEST"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "downloading uv ${UV_VERSION}…"
curl -fsSL --retry 3 -o "$WORK/$ASSET"         "$BASE/$ASSET"
curl -fsSL --retry 3 -o "$WORK/$ASSET.sha256"  "$BASE/$ASSET.sha256"

echo "verifying sha256…"
( cd "$WORK" && shasum -a 256 -c "$ASSET.sha256" )

tar -xzf "$WORK/$ASSET" -C "$WORK"
mkdir -p "$(dirname "$DEST")"
install -m 0755 "$WORK/uv-${ARCH}/uv" "$DEST"

# A quarantine flag inherited by the downloaded file breaks signing and execution.
xattr -c "$DEST" 2>/dev/null || true

echo "ready: $DEST ($("$DEST" --version))"
