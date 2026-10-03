# The managed Python environment

The app sets up and manages its own isolated Python environment for transcription.
The user's system Python, their Homebrew installation and the `whisper` command on
their PATH are never used, under any circumstances.

## Why

- The user's system Python is 3.14.6 (Homebrew). That version may work today, but a
  single `brew upgrade python` changes it overnight and breaks the app. An isolated
  environment cuts that off.
- Version compatibility between openai-whisper, torch, numba and llvmlite is fragile.
  A pinned `requirements.txt` ships exactly one verified combination.
- The user's other projects are unaffected, and uninstalling is nothing more than
  deleting a single directory.

## Layout

```
~/Library/Application Support/WhisperTranscriber/
├── runtime/
│   ├── python/                 # CPython 3.13 downloaded by uv (python-build-standalone)
│   ├── venv/                   # openai-whisper + torch + imageio-ffmpeg
│   ├── bin/ffmpeg              # symlink to the binary inside imageio-ffmpeg
│   └── runtime.json            # { schema, python, whisper, torch, requirements_sha256, installed_at }
├── logs/
│   ├── provision-YYYYMMDD-HHMMSS.log
│   └── worker-YYYY-MM-DD.log
└── presets.json                # the user's saved setting bundles

~/Library/Caches/WhisperTranscriber/uv/   # temporary download cache, deleted at the
                                          # end of setup (~810 MB comes back)
```

Models are **not copied here**. The default model directory is the user's existing
`~/.cache/whisper` (which already holds `small.pt`, `large-v3.pt` and
`large-v3-turbo.pt` — 4.8 GB), so no model download is needed on first use. It can be
changed in Settings; the app writes to that directory **only through whisper's own
downloader** and never deletes files there itself.

## The embedded `uv`

`uv` (Astral) is a single static binary — it runs without Python, which is what
solves the "you need Python to install Python" chicken-and-egg problem.

- Source: the `astral-sh/uv` GitHub release, `uv-aarch64-apple-darwin.tar.gz` (~16 MB)
- `make bootstrap` downloads it, verifies it against the published `.sha256`, and puts
  it in `app/WhisperTranscriber/Resources/bin/uv` (not committed; it's in `.gitignore`)
- The version is pinned in `scripts/versions.env`; upgrading is a deliberate commit
- When the app is signed, this binary is signed too, with **Developer ID + hardened
  runtime** (nested binaries are signed outside-in — see `BUILD_AND_RELEASE.md`)

## Setup steps (first launch)

`RuntimeProvisioner` runs the following in order and reports progress to the UI at
every step.

Reference implementation: `scripts/provision_runtime.sh`. The Swift-side
`RuntimeProvisioner` keeps the step order, the environment variables and the
verifications exactly identical.

| # | Step | Command | Measured time |
|---|---|---|---|
| 1 | Download Python | `uv python install 3.13` | 2 s |
| 2 | Create the venv | `uv venv --python 3.13 <runtime>/venv` | < 1 s |
| 3 | Install dependencies | `uv pip install --python <venv> -r requirements.txt` | 46 s |
| 4 | Link ffmpeg | `imageio_ffmpeg.get_ffmpeg_exe()` → `bin/ffmpeg` symlink | 1 s |
| 5 | Clear quarantine | `xattr -dr com.apple.quarantine <runtime>` | 1 s |
| 6 | Verify | import `whisper`/`torch` + report versions | 9 s |
| 7 | Record | write `runtime.json` | < 1 s |
| 8 | Clean the cache | `uv cache clean` | 2 s |

**Measured result (2026-10-01, 1 Gbit connection):**

| | |
|---|---|
| Total time | **61 seconds** |
| Downloaded | ~850 MB (24 packages + CPython) |
| Permanent disk use | **887 MB** (`runtime/`) |
| Reclaimed | 810 MB (step 8, the temporary cache) |
| Installed versions | CPython 3.13.15 · openai-whisper 20250625 · torch 2.14.1 · numba 0.68.0 · numpy 2.5.3 · ffmpeg 7.1 |

Step 8 is verified: the venv keeps working after the cache is deleted (no hardlinks
are used, the files are copied into the venv).

> On a slow connection this can take several minutes, depending on the download; the
> setup screen gives no time estimate, it shows real progress.

Rules:
- Environment variables are passed to the child process **explicitly**:
  `UV_PYTHON_INSTALL_DIR=<runtime>/python`,
  `UV_CACHE_DIR=~/Library/Caches/WhisperTranscriber/uv`,
  `UV_PYTHON_PREFERENCE=only-managed` (never fall back to the system Python),
  `UV_NO_CONFIG=1` (ignore the user's `uv.toml`).
  The user's `PYTHONPATH`, `PYTHONHOME`, `VIRTUAL_ENV` and `PIP_*` variables are
  **cleared** — dirty shell profiles break the environment.
- Step 5 is mandatory: if the quarantine xattr is inherited by files the app
  downloads, Gatekeeper kills `python3`. It is cleared once, after setup.
- Setup must **survive interruption**: a half-finished `runtime/` directory is
  detected on the next launch by the absence of `runtime.json`, then deleted and
  installed from scratch.
- Every step's full command, exit code and last 50 lines of output are written under
  `logs/`.

## Health check (subsequent launches)

`runtime.json` is read and three things are verified:
1. does `venv/bin/python3` exist and is it executable
2. does `requirements_sha256` match the hash of the embedded `requirements.txt`
   (if it doesn't → the app has been updated, so the dependencies are reinstalled)
3. does a `capabilities` call return `hello` within 15 s

If any of the three fails the state becomes `.broken(reason)`; the UI shows a
"Reinstall the environment" button, `runtime/` is deleted and setup starts again from
step 1.

## Dependencies

`python/requirements.txt` — the most recent versions **verified** on PyPI
(2026-10-01):

```
openai-whisper==20250625
torch==2.14.1
imageio-ffmpeg==0.6.0
```

Pulled in transitively: `numba` (0.68.0), `llvmlite` (0.50.0), `tiktoken` (0.14.0),
`numpy`, `more-itertools`, `tqdm`. All of them have cp313 **and** cp314 wheels for
macOS arm64 — nothing is built from source.

> During setup a fully pinned `requirements.lock` will be produced with
> `uv pip compile` and committed to the repository (Phase 1). The three lines above
> are the input to that lock file.

### Why Python 3.13

Every package above also publishes wheels for 3.14 (checked), but numba/llvmlite's
JIT has historically been the last component to mature on a new CPython release. 3.13
is one release behind, has full wheel coverage and is supported for a long time.
Because we are independent of the system Python, this choice doesn't affect the user
at all. Upgrading means changing a single line in `scripts/versions.env`.

## ffmpeg

To read audio, whisper spawns an `ffmpeg` child process and **looks for it on PATH**.
Rather than trusting PATH, the worker decodes the audio itself:

```python
# what whisper.load_audio does, repeated with an explicit ffmpeg path
cmd = [FFMPEG, "-nostdin", "-threads", "0", "-i", path,
       "-f", "s16le", "-ac", "1", "-acodec", "pcm_s16le", "-ar", "16000", "-"]
audio = np.frombuffer(run(cmd), np.int16).flatten().astype(np.float32) / 32768.0
```
`whisper.transcribe(model, audio, ...)` is then called with the numpy array.
What this buys us: no PATH dependency, a distinct and comprehensible ffmpeg failure
(`AUDIO_DECODE_FAILED` plus ffmpeg's real stderr), and the audio duration known
before transcription starts (which the progress percentage needs).

The `FFMPEG` path is resolved in order: `runtime/bin/ffmpeg` →
`imageio_ffmpeg.get_ffmpeg_exe()`. The installed version is **ffmpeg 7.1** (the static
binary that ships with imageio-ffmpeg 0.6.0). The user's Homebrew ffmpeg (8.1.2) is
not used; we don't control its version.

## Device selection (CPU / MPS)

- **The default is `cpu`.** On Apple Silicon, openai-whisper's support for MPS has
  been partial for years: missing operators, and silent quality regressions caused by
  fp16.
- Settings has an **"MPS (experimental)"** switch. The `hello` event reports
  `mps_available`; if MPS is selected and the run fails, the worker falls back to CPU
  automatically and says so with `{"type":"log","level":"warning"}`.
- `fp16` defaults to `false` on both MPS and CPU (fp16 isn't supported on CPU anyway —
  whisper prints a warning and drops to fp32, so we cut the noise out up front).
- The real answer for speed is not MPS, it's the whisper.cpp engine (Metal) in Phase 5.

## Uninstalling

Settings → "Delete the runtime environment": `runtime/` is deleted (~890 MB
reclaimed). `~/.cache/whisper` is **left alone** — that belongs to the user, not to
the app. For cleaning it, all we offer is a shortcut that opens the directory in
Finder.
