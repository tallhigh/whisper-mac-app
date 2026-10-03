# Implementation plan

Status markers: ⬜ not started · 🟨 in progress · ✅ done
At the end of every phase `make test && make lint` must be green and the phase's
acceptance tests must be verified by hand.
Track the active phase from here; when a phase is done, tick the boxes and commit.

---

## Phase 0 — Skeleton and verification ✅

Goal: an empty but signed and running app, plus proof that the Python environment can
genuinely be installed.

- [x] The Xcode project is generated from `app/project.yml` with XcodeGen (ADR-011), macOS 14.0, arm64, Swift 6 strict concurrency
- [x] `app/Version.xcconfig` (MARKETING_VERSION 0.1.0, CURRENT_PROJECT_VERSION 1)
- [x] Bundle id: `com.talhaturhan.WhisperTranscriber` · Team `AL9CGWVTYB`
- [x] Hardened Runtime on (verified via `flags=0x10000(runtime)`), empty `.entitlements`, sandbox off
- [x] `Makefile`: `bootstrap provision generate build run test lint format fixtures doctor clean`
- [x] `scripts/versions.env` — `UV_VERSION=0.12.21`, `PYTHON_VERSION=3.13`
- [x] `scripts/fetch_uv.sh` — downloads, verifies the `.sha256`, clears quarantine
- [x] `scripts/provision_runtime.sh` — the 8-step environment setup (the reference for the Swift side)
- [x] `scripts/make_test_audio.sh` — reproducible Turkish test files (TTS + ffmpeg)
- [x] Copy Files phases: `uv` → `Contents/MacOS/uv`, the worker → `Contents/Resources/python/`
- [x] Lint infrastructure: `.swift-format` (4 spaces, 110 columns) + `python/ruff.toml`
- [x] **Manual verification (critical):** the environment was installed end to end and a real transcription was run

**Measured results.**

| | |
|---|---|
| Environment setup | **61 s**, ~850 MB download, 887 MB of permanent disk |
| Temporary cache | 810 MB — reclaimed with `uv cache clean`, the venv unaffected |
| Installed versions | CPython 3.13.15 · whisper 20250625 · torch 2.14.1 · numba 0.68.0 · ffmpeg 7.1 |
| MPS | `torch.backends.mps.is_available() == True` |
| Discovered | 14 models, 100 languages |
| Transcription | 24.35 s of audio → **8.76 s** (`small`, CPU) = **2.8×** real time |
| Skeleton `.app` | 36 MB (35 MB of it the embedded `uv`) |

**Acceptance test — passed.** `make build` succeeds, the signature is valid
(`codesign --verify --deep --strict`), the app launches and confirms on screen that it can
resolve all three embedded resources (`uv`, `whisper_worker.py`, `requirements.txt`) from
inside the bundle.

**What Phase 0 taught us.**
1. In XcodeGen, `copyFiles` must be written **nested under `buildPhase:`** in the sources
   entry. Written as a sibling it is ignored silently; the build looks successful but the
   bundle stays empty. That's why the check inside `ContentView` is permanent.
2. Xcode doesn't re-sign the copied `uv` (Astral's team identifier `2DC432GLL2` remains).
   `uv` has to be re-signed explicitly as part of the release signature.
3. `uv cache clean` doesn't break the venv — 810 MB is reclaimed at the end of setup.
4. ruff's RUF001-003 rules produce nothing but noise on Turkish text, so they're off.

---

## Phase 1 — The Python worker ✅

Goal: `whisper_worker.py` works completely on its own, from a terminal.

- [x] `python/requirements.txt` plus a `requirements.lock` via `uv pip compile` (24 packages, committed)
- [x] `inspect.signature(whisper.transcribe)` and the CLI `argparse` definitions were read and
      `docs/WHISPER_OPTIONS.md` was **corrected** against the installed version
- [x] `emit()` plus the stdout protection shim (dup of fd 1, `_LogShim`)
- [x] `capabilities` mode: 14 models, 100 languages, 5 formats, the cached models
- [x] `transcribe` mode: validate → decode the audio (explicit ffmpeg path) → load the model →
      `whisper.transcribe()` → write to a temporary directory with `get_writer()` → atomic `os.replace`
- [x] `progress` events via a `tqdm` monkeypatch (two separate targets: the module and the class)
- [x] `segment` events (by wrapping `make_safe`, live)
- [x] `SIGTERM` → `WorkerCancelled` → `error/CANCELLED`, leaving no half-written file
- [x] Every error code mapped to a real exception (10 codes)
- [x] `pytest`: 42 fast tests + 5 slow ones

**Acceptance test — passed.** The worker's output is **byte-for-byte identical** to what the
`whisper` CLI produces (`test_output_is_identical_to_the_cli`, verified on every
`make test-python-slow` run).

```bash
make fixtures          # python/tests/fixtures/speech.m4a (24.35 s of Turkish speech)
make test-python       # 42 fast tests, loads no model, uses no network
make test-python-slow  # 5 real transcription tests (~42 s)
```

**What Phase 1 taught us.**

1. **The CLI and the library don't produce the same output.** The whisper CLI does beam
   search with its argparse defaults of `beam_size=5` and `best_of=5`; calling
   `whisper.transcribe()` directly gives greedy decoding. The text differs for the same
   audio ("Üç ayrı başlık" → "3 ayrı başlık"). The worker takes the CLI's side through
   `_CLI_PARITY_DEFAULTS`. My first suspicion, an ffmpeg version difference, was **wrong** —
   running the CLI with the same ffmpeg kept the difference, and the real cause was the
   decoding strategy.
2. **The `whisper.transcribe` module is shadowed by the function of the same name.** The
   module has to be reached via `sys.modules["whisper.transcribe"]`. There are also two
   separate tqdm targets: the tqdm *module* inside that module (transcription) and the
   `whisper.tqdm` *class* (model downloads).
3. **Progress granularity is a 30-second window.** 8 events for a 3-minute recording; a
   single event (100%) for a 24-second one. The UI can't invent intermediate values.
4. **Cancellation latency measured: 7 seconds** (`small`, noticed at a window boundary).
   The SIGKILL deadline was raised from 5 to 10 seconds; the UI shows the cancellation at
   once and reaps the process in the background.
5. The progress bar is constructed with `disable=verbose is not False`; because we use
   `verbose=True` the bar is disabled and `self.n` can't be trusted — the counter is kept
   by hand in the subclass.

## Phase 2 — The environment provisioner (Swift) ✅

Goal: the app installs its own Python environment and verifies its health.

- [x] `ProcessRunner` — the single path for running a child process; stdout/stderr are read
      concurrently (reading one pipe deadlocks when it fills), stdin is written and closed
- [x] The `RuntimeProvisioner` actor — 8 steps, with progress weighted by the measured times
- [x] Clean environment variables (`PYTHONPATH`/`PYTHONHOME`/`VIRTUAL_ENV`/`PIP_*` are not
      carried over, `UV_*` are passed explicitly, `UV_PYTHON_PREFERENCE=only-managed`)
- [x] Clearing quarantine and writing `runtime.json`
- [x] Health check: the manifest + `requirements_sha256` + the worker's `capabilities` response
- [x] Resilience to interruption: with no `runtime.json`, the directory is deleted and set up again
- [x] `AppState` (@MainActor @Observable) + `RootView` routing
- [x] The setup screen: consent, real progress, a live log, cancellation, errors + retry + copy log
- [x] Per-step logging to `logs/provision-*.log`
- [x] A Swift test target (Swift Testing) — 23 tests

**Acceptance test — passed.** `runtime/` was deleted completely, the **signed app** was
launched, setup ran from start to finish from the setup screen, and on the next launch it
went straight to the ready screen.

**The critical risk Phase 2 closed.** An app signed with hardened runtime can launch the
embedded `uv`, and the CPython it installs, as child processes **without trouble**. In the
environment the app installed itself, `whisper` and `torch` import, the worker answers
`capabilities`, and no quarantine flag remains (the `xattr` count after step 5 is 0). No
extra entitlement was needed — ADR-007 verified.

**Note.** The `runtime.json` the app writes is identical to the one the shell script
produces (the same `requirements_sha256`). The two implementations are interchangeable.

## Phase 3 — Engine, queue and main interface ✅

Goal: the app's actual job — drop a file, configure, transcribe.

- [x] The `TranscriptionEngine` protocol + `EngineCapabilities` + `EngineEvent`
- [x] The NDJSON decoder — an unrecognised line or event becomes `.unknown`, not an error
- [x] The `PythonWhisperEngine` actor — process lifecycle, writing stdin,
      cancellation (SIGTERM → 10 s → SIGKILL)
- [x] `WhisperSettings` plus the pure `jobPayload(for:jobID:)` transformation
- [x] `JobQueue` — sequential processing, the state machine, reordering, retrying
- [x] The main window: three panes, the toolbar, the TEXT/LOG tabs
- [x] Drag and drop (folder support, reporting unsupported files)
- [x] Model/language/format controls populated from capabilities + the un-downloaded model warning
- [x] Settings persistence (`UserDefaults`) + overwrite confirmation
- [x] "Open With" from Finder and dragging onto the Dock (`CFBundleDocumentTypes`)
- [x] Preventing sleep, notifying on completion, confirming on quit
- [x] Swift Testing: 80 unit tests + 6 integration tests
- [ ] Keep the process alive and skip loading the model when the same model is used consecutively
      (deferred to Phase 4 — rationale below)

**Acceptance test — passed.** The integration tests run the real worker
(`make test-swift-slow`, ~40 s):

| Test | Time | What it verifies |
|---|---|---|
| Capabilities are read from the real worker | 1.3 s | 100 languages, 14 models, the lists aren't hard-coded |
| A real file is transcribed and the event stream follows the contract | 9.4 s | hello first, result last, segment + progress present |
| A corrupt file gives a classified error | 0.6 s | `AUDIO_DECODE_FAILED`, the destination directory stays empty |
| A Turkish file name with an emoji survives | 9.2 s | `SAMPLE recording 🎙 şçğü.txt` is written |
| An existing output is not overwritten | 0.03 s | `OUTPUT_EXISTS`, the existing file is unchanged |
| A cancelled job leaves no half-written file | 19.6 s | `Task.cancel()` → SIGTERM → the directory is empty |

The test split is done with `-skip-testing` / `-only-testing` rather than an environment
variable: `xcodebuild test` doesn't pass the shell's environment into the test process,
and that had produced a silent false positive that reported "0 tests ran".

### Event rate: no throttling needed

The plan called for throttling `progress` events to 10 Hz. That was dropped after
measurement: whisper produces `progress` once per 30-second window and `segment` once per
segment. A throttling machine would be complexity with nothing to show for it. Because
`log` events can arrive more often, a 500-line ring buffer per job is used.

### The concurrency decision changed

The plan had `JobQueue` as an `actor`. In the implementation it became
`@MainActor @Observable`: the queue holds the `TranscriptionItem` objects the views read
directly, and all it does is coordination — the heavy work is already in the
`PythonWhisperEngine` actor and in a separate OS process. Making it an actor would have
meant copying every read onto the main actor. `CLAUDE.md` and `ARCHITECTURE.md` were
corrected accordingly.

### A real bug found: the blocking `waitUntilExit`

`ProcessRunner` was awaiting process exit with `Process.waitUntilExit()`. That call blocks
the calling thread, which under Swift concurrency means holding a thread from the
cooperative pool. In Phase 3, once the test count grew and Swift Testing ran the tests in
parallel, the pool was exhausted, the reader tasks couldn't be scheduled, and **the whole
test round deadlocked** (hung for 10+ minutes).

What matters: this was not a test problem. The same code runs several processes
back-to-back during environment setup; the same deadlock could have happened in the app.

The fix: `ProcessRunner.waitForExit(_:)` — a non-blocking wait built on
`terminationHandler`. `PythonWhisperEngine` dropped its own copy and uses this too (that
copy also had a double-resume race, closed with `OnceResumer`). Written into `CLAUDE.md`
and `ARCHITECTURE.md` as a rule.

### The health check was hardened

During Phase 3, the health probe failed once when the app was opened with file arguments,
and **could not be reproduced**. The root cause wasn't found. The symptom was defanged as
follows:

- The probe is retried once automatically; a single transient failure doesn't mark the
  environment "broken".
- A 60-second timeout was put on the probe; a hung child process can't make the app wait
  forever at launch.
- The error message now carries the real cause and is written to `logs/health.log`
  (previously it said "The runtime is not responding" and swallowed the cause).
- **The actual design flaw was fixed:** the "Retry" button on the error screen used to
  delete the environment and re-download 890 MB. Now "Retry" only repeats the health
  check; the destructive reinstall is a separate button.

If it happens again, `health.log` will give the root cause.

**Deferred work.** The optimisation of keeping the process alive for consecutive uses of
the same model (ADR-008) wasn't done. The worker is currently one process per job, which
keeps crash isolation and cancellation simple. In the integration test a 24 s file took
9.4 s end to end, about 2 s of which is model loading — a small gain for `small`. Since it
would be meaningful for batches with `large-v3`, it will be evaluated in Phase 4 by adding
a persistent mode to the protocol.

## Phase 4 — Advanced options, presets, polish ✅

- [x] The "Advanced" section — every control from the `WHISPER_OPTIONS.md` table
      (thresholds, the fallback step, the hallucination threshold, fp16, "reset to defaults")
      · ⚠ **removed entirely on 2026-10-02** — see the simplification round below (ADR-015)
- [x] The UI validation rules (the 7 rules in that same file)
- [x] The preset system + 3 built-in presets (Quick note / High quality / Subtitles);
      visible both in the toolbar menu **and** as buttons in the settings pane
- [x] User presets: "Save Current Settings…" → `presets.json`, deletable from
      Settings → General
- [x] The Settings window (⌘,): General, Models, Runtime, About
- [x] Notify on completion, reveal in Finder, copy the text
- [x] The MPS (experimental) switch + falling back to CPU on failure (ADR-012)
- [x] Preventing sleep (`beginActivity`), confirming on quit — both can be turned off by preference
- [x] `Localizable.xcstrings` — 219 keys, generated with `make strings`
- [x] An accessibility pass (Picker labels, combining VoiceOver rows, progress values,
      hiding decorative elements)
- [x] The app icon (added 2026-10-02) — `scripts/make_icon.swift` generates 10 sizes from
      a vector; a superellipse body, a violet→indigo gradient, a sound wave turning into
      lines of text. Legibility at 16/32 px verified by eye.

**Measured result.**

| Item | Result |
|---|---|
| Swift unit tests | 108 tests, 21 suites, 0.16 s |
| Swift integration tests | 6 tests, 34.8 s (the real worker) |
| Python fast tests | 45 tests, 0.09 s |
| Python slow tests | 5 tests, 42.7 s (including CLI equivalence) |
| Catalog keys | 219 |
| Build | warning-free |

**What we learned.**
- `Picker("", selection:)` + `labelsHidden()` is a common pattern but gives VoiceOver **no**
  name at all. The right way is to write the real label and hide it visually with
  `labelsHidden()`: the accessibility name survives.
- The `.xcstrings` catalog **does not fill itself** on a command-line build; the Xcode UI
  fills it. `SWIFT_EMIT_LOC_STRINGS` produces a `.stringsdata` per Swift file, and merging
  that into the catalog is done by hand with `xcrun xcstringstool sync` → `make strings`.
- Swift's synthesised `Decodable` decoder **throws on a missing key**; swallowed with
  `try?`, every new settings field reset all of the user's settings. Worse: because the
  synthesised encoder omits `nil` optionals, the distinction between "no key" and "the user
  left it empty" was lost, and `beam_size` silently became `nil`, breaking CLI equivalence.
  **A test caught this**, not a human (ADR-013).
- Warnings like a missing `@discardableResult` or `try? handle.seekToEnd()` only appear when
  the file in question is recompiled; incremental builds can create a false impression of
  being "warning-free".

**Acceptance test.** All three presets produce the expected output. Invalid combinations
can't be selected in the UI. Every user-facing string lives in `Localizable.xcstrings`.

---

## Phase 5 — The first release (v0.1.0) 🟨

**Released:** <https://github.com/tallhigh/whisper-mac-app/releases>
v0.1.0 was the first; the current release is v0.3.0, which includes live recording.
The only item left is the README screenshot.

- [x] `scripts/` → `common.sh`, `archive.sh`, `sign.sh`, `notarize.sh`,
      `make_dmg.sh`, `release_notes.sh`, `release.sh`, `ExportOptions.plist`,
      `local.env.example`
- [x] `make archive` → `codesign --verify --deep --strict` clean, with the Hardened Runtime
      flag and matching team identifiers verified inside the script
- [x] `make notarize` → `status: Accepted`, `stapler validate` succeeds
- [x] **Clean-machine test:** with the quarantine xattr written, both the dmg **and** the app
      inside it are `accepted` by `spctl` — the test is embedded in `make dmg` and can't be
      skipped
- [x] The `.dmg` is under 50 MB — measured at **18 MB** (the script stops if the threshold is passed)
- [x] `README.md` installation instructions + keyboard shortcuts
- [ ] `README.md` screenshot — the developer will take it from the running app
- [x] `gh release create v0.1.0` — `tallhigh/whisper-mac-app` (**private**),
      asset `WhisperTranscriber-0.1.0.dmg` (17 MB), build number 2

**Measured result.**

| Step | Result |
|---|---|
| Archive + export + sign | `.app` 36 MB, `flags=0x10000(runtime)`, team `AL9CGWVTYB` |
| `.app` notarization | Accepted, ~40 s |
| dmg notarization | Accepted, ~50 s |
| dmg size | 18 MB |
| Gatekeeper | `accepted · source=Notarized Developer ID` |
| Re-signed `uv` | `uv 0.12.21` works |
| `make release VERSION=0.1.0` | passed start to finish in one command; the tag and the release were created |

**An open point.** The repository is **private**, so the download link for the release asset
also demands a GitHub login. For the originally intended "download the `.dmg` straight from
the web" behaviour, the repository has to be made public
(`gh repo edit --visibility public`). This is a deliberate choice; the code is kept closed
for now.

**What we learned.**
- The `codesign … | grep -q` pattern produces a **false failure** under `set -o pipefail`:
  `grep` closes the pipe at the first match and `codesign` dies of SIGPIPE. The first
  `make archive` attempt stopped saying the Hardened Runtime flag was missing, while it was
  right there. The fix: capture the output into a variable and search the variable.
- Notarization is needed **twice**: the `.app` first (and stapled), then the dmg. If only
  the dmg is stamped, the app has no ticket of its own once copied into Applications and
  offline Gatekeeper verification fails.
- An `.xcstrings` containing only the source language isn't compiled into the bundle —
  there's no translation for the compiler to absorb and at runtime the key (= the source
  text) is used. Expected behaviour, not a gap.
- `notarytool --wait` can exit zero while the status is `Invalid`; `notarize.sh` looks for
  `status: Accepted` in the output and prints the log if it isn't there.

**Acceptance test.** The downloaded `.dmg` opens under a second user account (or on a clean
machine), the app completes setup and transcribes a file.

---

## Simplification round (2026-10-02) ✅

The user's request: "let's make the app simpler, remove the advanced settings, add a feature
that extracts the notes line by line."

- [x] The advanced section was removed from the interface; the 19 corresponding fields were
      deleted from `WhisperSettings`. The job definition now carries no decoding key at all
      (ADR-015)
- [x] Device selection moved from the main panel to **Settings → Runtime** — a return
      to `UI_SPEC.md`'s original design
- [x] A new output format, **`notes`** — a timestamped bullet list with an `.md` extension.
      Its writer is in the worker (ADR-014)
- [x] A fourth built-in preset: **Meeting notes** (`small` · `notes`)
- [x] The format checkboxes were moved to two rows of three (six didn't fit on one line)

**Measured result.**

| Item | Before | After |
|---|---|---|
| Controls on the main panel | 5 core + 17 advanced | 5 core |
| `WhisperSettings` fields | 28 | 9 |
| `options` keys in the job definition | 10 | 1 (`fp16`, on CPU only) |
| Swift unit tests | 108 | 99 |
| Swift integration tests | 6 | 7 |
| Python fast tests | 45 | 57 |
| Python slow tests | 5 | 6 |

**The most critical verification.** `test_output_is_identical_to_the_cli` **still passes**. That
was the expected outcome, but it had to be proven: Swift no longer sends `beam_size`, and
equivalence is provided single-handedly by the worker's `_CLI_PARITY_DEFAULTS` constant. The
test itself already ran without sending `options`, so it turns out it had been measuring the
new path all along.

**What we learned.**
- **Not** sending an option is safer than sending the right value. The bug recorded in
  ADR-013 (a missing `beam_size` key silently dropping to greedy decoding) is now
  structurally impossible: there is no key to send.
- Settings removed from the UI have to be deleted from the model too. Leaving the fields
  "in case we need them later" would have let the values in the user's older settings block
  stay invisibly in effect.
- A format name diverging from its file extension (`notes` → `.md`) needs a counterpart in
  two places at once: `format_extension()` in the worker and `OutputFormat.fileExtension` in
  Swift. The tests pin both separately.

---

## Phase 7 — Live recording and real-time transcription ✅

The design and the measurements are in a separate file:
**[LIVE_TRANSCRIPTION.md](LIVE_TRANSCRIPTION.md)**.

In summary: recording starts from inside the app, text flows on screen while you speak, and
on "Finish" the recording file enters the existing queue as an ordinary job and produces the
real output. Two passes: the live preview is greedy (with no correctness claim), while
everything written to a file comes from the CLI-equivalent second pass.

Shipped in v0.3.0. What remains is the manual walk-through of 7.4.

- [x] 7.1 — Microphone capture, the recording file (the worker is untouched)
      - The `AudioCapturing` protocol + `MicrophoneCapture` (AVAudioEngine → 16 kHz mono)
      - The `RecordingController` state machine, the `RecordingView` sheet, ⇧⌘R
      - The recording-folder preference, a non-colliding file name, the level meter
      - 12 new tests (with a fake capturer, never touching the microphone)
      - The permission experiment was run: without the entitlement the system refuses
        **without ever showing the dialog**, so `com.apple.security.device.audio-input`
        was added afterwards with the evidence (ADR-016)
- [x] 7.2 — System audio (a Core Audio process tap), source and app selection
      - `AudioProcessList`: the processes producing audio are listed from Core Audio
      - `SystemAudioCapture`: `CATapDescription` (mono + mixdown + private,
        `muteBehavior = .unmuted`) → aggregate device → `IOProc`
      - `.both`: a sub-device of **the same** aggregate device as the microphone tap, with
        drift compensation on; all input channels are reduced to mono
      - Source and app selection on the recording screen, stored as a preference
      - Deployment target 14.0 → **14.4**
      - Measured: system audio needs **no** permission and no entitlement (a capture with
        `source: both` recorded 51.9 s successfully)
- [x] 7.3 — The worker's `stream` mode, protocol v2, the segment-commit algorithm
      - `StreamReader` reads stdin on a separate thread: transcription blocks the main
        thread for seconds at a time while audio keeps arriving
      - The digital-silence gate (RMS < 1e-4) never calls whisper at all
      - Context: the last 200 characters of committed text go to the next call as
        `initial_prompt`
      - The protocol version is now a property of **the channel**; in live mode every
        event, `log` and `status` included, carries v2 (a real test caught this)

**Measured result (24.4 s of Turkish audio, `small`/CPU, fed in at real-time speed).**

| Item | Value |
|---|---|
| Text appearing on screen | ~1.5–2.5 s |
| Commit (grey → black) | 3.0 s on average, 6.1 s worst case |
| Full text | the same in meaning as the batch output (322 characters) |
| Timeline | unbroken: 0.0→2.3→6.1→8.6→13.4→19.0→24.4 |

**Two fixes came out of the measurement.**
1. The tick was lowered from 3 s to 1.5 s (the worst commit was 8.1 s).
2. `partial` now carries **everything uncommitted**. It used to send only the last segment,
   so the segments in the middle never appeared on screen — the user saw the committed
   text, then a gap, then the last sentence.

**The acceptance criterion was corrected.** The plan said "latency under 5 s"; the right
criterion is when the text **appears** (~2 s), not when it commits. Commit latency is
cosmetic: the text is already on screen as provisional. The latency comes from whisper
changing its segment boundaries after the fact; the permanent fix is LocalAgreement-2 and
it is still deferred.

- [x] 7.4 — The live interface, model selection, the two-pass write flow
      · **awaiting manual verification**
      - `LiveTranscriptionEngine` as a separate protocol; `PythonWhisperEngine` conforms
      - `LiveSession` keeps stdin open, with the audio written from a separate queue
      - A single stream of committed (primary) + provisional (faded) text on the recording screen
      - The live model is chosen separately; the accurate pass uses the model from Settings
      - "Finish" → the live text is written **instantly** as `txt`/`notes`; to
        `… (live).txt` if the accurate pass will run too, otherwise under the plain name
      - Live transcription can be turned off from both the recording screen and Settings;
        turning it off makes the accurate pass mandatory (with both off, the recording would
        never become text at all)
      - A recording can be named; `/` and `:` become hyphens, leading dots are dropped, the
        name is truncated at 120 characters, and a number is appended on a collision

**Three departures from the plan, all of them justified.**

1. **No energy gate on the Swift side.** The plan called for not sending silent chunks to
   the worker; but dropping a chunk removes **time** from the stream and the committed
   timestamps then don't match the recording's real clock — and the `notes` format writes
   exactly those timestamps. Silence protection stayed as the buffer-level gate in the
   worker; the measurement had already shown the pathological case to be "the buffer is
   entirely zeros".
2. **The live text is written to its own file.** The plan had both going to the same file
   with the second pass overwriting it, which loses the live text. A separate file preserves
   it and also removes the need for an exception to the overwrite check.
3. **The live text only writes `txt` and `notes`.** We have the segment text and a
   timestamp; we don't have the fields `srt`/`vtt`/`json`/`tsv` need and we don't imitate
   whisper's formats (CLAUDE.md, architecture rule 5). Any other selected formats are
   produced by the second pass.

**Live transcription fails optionally.** If the session can't be established, the recording
carries on anyway and the user is told in a log line: the real job is to record the audio.

**Decisions (confirmed with the user).** Both microphone and system audio, with the user
choosing (and the app selectable, for Zoom/Meet). The live preview's model is separately
selectable. The recording folder belongs to the user. The live text is held in memory and
written to a file on "Finish".

**A Core Audio process tap rather than ScreenCaptureKit** was chosen for system audio
(`AudioHardwareCreateProcessTap`, macOS 14.2+; verified in the SDK). The deciding factor was
the permission: screen-recording permission is disproportionate for an audio app.
`CATapDescription` gives mono mixdown and per-process selection out of the box. The
deployment target rose from 14.0 to 14.4.

**Feasibility measured (2026-10-02).** `small`/CPU with the model in memory: decoding a 30 s
buffer greedily takes **1.89 s**, with beam search 6.79 s. A tick interval of a few seconds
fits comfortably — the live preview cannot use beam search.

**Three measured risks.** Digital silence produces severe hallucination with the `small`
model (text arrives even with `no_speech_prob` at 0.841); real room noise is not a problem;
a window cut mid-sentence corrupts the first word. All three shaped the design.

**This phase required the exception to ADR-007:** with Hardened Runtime on, microphone
access is refused without the `com.apple.security.device.audio-input` entitlement. The
acceptance test included observing the refusal before the entitlement was added — it is
never added just in case.

---

## Phase 6 — Next steps (post-v1, in any order) ⬜

- [ ] **The whisper.cpp engine** (ADR-003) — Metal acceleration, GGML model management, an engine picker
- [x] Recording from the microphone + direct transcription — delivered by Phase 7
- [ ] Folder watching (transcribe automatically when a new file lands)
- [ ] Finder Quick Action / Services menu integration
- [ ] An update notification (the lightweight alternative from ADR-010)
- [ ] A fancy `.dmg` (background image, Applications shortcut)
- [ ] Batch summarisation / post-editing tools

---

## The acceptance-test list (repeated for every release)

| # | Scenario | Expected |
|---|---|---|
| 1 | `~/Desktop/whisper/mehmet.m4a`, small, Turkish, txt | The output is identical under `diff` to what the existing CLI command produces |
| 2 | A 5-file queue, cancelled in the middle | The cancelled job is `cancelled`, the rest keep processing |
| 3 | A corrupt / zero-byte audio file | `AUDIO_DECODE_FAILED`, a comprehensible message, the queue doesn't stop |
| 4 | A file name with Turkish characters, spaces and an emoji | Works, and the output name is preserved |
| 5 | The output file already exists, `overwrite` off | Confirmation is asked for before the job starts |
| 6 | `runtime/` deleted | The setup screen appears and setup completes |
| 7 | An un-downloaded model selected with no network | `MODEL_DOWNLOAD_FAILED` + a network hint |
| 8 | `large-v3` + 10 minutes of audio | No memory error, progress flows correctly |
| 9 | Closing the window during a long job | The job continues and a notification arrives when it finishes |
| 10 | A `.dmg` marked with quarantine | Opens with no Gatekeeper warning |
| 11 | ⇧⌘R → record → speak → "Finish" | The text flows live, and the files appear in the recording folder |

---

## Open questions / risks

| Item | Status | How it closes |
|---|---|---|
| ~~Does the `tqdm` monkeypatch work~~ | **closed** | It does. It needed two separate targets (module + class) and the counter is kept by hand. |
| ~~Does the parameter list match the table~~ | **closed** | It didn't. The `beam_size`/`best_of`/`temperature` defaults and `carry_initial_prompt` were corrected. |
| The `method` value in `ExportOptions.plist` on Xcode 26 | **closed** | `developer-id` is accepted; the full release pipeline ran with it. |
| ~~The CPython uv downloads — will Gatekeeper kill the child process~~ | **closed** | Phase 2: the signed, hardened-runtime app completed setup end to end and ran the worker. No extra entitlement was needed. |
| Quality/stability on MPS | a known issue | CPU by default in v1; MPS is labelled "experimental" and falls back to CPU automatically on failure (ADR-003) |
| ~~The first-install download size~~ | **closed** | Measured: 61 s, ~850 MB download, 887 MB of disk. The docs were updated. |
| Memory pressure with `large-v3` | not measured | Phase 3 acceptance test #8; if needed, a RAM warning is added to the model picker |
| The live quality of `tiny`/`base` for Turkish | not measured | Measured if the user selects one (LIVE_TRANSCRIPTION.md) |
