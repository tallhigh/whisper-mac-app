#!/usr/bin/env bash
# Builds the Release archive, exports it and signs it with the Developer ID.
#
# Output: dist/export/WhisperTranscriber.app — signed, verified, not yet notarized.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_tool xcodebuild
require_tool xcodegen
require_tool codesign

say "generating the project (the .xcodeproj is not kept in git — ADR-011)"
(cd "$ROOT/app" && xcodegen generate --spec project.yml >/dev/null)

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$DIST"

say "archiving (Release, arm64) — version $(marketing_version) ($(build_number))"
xcodebuild -project "$ROOT/app/WhisperTranscriber.xcodeproj" \
  -scheme WhisperTranscriber -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  archive

say "exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR"

[[ -d "$APP" ]] || die "the export produced no .app: $APP"

"$ROOT/scripts/sign.sh"
