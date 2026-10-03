#!/usr/bin/env bash
# Signs the embedded binaries and then the .app, inside-out, and verifies the result.
#
# `codesign --deep` is not used: Apple doesn't recommend it and it hides inner failures.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_tool codesign
[[ -d "$APP" ]] || die "no .app to sign: $APP — run 'make archive' first"

UV_BINARY="$APP/Contents/MacOS/uv"
[[ -x "$UV_BINARY" ]] || die "the embedded uv is missing from the bundle: $UV_BINARY"

# Measured in Phase 0: Xcode does not re-sign the uv copied by the Copy Files phase;
# Astral's signature (TeamIdentifier 2DC432GLL2) stays exactly as it was. Without a
# re-sign, notarization complains about the mixed team identifier.
say "re-signing the embedded uv"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" "$UV_BINARY"

say "signing the .app"
codesign --force --options runtime --timestamp \
  --entitlements "$ROOT/app/WhisperTranscriber/WhisperTranscriber.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP"

say "verifying the signature"
codesign --verify --strict --verbose=2 "$UV_BINARY"
codesign --verify --deep --strict --verbose=2 "$APP"

# codesign writes its details to stderr. We capture the output into a variable:
# in the `codesign ... | grep -q` pattern, grep closes the pipe at the first match,
# which sends codesign SIGPIPE and produces a false failure under `pipefail`.
APP_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
UV_INFO="$(codesign -dv --verbose=4 "$UV_BINARY" 2>&1)"

# Hardened Runtime is a notarization requirement; we want to see the flag really set.
case "$APP_INFO" in
  *"(runtime)"*) ;;
  *) die "the Hardened Runtime flag is missing — check ENABLE_HARDENED_RUNTIME and --options runtime" ;;
esac

TEAM_IN_APP="$(awk -F'=' '/TeamIdentifier/ { print $2 }' <<<"$APP_INFO")"
TEAM_IN_UV="$(awk -F'=' '/TeamIdentifier/ { print $2 }' <<<"$UV_INFO")"
[[ "$TEAM_IN_APP" == "$TEAM_IN_UV" ]] \
  || die "the team identifiers differ (.app=$TEAM_IN_APP uv=$TEAM_IN_UV)"

# Sparkle brings nested code of its own — a helper app and XPC services that do the part an
# app cannot do to itself. Xcode signs them as embedded content, but a mis-signed one only
# shows up as a notarization rejection minutes later, or worse as an update that fails on a
# user's machine. Checked here instead (ADR-020).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  say "verifying the Sparkle framework"
  codesign --verify --strict --verbose=2 "$SPARKLE"
  SPARKLE_INFO="$(codesign -dv --verbose=4 "$SPARKLE" 2>&1)"
  TEAM_IN_SPARKLE="$(awk -F'=' '/TeamIdentifier/ { print $2 }' <<<"$SPARKLE_INFO")"
  [[ "$TEAM_IN_SPARKLE" == "$TEAM_IN_APP" ]] \
    || die "Sparkle is signed by another team (.app=$TEAM_IN_APP sparkle=$TEAM_IN_SPARKLE)"

  # Every nested executable has to carry Hardened Runtime too, or notarization refuses the
  # whole bundle. Checked one by one rather than trusted.
  while IFS= read -r nested; do
    NESTED_INFO="$(codesign -dv --verbose=4 "$nested" 2>&1)"
    case "$NESTED_INFO" in
      *"(runtime)"*) ;;
      *) die "nested code without Hardened Runtime: ${nested#"$APP/"}" ;;
    esac
  done < <(find "$SPARKLE" \( -name '*.app' -o -name '*.xpc' \) -maxdepth 4)
  say "Sparkle ok — $(find "$SPARKLE" \( -name '*.app' -o -name '*.xpc' \) -maxdepth 4 | wc -l | tr -d ' ') nested helpers verified"
else
  warn "Sparkle.framework is not in the bundle — this build cannot update itself"
fi

say "signature ok — team identifier $TEAM_IN_APP"
