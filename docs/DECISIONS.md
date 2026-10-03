# Decisions (ADRs)

Every decision: context → decision → rationale → rejected alternatives → consequences.
A new entry is added here whenever an architecture, packaging or library decision is
made. A decision that stops being valid is not deleted; it is marked
"Status: superseded (ADR-0xx)".

---

## ADR-001 — The Python environment is not embedded in the `.app`; the app installs it
**Date:** 2026-10-01 · **Status:** accepted

**Context.** The app needs openai-whisper and torch. Those are either embedded in the
`.app` or installed at runtime.

**Decision.** Only the ~16 MB static `uv` binary is embedded in the `.app`. On first
launch, `uv` installs an isolated CPython 3.13 and the dependencies under
`~/Library/Application Support/WhisperTranscriber/runtime/`.

**Rationale.**
- The torch macOS arm64 wheel is ~1 GB and contains hundreds of `.dylib` files. In the
  embedded scenario each one has to be signed individually and every release means a
  ~3 GB notarization upload — slow and fragile.
- The `.dmg` stays at 25–40 MB; app updates download in seconds.
  (Measured in Phase 0: the empty skeleton `.app` is **36 MB**, 35 MB of which is the
  embedded `uv`.)
- Dependencies can be updated without re-releasing the app (when the
  `requirements.txt` hash changes).

**Rejected.**
- *A fully embedded runtime:* not needing the internet is an advantage, but the
  signing/notarization cost above is paid on every single release.
- *Using the user's existing `whisper` installation:* there is no `whisper` on the
  user's PATH right now; the system Python is 3.14.6 and a `brew upgrade` can change it
  overnight. Depending on an environment the app doesn't control is unacceptable.
- *A single Python app via PyInstaller:* loses the native look, plus PyInstaller's
  notarization problems.

**Consequences.** The internet and a ~850 MB download are mandatory on first launch.
This is spelled out on the setup screen and never started without the user's consent.

**Phase 0 verification (2026-10-01).** Setup was run end to end: **61 seconds**, 887 MB
of permanent disk, no extra cost once the temporary cache is cleared. The decision is
backed by measurement.

---

## ADR-002 — A native SwiftUI interface, with Python only as a background worker
**Date:** 2026-10-01 · **Status:** accepted

**Decision.** The interface is Swift 6 / SwiftUI. Python code exists only as
`whisper_worker.py`, running in a separate child process.

**Rationale.** Drag and drop, Finder integration, notifications, dark mode, the Settings
window and the signing/notarization flow all come for free on the native side. The
separate process additionally gives us crash isolation and reliable cancellation.

**Rejected.** PyQt6/Tkinter (non-native look, packaging problems), Electron/Tauri (a web
layer is needless weight for this job).

**Consequences.** A two-language repository. The contract between the processes must be
defined explicitly → `docs/PROTOCOL.md`.

---

## ADR-003 — A swappable engine layer; openai-whisper in v1, whisper.cpp in v2
**Date:** 2026-10-01 · **Status:** accepted

**Context.** On Apple Silicon, openai-whisper runs on the CPU in practice; MPS support
has been partial for years (missing operators, quality regressions caused by fp16).
whisper.cpp with Metal is markedly faster.

**Decision.** The UI talks to the `TranscriptionEngine` protocol. In v1 there is a
single implementation, `PythonWhisperEngine` (producing results identical to the user's
existing CLI behaviour). `WhisperCppEngine` gets added to the same protocol in Phase 5.

**Rationale.** v1's output must match what the user gets today — that is the
correctness reference. Speed optimisation comes later, without changing the interface.

**Rejected.**
- *Starting with whisper.cpp directly:* gaining speed before the output difference can
  be verified puts the result the user trusts at risk.
- *faster-whisper:* good speed-up on the CPU, but it brings a separate model
  format/download and its ceiling isn't as high as whisper.cpp + Metal. Can be
  re-evaluated in Phase 5.

**Consequences.** Extra work for the abstraction layer. `EngineCapabilities` is read at
runtime and the UI greys out unsupported controls.

---

## ADR-004 — The worker doesn't invoke the whisper CLI; it uses the library directly
**Date:** 2026-10-01 · **Status:** accepted

**Decision.** Rather than running the `venv/bin/whisper` command, `whisper_worker.py`
imports the `whisper` module and calls `transcribe()`. Output files are produced by
whisper's own `whisper.utils.get_writer()` writers.

**Rationale.**
- Real progress percentages: the `tqdm` object can be hooked; parsing the CLI's stdout
  is fragile.
- Live text can be shown as the segments arrive.
- Errors can be typed as Python exceptions (`AUDIO_DECODE_FAILED` and so on); with the
  CLI they are all just "exit 1".
- The audio is decoded on our side with an ffmpeg at a known path → no PATH dependency,
  and the audio duration is known up front.
- Because the writers are whisper's own, the output file is identical to the CLI's.

**Rejected.** Invoking the CLI as a child process (simple, but weak on progress,
cancellation and distinguishing errors).

**Consequences.** The worker depends on whisper's internal API
(`whisper.transcribe.tqdm`, `whisper.utils.get_writer`). Both points are covered by
pytest and are verified deliberately whenever the `openai-whisper` version is bumped.

---

## ADR-005 — The default model directory is the user's `~/.cache/whisper`
**Date:** 2026-10-01 · **Status:** accepted, amended by ADR-017

**Decision.** `model_dir` defaults to `~/.cache/whisper`. The app reads from that
directory and writes to it only through whisper's downloader.

> The original decision also said the app **never deletes** from the directory.
> **ADR-017 replaced that**: the Models tab can delete one model file on a confirmed
> request. The directory itself is still never removed.

**Rationale.** The user's directory already holds `small.pt`, `large-v3.pt` and
`large-v3-turbo.pt` (4.8 GB in total). Choosing an app-specific directory would have
meant downloading those 4.8 GB again.

**Consequences.** The directory lives outside the app, under the user's control. The
Models tab reveals it in Finder and, since ADR-017, can delete a single model from it.

---

## ADR-006 — Pinned to Python 3.13
**Date:** 2026-10-01 · **Status:** accepted

**Decision.** The managed environment uses CPython 3.13 (`scripts/versions.env`).

**Rationale.** macOS arm64 cp313 **and** cp314 wheels exist for `torch` 2.14.1, `numba`
0.68.0, `llvmlite` 0.50.0 and `tiktoken` 0.14.0 (verified on PyPI), so 3.14 is
technically possible too. Even so, numba/llvmlite's JIT has historically been the last
component to mature on the newest CPython; staying one release behind is risk-free.
Because we are independent of the system Python, the user is unaffected by the choice.

**Consequences.** Upgrading is a one-line change plus a full acceptance-test round.

---

## ADR-007 — Hardened Runtime on, a minimal entitlement list, no sandbox
**Date:** 2026-10-01 · **Status:** accepted; amended by ADR-016

**Decision.** Hardened Runtime is enabled (a notarization requirement), the
`.entitlements` file is empty, and App Sandbox is off.

**Rationale.** The code that uses a JIT (numba, torch) runs in a separate Python child
process, not in ours; because that child has its own signing context our entitlements
are not inherited by it — so neither `allow-jit` nor `disable-library-validation` is
needed. The sandbox is unnecessary with no App Store target, and it makes writing to
folders the user chooses harder.

**Consequences.** Entitlements are never added "just in case". If a real failure
requires one, it is added through a new ADR, with evidence of the failure. This is
exactly what happened in ADR-016 for the microphone, which is the one entitlement in
the file today.

---

## ADR-008 — The queue works sequentially, not in parallel
**Date:** 2026-10-01 · **Status:** accepted

**Decision.** Several files can be queued, but they are processed one at a time, in
order.

**Rationale.** A single whisper model already saturates the CPU cores and (with the
large models) several GB of RAM. Running them in parallel doesn't shorten the total
time; it brings memory pressure and the risk of swapping.

**Consequences.** The model can be loaded once and kept in memory across the queue (a
Phase 3 optimisation): for consecutive files using the same model, the load time is
paid once.

---

## ADR-009 — Commit straight to `main`, release with tags
**Date:** 2026-10-01 · **Status:** accepted

**Decision.** A single-developer project; no PR flow, commits go straight to `main`.
Releases are tagged `vX.Y.Z`, created by `make release`.

**Consequences.** No CI; the quality gates are local (`make test`, `make lint`) plus the
acceptance-test list in `docs/PLAN.md`. No tag is created from a tree that isn't green.

---

## ADR-010 — No Sparkle (auto-update) in v1
**Date:** 2026-10-01 · **Status:** superseded by ADR-020

> Its rationale was "a single user". The repository became public, which removed the
> premise; **ADR-020** adopted Sparkle as this ADR said a later one would have to.

**Decision.** There is no update check in v1; the user downloads the new `.dmg` from
GitHub Releases.

**Rationale.** A single user. Sparkle brings appcast.xml hosting and a separate EdDSA
signing infrastructure; at this stage there's nothing to show for that.

**Alternative (Phase 6, optional).** The lightest middle ground: on launch the app reads
the latest tag from the GitHub Releases API, shows a "there's a new version"
notification and opens the download page. No automatic installation. If that is decided
on, a new ADR gets written.

---

## ADR-011 — The Xcode project is generated from `project.yml`; the pbxproj is not committed
**Date:** 2026-10-01 · **Status:** accepted

**Context.** `.xcodeproj/project.pbxproj` is a machine-generated file thousands of lines
long. Editing it by hand is error-prone, and every new Swift file changes it.

**Decision.** The project is generated from `app/project.yml` with XcodeGen (2.46.0).
`app/WhisperTranscriber.xcodeproj/` and the generated `Info.plist` are in `.gitignore`.
`make generate` produces it; `make build` and `make archive` call that first.

**Rationale.** Source files are collected from the directory automatically — adding a
new file doesn't mean touching the pbxproj. Build settings can be reviewed as readable
YAML. A full build is possible without opening Xcode.

**Rejected.**
- *Writing the pbxproj by hand and committing it:* possible in a single-target project,
  but every added file means editing a 20-plus-line block full of UUIDs.
- *Swift Package Manager:* can't produce the `.app` bundle, the Info.plist or the
  signing flow.
- *Tuist:* heavier than XcodeGen; nothing to show for it at this scale.

**Consequences.** XcodeGen becomes a development dependency (`brew install xcodegen`).
Settings changed by hand in Xcode are lost at the next `make generate` — they must be
changed in `project.yml`. `make doctor` reports whether xcodegen is present.

**Phase 0 note.** The `copyFiles` schema must be written **nested under `buildPhase:`**
in the sources entry; written as a sibling, XcodeGen ignores it silently and the files
are never copied into the bundle. That's a hard failure to notice, because the build
still looks successful — which is exactly why the `BundledResources` check inside
`ContentView` exists.

---

## ADR-012 — MPS stays experimental; on failure the job is retried on the CPU
**Date:** 2026-10-01 · **Status:** accepted

**Context.** `torch` supports the MPS backend on Apple Silicon, but `openai-whisper` is
not reliable on MPS: some kernels are missing, and some models produce silently
corrupted output or a runtime error. The speed-up potential is high even so, which is
why we don't want to remove the option entirely.

**Decision.** `mps` is offered in the device selection labelled **"(experimental)"** and the
default stays `cpu`. If a job fails with MPS, the queue does not drop it: it switches
the device to `cpu` and retries **once**. The fallback is not hidden from the user — the
log lines from the failed MPS attempt are preserved and the line
`[warning] MPS failed, retrying on the CPU.` is appended to the log.

**Rationale.**
- What matters to the user is the result: the transcription finishing matters more than
  which backend was used.
- A silent fallback is unacceptable; marking MPS experimental and then hiding the error
  would mean the user never learns that MPS doesn't work.
- The retry happens **once**, and because the device is `cpu` on the second attempt the
  condition can't be met again; there is no risk of a loop.

**Consequences.**
- A job that fails on MPS completes with a delay equal to the CPU time.
- The queue row shows the job as completed; the MPS fallback is only visible from the
  LOG tab. That's deliberate: we don't present it as an error in the main flow.

---

## ADR-013 — A settings block decodes resiliently against missing keys; empty optionals are written as an explicit `null`
**Date:** 2026-10-01 · **Status:** accepted

**Context.** `WhisperSettings` is stored as JSON inside `UserDefaults`. Swift's
synthesised `Decodable` decoder **throws on a missing key**, and `SettingsStore.load()`
was swallowing the error and falling back to the defaults. The result: every time a new
settings field was added to the app, all of the user's settings were silently reset.

A second problem: the synthesised **encoder** omits `nil` optionals. That made "no key"
(an older block) indistinguishable from "the user deliberately cleared it". Because the
default for `beamSize`/`bestOf` is `5` and for `language` is `"tr"`, losing that
distinction silently broke CLI equivalence: a missing key → `nil` → greedy decoding →
output that differs from the whisper CLI's.

**Decision.**
1. `init(from:)` is written by hand; every field is read resiliently and a missing field
   falls back to **its default**, leaving the other settings intact.
2. `encode(to:)` is written by hand. The three optional fields whose default is **not**
   `nil` (`language`, `beamSize`, `bestOf`) are always written — explicitly as `null`
   when empty. For those, the decoder checks `contains(key)`: no key means the default,
   a present key (including `null`) means the stored value.
3. Optionals whose default is `nil` (`maxLineWidth`, `customOutputDirectory` and so on)
   continue to be omitted; there, absence and `null` mean the same thing.
4. The same pattern is applied to `AppPreferences`.

**Rationale.** The "no key ≠ `null`" distinction that already exists in the protocol
(`docs/WHISPER_OPTIONS.md` → null semantics) should hold in the settings store too. The
alternative — a version number plus migration code — is too heavy for a structure this
size; reading the fields one by one is both explicit and testable.

**Consequences.**
- Adding a new settings field no longer drops the user's settings.
- `CodingKeys` is written out explicitly: changing a field's **name** resets that
  setting to its default. If a field is to be renamed, a migration that also reads the
  old key must be added.
- Every field added to `WhisperSettings` and `AppPreferences` owes a line to the "older
  block" test in `PreferencesTests`.

---

## ADR-014 — The worker produces the "notes" format with its own writer
**Date:** 2026-10-02 · **Status:** accepted

**Context.** The user wants a timestamped note list for skimming a recording
afterwards: `- [04:12] sentence`. None of whisper's `get_writer()` writers produces
that. `srt`/`vtt` carry timestamps but they are subtitle files; `tsv` is for machines;
`txt` has no timestamps.

This conflicts with the rule "we don't format output files, we use whisper's own
writers" (CLAUDE.md, architecture rule 5).

**Decision.** The exception to the rule is confined to **a single format**. The `notes`
format is written by `write_notes()` inside the worker; whisper's five formats
(`txt/vtt/srt/tsv/json`) keep going through `get_writer()` as before. The exceptions are
listed in the `_OWN_FORMATS` constant.

**Rationale.**
- The purpose of rule 5 is **CLI equivalence**: if we rewrite a format whisper produces,
  the output diverges from the command line's. `notes` has no counterpart on the command
  line, so there is no reference to diverge from.
- Moving the writing to Swift would be worse: atomic writes, the overwrite check and
  cleaning up the temporary directory are already in the worker and should stay in one
  place.
- The format name (`notes`) and the extension (`md`) diverge for the first time;
  `format_extension()` is the single source of that mapping.

**Consequences.**
- If another "our own" format is added, it joins `_OWN_FORMATS` and this ADR widens.
- `write_outputs` doesn't load `whisper.utils` at all for a job that asks only for
  `notes`.
- Segments with empty text are skipped: whisper can emit empty segments during silence,
  and those showed up as empty bullets in the note list.

---

## ADR-015 — Decoding options removed from the interface and not written into the job definition
**Date:** 2026-10-02 · **Status:** accepted (supersedes part of ADR-013)

**Context.** In Phase 4, every advanced parameter from the `WHISPER_OPTIONS.md` table
was put into the interface: beam width, the temperature ladder and the fallback step,
the three thresholds, the hallucination threshold, word timestamps, subtitle wrapping,
the thread count, fp16, the initial prompt. The user doesn't use any of them and asked
for the app to be simplified.

The presence of those settings was also a source of risk: ADR-013 records that leaving
the `beam_size` key out silently broke CLI equivalence.

**Decision.** The advanced section was removed from the interface entirely and the
corresponding fields were deleted from `WhisperSettings`. The job definition now
**carries no decoding key at all**; the single exception is `fp16`, and even that isn't a
user setting but derived from the device (`false` on CPU, key absent otherwise).

Device selection (CPU / MPS) moved from the main panel to the **Settings → Runtime
environment** tab; it isn't something that changes per job.

**Rationale.**
- Not sending a key is **safer** than sending it: the worker already applies the command
  line's `beam_size=5`, `best_of=5` and temperature ladder through
  `_CLI_PARITY_DEFAULTS`. Equivalence is defined in one place, in the worker.
- The UI values of the thresholds (`no_speech_threshold` and friends) were already
  identical to whisper's own defaults; sending them changed nothing.
- The protocol did not shrink: the worker still accepts every key, it is only the v1
  interface that doesn't send them. If an "expert mode" is added later, the protocol is
  ready.

**Consequences.**
- If the defaults change when the `whisper` version is bumped, the output changes with
  them; `test_output_is_identical_to_the_cli` catches that.
- Advanced keys in the user's older settings block are discarded silently while reading;
  the remaining settings are preserved (`PreferencesTests` → the older-block test).
- The "explicit `null`" rule ADR-013 introduced for `beamSize`/`bestOf` now applies only
  to `language`. The rule about decoding resiliently against a missing key stands
  unchanged.
- The initial prompt is gone too. If it's ever wanted back it's a one-field addition;
  the worker side (`initial_prompt`) is still there.

---

## ADR-016 — The microphone entitlement was added (the first exception to ADR-007)
**Date:** 2026-10-02 · **Status:** accepted

**Context.** ADR-007 keeps the entitlement list empty and says an entitlement will be
added only *"if a real runtime failure requires it"*. Phase 7.1 requires microphone
access; the entitlement was **not added first** — the behaviour was measured.

**Measurement (2026-10-02).** The app was run without
`com.apple.security.device.audio-input`, with Hardened Runtime on and a Debug signature,
and a recording was attempted. The log is quoted as it was recorded, while the app's
interface was still Turkish — `logs/recording.log`:

```
kayıt isteği — mikrofon durumu: undetermined
izin soruldu — sonuç: denied
kayıt başarısız: Mikrofon erişimine izin verilmedi.
```

Two observations together are decisive:
1. The initial state is `undetermined` — that is, TCC holds no record at all for this
   app.
2. `AVCaptureDevice.requestAccess(for: .audio)` returned `denied` in **under a second**,
   and the app **never appeared** in System Settings → Privacy & Security → Microphone.

Had the user seen a permission dialog and refused it, the app would appear in that list
(switched off). Its absence means the dialog was never shown: the request was refused at
the signing layer, before reaching TCC.

**Decision.** `com.apple.security.device.audio-input` is added to the entitlements file.
No other entitlement is added; App Sandbox is not added.

**Rationale.** Hardened Runtime's resource-access entitlements are not things to add
"just in case" — they are a **precondition** of access. The measurement proved it, and
the exception route ADR-007 anticipated was written for precisely this situation.

**Consequences.**
- The signature changed; a new notarization round is needed before release.
- If TCC has already cached a denial for this app, the dialog may still not appear after
  the entitlement is added; the fix is
  `tccutil reset Microphone com.talhaturhan.WhisperTranscriber`.
- System audio capture was measured the same way in Phase 7.2: **it needs no
  entitlement and no extra permission.** A capture with `source: both` recorded 51.9 s
  successfully without one, so nothing was added.

---

## ADR-017 — Deleting a model is allowed, from the app, one file at a time
**Date:** 2026-10-03 · **Status:** accepted · **Amends:** ADR-005

**Decision.** The Models tab gets a delete button on each downloaded model. It asks for
confirmation, naming the model and the space it frees, and then removes exactly one file:
`<model>.pt` in the folder the worker reported. The app still never removes the model
folder itself, and there is no "delete all".

The deletion is done in Swift with `FileManager`, not through the worker protocol. The
protocol is a transcription contract; adding a file-management verb to it would mean a
version bump, a new event, and a round trip through a child process for an operation that
is one call. `ModelStore` holds the rules, and the Models tab is its only caller.

**Rationale.** ADR-005 said the app never deletes from the user's `~/.cache/whisper`,
and the reasoning there was about not destroying a 4.8 GB download the user already had.
That protects the user from the *app*, but it also left them without the one thing the
folder actually needs: a way to reclaim the space from inside the app that filled it. A
`large-v3` the user tried once is 3 GB sitting there, and sending them to Finder to find
a `.pt` file by name is worse than a button — they can delete the wrong thing there, with
no list of which names are models.

So the protection moves from "never" to "only what was asked for":

- the name must be one the **worker** reported in `capabilities`, so a value from
  anywhere else cannot reach `removeItem`;
- it must be a plain file name — no separator, no traversal, no leading dot;
- the target must be a **regular file**. If `tiny.pt` turned out to be a directory,
  `removeItem` would take the tree with it, so that case is refused instead;
- one model per confirmed action. No sweep, no "free up space" button that decides for
  the user.

**Consequences.**
- ADR-005's "never deletes" no longer holds as written; its default-directory decision
  and its rationale are untouched.
- The directory the file is deleted from comes from `capabilities.model_dir`, not from
  `settings.modelDirectory`. Those can differ — `capabilities` always measures the
  worker's default directory — and the sizes shown in the tab come from the same place,
  so the delete and the number next to it always refer to the same file.
- A deleted model is gone, not in the Trash: `removeItem` is not a move to the Trash, and
  whisper re-downloads it on next use. The confirmation says so.
- `ModelStoreTests` covers the refusals, not just the happy path, including the directory
  impostor and the folder surviving the deletion of the last model.

---

## ADR-018 — A CPU budget for transcription, and a memory warning instead of one
**Date:** 2026-10-03 · **Status:** accepted · **Refines:** ADR-015

**Context.** On an 8 GB M1 MacBook Pro, transcribing with `medium` made the whole machine
unusable. The request was a CPU limit, accepting a slower run. Measuring first changed what
got built, so the numbers are here rather than in a commit message.

**What the measurements said** (M4, 4 performance + 6 efficiency cores, 16 GB; the 24 s
fixture, `small`, warm page cache):

| threads | time | output |
|---|---|---|
| unlimited | 8.2 s | identical |
| 4 | 8.2 s | identical |
| 3 | 8.7 s | identical |
| 2 | 9.7 s | identical |

Three things follow.

1. **A thread limit is cheap.** 3 threads costs about 5%, 2 costs about 18%. "Let it take
   longer" turns out to be a small price.
2. **torch already limits itself.** Its default was 4 — the performance-core count, not the
   10 cores the machine has. Unlimited and 4 are the same run. So the thread count was never
   the pathology, and a budget has to go *below* the P-core count to do anything.
3. **The transcript does not change.** This mattered more than the timings: thread count
   changes the order floating-point reductions happen in, so it could have flipped a token
   and broken the project's central claim. It did not, at any count, and
   `test_a_thread_limit_does_not_change_the_output` now pins it.

Peak memory, same fixture, measured with `ru_maxrss`:

| model | file | peak RSS | time |
|---|---|---|---|
| `small` | 461 MB | 2.10 GB | 8.3 s |
| `medium` | 1.4 GB | 4.38 GB | 24.4 s |
| `large-v3-turbo` | 1.5 GB | 4.64 GB | 10.7 s |

**This is the actual cause of the reported problem.** `medium` wants 4.4 GB on a machine
with 8 GB, where macOS wants about 3 GB of its own; it swaps, and swapping is what the user
felt. No CPU limit fixes that. (`large-v3-turbo` is also worth noting: the same memory as
`medium` for 2.3× the speed.)

**Decision.** Both, because they answer different halves.

*The budget* is `CPUBudget` — `full`, `balanced` (the default), `light` — with two levers:

- `options.threads`, which the worker gives to `torch.set_num_threads()` and now to ffmpeg
  as well, since `-threads 0` had let decoding take every core too. It is also exported as
  `OMP_NUM_THREADS` and friends, because those pools size themselves when torch is imported,
  before the worker has read the job.
- `Process.qualityOfService`: `.utility` for balanced, `.background` for light. This is the
  lever that actually keeps the interface smooth, because on Apple Silicon it steers the work
  onto the efficiency cores. It is **not** in the protocol — it describes how the app spawns
  a child process, which is no business of the worker's — so it rides on `TranscriptionJob`
  as a field deliberately left out of `CodingKeys`.

Thread counts come from `hw.perflevel0.physicalcpu`, not from a constant: `balanced` leaves
one performance core free, `light` takes half of them. On both an M1 and a base M4 that is 3
and 2.

*The warning* appears when a model's estimated peak exceeds half the installed memory. The
estimate is `1.0 GB + 2.5 × the model's file size`, fitted to the three measurements above
and accurate to within 1% on all of them. It is computed from the size the worker already
reports rather than a table of models, for the same reason the worker refuses to tabulate
sizes it has not measured: a table would quietly go stale at the next whisper release.

**Why `threads` in `options` does not contradict ADR-015.** ADR-015 keeps *decoding*
parameters out of the job definition so that CLI equivalence is defined in exactly one
place. `threads` is a resource limit: it changes how long a run takes and never what it
produces, which is now measured rather than assumed. `options` is therefore asserted as a
closed set — `{fp16, threads}` — rather than a list of forbidden names, so a real decoding
key leaking in still fails the test.

**Consequences.**
- The default changed. A transcription now runs at utility priority with one core free, so
  it is about 5% slower than before and the Mac stays usable. `full` restores the old
  behaviour.
- `light` uses background QoS, which macOS throttles hard. That is the point, but it means
  a long file can take considerably longer than the 18% the thread count alone suggests.
- The memory estimate is only available for downloaded models, because an undownloaded one
  has no reported size. No size, no warning.
- The measured numbers are from one machine. They are a guide to the shape of the problem,
  not a promise about every Mac.

---

## ADR-019 — Model size and language are separate controls; a model can be fetched on its own
**Date:** 2026-10-03 · **Status:** accepted · **Extends:** ADR-017

**Context.** `whisper.available_models()` returns one flat list of fourteen names that mixes
two independent things:

```
tiny.en  tiny  base.en  base  small.en  small  medium.en  medium
large-v1  large-v2  large-v3  large  large-v3-turbo  turbo
```

A **size** and a **language variant** — `.en` is the English-only build. A single picker
makes `small.en` look like a peer of `small` rather than a different answer to a different
question, and picking it for Turkish audio produces nonsense. There was already a warning
for exactly that mistake, which is the sign the control was wrong rather than the user.

**Decision.** Two pickers: a size, and a model language (*All languages* / *English only*).
The second is disabled when the chosen size has no `.en` build, which is the case for every
large model. `settings.model` is still the single composed string, so nothing in the protocol
or the stored settings changes.

The split is **mechanical**: the size is the name with a trailing `.en` removed, the variant
is whether that suffix was there. No table of models, so a size a later whisper version adds
is categorised without a code change — the same principle as reading capabilities instead of
hard-coding them. `ModelCatalog.resolve` composes a name back and is the only way the two
pickers write to `settings.model`, because `large-v3` + English-only would otherwise compose
`large-v3.en`, which does not exist; a test asserts every size/variant pair resolves to a
name the worker actually reported.

The sizes keep the worker's order rather than being sorted: it lists them smallest first,
and sorting alphabetically would put `large` before `small`.

**Downloading on demand.** A new worker mode, `download`, fetches one model and exits. It
introduces **no new event type**: the `downloading_model` status and the `progress` events
are the ones a transcription already sends, and success is a clean exit. An older app
therefore has nothing new to fail to understand, and the protocol version is unchanged.

- It is **not** on `TranscriptionEngine`. A `.pt` file in a model folder is this engine's own
  concept — whisper.cpp would want a ggml file from somewhere else — so it follows the
  precedent `LiveTranscriptionEngine` set and stays off the shared contract (ADR-003).
- It uses `whisper._download` and `whisper._MODELS`, a **fourth** coupling to whisper's
  internals alongside the three in CLAUDE.md. The public `load_model` would also download,
  but it then loads the weights into memory — 3 GB for `large-v3`, on the machines least able
  to spare it. Fetching the file without loading it is the point.
- There is **no "already downloaded, nothing to do" shortcut on the file existing.** An
  interrupted download leaves a truncated `.pt` behind, and calling that a success is a lie
  that only surfaces later as a load failure. `whisper._download` verifies the SHA256 of an
  existing file and re-downloads on a mismatch, so the decision is left to it; this was
  tested by truncating a complete model and watching it come back.
- One download at a time. A second request is ignored rather than queued: two downloads
  would only halve each other's bandwidth.

**Progress is throttled.** whisper reads in 8 KB chunks, so the sink fired about 9 000 times
for `tiny` — and would fire roughly 375 000 times for `large-v3`, all of it NDJSON the app
parses line by line. `_download_progress_sink` emits once per whole percent, measured at 102
events for `tiny`. A download whose server sends no `Content-Length` has no percentage to
throttle on, so it falls back to one event per megabyte; the first version of this silently
emitted nothing in that case, which is what the test for an unknown total now prevents.
The transcription sink is left alone — it updates at 30-second window boundaries and never
flooded.

**A settings button on the main window.** `SettingsLink`, not a hand-rolled
`showSettingsWindow:` action, which misbehaves when the window is already open. ⌘, keeps
working as before.

**Consequences.**
- The model picker no longer shows fourteen entries; it shows ten sizes, four of which offer
  a language choice.
- The aliases `large` and `turbo` remain listed, because knowing they duplicate `large-v3`
  and `large-v3-turbo` is model knowledge, not structure, and hiding them would mean the
  hard-coded table this design avoids.
- The Models tab now has three states per row: a trash button for what is downloaded, a
  download button for what is not, and a progress bar for the one in flight.
- Bumping `openai-whisper` now means checking a fourth internal coupling, not three.

---

## ADR-020 — Sparkle, for updates that install themselves
**Date:** 2026-10-03 · **Status:** accepted · **Supersedes:** ADR-010

**Context.** ADR-010 refused Sparkle with a one-line rationale: "a single user". That
premise is gone — the repository is public and the `.dmg` is downloadable by anyone, so
"the user will notice a new release and drag it in again" is no longer a plan. ADR-010 also
anticipated this and said a new ADR would be written if it changed.

**Decision.** Sparkle 2.10.0, pinned exactly, for the full cycle: check, download, verify,
install, relaunch.

**Why not hand-rolled.** Checking a version and downloading a file is easy, and neither is
the problem. The problem is that **an application cannot replace itself while it is
running**, and doing it anyway means a staged copy, an external helper to swap the bundle
after the app exits, correct handling of quarantine and app translocation, and a relaunch.
Sparkle ships exactly that — `Autoupdate`, `Updater.app` and two XPC services, all of which
appear in our bundle and are verified at signing time. Writing a worse version of it would
risk leaving a user with no working app at all.

**The framework comes from SPM, the tools are vendored.** Xcode embeds and signs the
framework together with its four nested helpers; getting that right by hand is most of what
Sparkle does for us. The signing *tools* (`generate_keys`, `sign_update`) never ship, so
`make bootstrap` fetches them into `vendor/` the way it already fetches `uv` — with the
sha256 pinned in `versions.env`, because Sparkle publishes no sibling checksum file and a
release an attacker could replace would carry a checksum they could replace too.

This is the project's **first third-party Swift dependency**. It earns the exception by
doing the one thing that cannot be done safely in-process.

**Trust.** Two independent signatures have to hold before an update installs:

- Apple's: the new `.dmg` is Developer ID-signed, notarized and stapled, exactly as before.
- Ours: an **EdDSA (Ed25519)** signature over the `.dmg`, checked against `SUPublicEDKey`
  in the running app. Its private half is generated once and lives **only in the keychain** —
  never in the repository, never in `local.env`. Losing it means no installed copy will ever
  accept another update, so it belongs in the same backup as the Developer ID certificate.

`make_appcast.sh` refuses to produce a feed if the key in the **built bundle** is not the
counterpart of the key in the keychain. That failure would otherwise be invisible here and
total on everyone else's machine; the guard was tested by swapping the key and watching the
release stop.

**The appcast needs no hosting.** It is uploaded as an asset of each release, and
`https://github.com/tallhigh/whisper-mac-app/releases/latest/download/appcast.xml` always
redirects to the newest one. No GitHub Pages, no separate server, nothing else to keep alive.

A one-item feed is deliberate: Sparkle only compares the newest item against the running
build, and `generate_appcast` — which infers a whole feed by scanning a directory of
archives — would be guessing at what the release script already knows exactly.
`sparkle:version` is the build number, which `release.sh` already increments monotonically.

**Scheduling — measured after the first release, not assumed.** 1.1.2 went up nine minutes
after 1.1.1, and a machine running 1.1.1 did not offer it until the menu item was used. The
cause was not a missing first-launch check: Sparkle treats an absent last-check date as
`distantPast`, decides it is overdue and checks straight away, which it had done — and found
nothing, because 1.1.1 *was* the newest release at that moment. Having recorded the time, its
next scheduled look was a day later.

That default is wrong for an app like this. `SUScheduledCheckInterval` is therefore set to
**3600**, which is also Sparkle's own floor (it clamps anything smaller). The interval is
counted from the last check rather than from launch, so at an hour, opening the app is in
practice a check, while opening it twice in one hour politely does not ask GitHub twice.
`UpdateControllerTests` pins the key, because losing it silently restores the day.

**Consequences.**
- Releasing now also signs the dmg with the EdDSA key and uploads `appcast.xml`. A release
  made on a machine without that key in its keychain **stops before notarizing**, rather
  than publishing a release nothing can update to.
- `make bootstrap` is required before a release, not just before a build.
- The bundle grew by Sparkle's framework and helpers; the dmg went from 17 MB to 19 MB.
- A Debug build carries no feed URL, so `UpdateController` is inert there. It is inert under
  the test runner too, by default — otherwise Sparkle would ask for permission and schedule
  a network request in the middle of a test run.
- Bumping Sparkle means changing both `SPARKLE_VERSION` and `SPARKLE_SHA256`, and the
  version in `app/project.yml`, which is deliberately duplicated so the framework and the
  tools can never silently disagree.
- Users on 1.1.0 or earlier have no updater, so they upgrade by hand one last time. From
  1.1.1 onwards it is automatic.
