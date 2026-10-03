#!/usr/bin/env bash
# Builds the release notes from the conventional commits since the last tag.
#
#   scripts/release_notes.sh 0.1.0 > dist/RELEASE_NOTES.md
#
# A version can opt out of the changelog by committing docs/release-notes/vX.Y.Z.md;
# that file is then used verbatim in place of the commit sections. v1.0.0 does this,
# because a first release has no previous version to list changes against — it
# describes what the app does instead.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VERSION="${1:-$(marketing_version)}"
PREVIOUS="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
RANGE="${PREVIOUS:+$PREVIOUS..}HEAD"
HANDWRITTEN="$ROOT/docs/release-notes/v$VERSION.md"

section() {
  local prefix="$1" title="$2"
  local lines
  lines="$(git -C "$ROOT" log "$RANGE" --no-merges --pretty=format:'%s' \
    | grep "^$prefix" | sed "s/^$prefix[(:][^)]*)\{0,1\}: \{0,1\}/- /;s/^$prefix: /- /" || true)"
  [[ -z "$lines" ]] && return 0
  printf '### %s\n%s\n\n' "$title" "$lines"
}

printf '## v%s\n\n' "$VERSION"

if [[ -f "$HANDWRITTEN" ]]; then
  cat "$HANDWRITTEN"
  printf '\n'
else
  section feat "New"
  section fix "Fixed"
  section docs "Documentation"
  section build "Build and release"
  section refactor "Internal"
fi

cat <<'MD'
### Installing

1. Download and open the `.dmg`, then drag the app into **Applications**.
2. On first launch the app installs an isolated Python environment of its own
   (~850 MB download, once only). Your system Python and Homebrew are untouched.
3. Models are downloaded into `~/.cache/whisper`; any models you already have are used.

Requirements: an Apple Silicon Mac, macOS 14.4 or later.
MD

if [[ -n "$PREVIOUS" && ! -f "$HANDWRITTEN" ]]; then
  printf '\n**Full changelog:** `%s..v%s`\n' "$PREVIOUS" "$VERSION"
fi
