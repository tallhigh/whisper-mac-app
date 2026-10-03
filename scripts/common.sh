# Helpers shared by the release scripts. Not run directly; sourced.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
ARCHIVE="$DIST/WhisperTranscriber.xcarchive"
EXPORT_DIR="$DIST/export"
APP="$EXPORT_DIR/WhisperTranscriber.app"

# shellcheck disable=SC1091
if [[ -f "$ROOT/scripts/local.env" ]]; then
  source "$ROOT/scripts/local.env"
fi

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
TEAM_ID="${TEAM_ID:-AL9CGWVTYB}"
NOTARY_PROFILE="${NOTARY_PROFILE:-WHISPER_NOTARY}"
GH_REPO="${GH_REPO:-}"

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found"
}

# MARKETING_VERSION from app/Version.xcconfig.
marketing_version() {
  awk -F'=' '/^MARKETING_VERSION/ { gsub(/ /, "", $2); print $2 }' "$ROOT/app/Version.xcconfig"
}

build_number() {
  awk -F'=' '/^CURRENT_PROJECT_VERSION/ { gsub(/ /, "", $2); print $2 }' "$ROOT/app/Version.xcconfig"
}

dmg_path() {
  echo "$DIST/WhisperTranscriber-$(marketing_version).dmg"
}

require_notary_profile() {
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "the notarytool profile '$NOTARY_PROFILE' does not work. docs/BUILD_AND_RELEASE.md → Prerequisites"
}
