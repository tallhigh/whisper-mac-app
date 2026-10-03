#!/usr/bin/env bash
# The full release flow: version → test → archive → notarize → dmg → GitHub Release.
#
#   scripts/release.sh 0.1.0
#
# It stops at the first failing step. The tag is created AFTER the dmg is ready, so a
# half-finished release leaves no tag in the repository.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "usage: scripts/release.sh X.Y.Z"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the version must look like X.Y.Z: $VERSION"

require_tool git
require_tool gh
require_tool xmllint
require_notary_profile
# Checked here rather than after notarizing: a release whose appcast cannot be signed is a
# release no installed copy would accept, and finding that out at the end wastes a
# notarization round (ADR-020).
[[ -x "$ROOT/vendor/sparkle/bin/sign_update" ]] \
  || die "Sparkle's tools are missing — run 'make bootstrap'"

cd "$ROOT"

[[ -z "$(git status --porcelain)" ]] || die "the working copy is not clean — commit first"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "releases are only made from main"
git rev-parse "v$VERSION" >/dev/null 2>&1 && die "the tag v$VERSION already exists"
gh auth status >/dev/null 2>&1 || die "not logged in to gh — run 'gh auth login'"

say "tests"
make test

say "writing version $VERSION"
NEXT_BUILD=$(( $(build_number) + 1 ))
# The version numbers live only in Version.xcconfig; the Xcode project reads them there.
sed -i '' \
  -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $VERSION/" \
  -e "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $NEXT_BUILD/" \
  app/Version.xcconfig
git add app/Version.xcconfig
git commit -q -m "build: version $VERSION ($NEXT_BUILD)"

say "archive and signature"
./scripts/archive.sh

say "notarizing the app"
./scripts/notarize.sh "$APP"

say "dmg"
./scripts/make_dmg.sh

DMG="$(dmg_path)"
say "release notes"
./scripts/release_notes.sh "$VERSION" > "$DIST/RELEASE_NOTES.md"

# The appcast is what installed copies read to find this release, so it goes up with the
# dmg as an asset of the same release (ADR-020). It needs the notes, hence the order.
say "appcast"
./scripts/make_appcast.sh "$VERSION"

say "tag and GitHub Release"
git tag -a "v$VERSION" -m "v$VERSION"
git push origin main
git push origin "v$VERSION"

REPO_ARGS=()
[[ -n "$GH_REPO" ]] && REPO_ARGS=(--repo "$GH_REPO")
gh release create "v$VERSION" "$DMG" "$DIST/appcast.xml" \
  --title "v$VERSION" \
  --notes-file "$DIST/RELEASE_NOTES.md" \
  "${REPO_ARGS[@]}"

say "released: v$VERSION — $(basename "$DMG")"
