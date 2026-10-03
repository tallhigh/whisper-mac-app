#!/usr/bin/env bash
# Installs the isolated Python runtime.
#
# This script is the exact counterpart of the steps in docs/PYTHON_RUNTIME.md and the
# reference implementation for RuntimeProvisioner on the Swift side. The step order, the
# environment variables and the verifications must stay identical between the two.
#
# Usage: scripts/provision_runtime.sh [--force]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
source "$ROOT/scripts/versions.env"

SUPPORT="$HOME/Library/Application Support/WhisperTranscriber"
RUNTIME="$SUPPORT/runtime"
VENV="$RUNTIME/venv"
LOGDIR="$SUPPORT/logs"
UV="$ROOT/app/WhisperTranscriber/Resources/bin/uv"
REQ="$ROOT/python/requirements.txt"

[[ -x "$UV" ]] || { echo "uv not found: $UV — run 'make bootstrap' first." >&2; exit 1; }

if [[ "${1:-}" == "--force" ]]; then
  echo "--force: deleting the existing runtime"
  rm -rf "$RUNTIME"
fi

mkdir -p "$RUNTIME" "$LOGDIR"
LOG="$LOGDIR/provision-$(date +%Y%m%d-%H%M%S).log"
echo "log: $LOG"

# A dirty shell profile can break the environment; child processes only ever see the
# variables we pass ourselves.
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP VIRTUAL_ENV
unset PIP_REQUIRE_VIRTUALENV PIP_TARGET PIP_PREFIX PIP_USER
export UV_PYTHON_INSTALL_DIR="$RUNTIME/python"
export UV_CACHE_DIR="$HOME/Library/Caches/WhisperTranscriber/uv"
export UV_PYTHON_PREFERENCE=only-managed   # never fall back to the system python
export UV_NO_CONFIG=1                      # ignore the user's uv.toml

step() { printf '\n=== %s/8 %s ===\n' "$1" "$2" | tee -a "$LOG"; STEP_T0=$SECONDS; }
done_step() { printf '    (%s s)\n' "$((SECONDS - STEP_T0))" | tee -a "$LOG"; }

T0=$SECONDS

step 1 "Downloading Python $PYTHON_VERSION"
"$UV" python install "$PYTHON_VERSION" 2>&1 | tee -a "$LOG"
done_step

step 2 "Creating the venv"
"$UV" venv --python "$PYTHON_VERSION" "$VENV" 2>&1 | tee -a "$LOG"
done_step

step 3 "Installing dependencies (the longest step)"
"$UV" pip install --python "$VENV/bin/python3" -r "$REQ" 2>&1 | tee -a "$LOG"
done_step

step 4 "Linking ffmpeg"
FFMPEG_SRC="$("$VENV/bin/python3" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')"
mkdir -p "$RUNTIME/bin"
ln -sf "$FFMPEG_SRC" "$RUNTIME/bin/ffmpeg"
chmod +x "$FFMPEG_SRC"
"$RUNTIME/bin/ffmpeg" -version 2>&1 | head -1 | tee -a "$LOG"
done_step

step 5 "Clearing quarantine flags"
xattr -dr com.apple.quarantine "$RUNTIME" 2>/dev/null || true
echo "    done" | tee -a "$LOG"
done_step

step 6 "Verifying"
"$VENV/bin/python3" - <<'PY' 2>&1 | tee -a "$LOG"
import sys, json, platform
import whisper, torch
print("    python :", platform.python_version())
print("    whisper:", whisper.version.__version__ if hasattr(whisper, "version") else "?")
print("    torch  :", torch.__version__)
print("    mps    :", torch.backends.mps.is_available())
print("    models :", len(whisper._MODELS), "/ languages:", len(whisper.tokenizer.LANGUAGES))
PY
done_step

step 7 "Writing runtime.json"
"$VENV/bin/python3" - "$RUNTIME" "$REQ" <<'PY' 2>&1 | tee -a "$LOG"
import hashlib, json, pathlib, platform, sys, datetime
runtime, req = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
import whisper, torch, imageio_ffmpeg
info = {
    "schema": 1,
    "python": platform.python_version(),
    "whisper": getattr(whisper.version, "__version__", None),
    "torch": torch.__version__,
    "imageio_ffmpeg": imageio_ffmpeg.__version__,
    "requirements_sha256": hashlib.sha256(req.read_bytes()).hexdigest(),
    "installed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
(runtime / "runtime.json").write_text(json.dumps(info, indent=2) + "\n")
print("   ", json.dumps(info, indent=2).replace("\n", "\n    "))
PY
done_step

step 8 "Cleaning the temporary download cache"
# Verified: deleting the cache doesn't affect the venv (no hardlinks, ~810 MB comes back).
"$UV" cache clean 2>&1 | tail -1 | tee -a "$LOG"
done_step

printf '\n--- summary ---\n' | tee -a "$LOG"
printf 'total time : %s s\n' "$((SECONDS - T0))" | tee -a "$LOG"
printf 'runtime    : %s\n' "$(du -sh "$RUNTIME" | cut -f1)" | tee -a "$LOG"
printf 'uv cache   : %s\n' "$(du -sh "$UV_CACHE_DIR" 2>/dev/null | cut -f1)" | tee -a "$LOG"
printf 'ready: %s\n' "$VENV/bin/python3" | tee -a "$LOG"
