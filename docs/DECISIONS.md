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

---

## ADR-021 — Past recordings are listed from the folder, with no index
**Date:** 2026-10-03 · **Status:** accepted, amended by ADR-024

> The window this ADR describes became a **sidebar tab**, and the list grew to cover dropped
> files as well as recordings. The folder scan and the Trash decision below are unchanged.

**Context.** A finished recording was only visible for as long as its job sat in the queue.
The audio was on disk the whole time, in `~/Documents/Whisper Transcriber/`, but nothing in
the app would show it, so "what did I record last week" meant going to Finder.

**Decision.** A **Recordings** window (⇧⌘L), listing the `.m4a` files in the recording folder
newest first, with the transcripts found for each. Per row: transcribe again, show in Finder,
open a transcript, move to Trash.

**No index file.** The folder is the record. A recording the user moved or deleted in Finder
simply is not in the list, with nothing to reconcile and no way for a stored index to drift
out of step with the disk — the same reasoning as reading capabilities from the worker rather
than hard-coding them. The cost is that a recording moved elsewhere disappears from the list,
which is the honest answer: the app does not know where it went.

**Transcripts are matched exactly, never by prefix.** A recording called `Meeting.m4a` must
not claim `Meeting notes from last year.txt`. The only names accepted are the ones the writers
produce: the stem, or the stem plus the live suffix, with a format's own extension. Both the
recording's folder and the chosen output folder are searched, and a file found twice is listed
once. A test covers the prefix trap specifically, because it is the kind of bug that looks
like a feature until it attaches someone's unrelated notes to the wrong audio.

**Deleting moves to the Trash.** This is the one deletion in the app that stays recoverable,
and the difference from ADR-017 is the point: a model file can be downloaded again, a
conversation that happened once cannot. The transcripts are left where they are — they are
the part worth keeping.

**Consequences.**
- The list is read on every appearance rather than cached, so it costs a directory scan. At
  the scale of a recordings folder that is nothing.
- Duration is not shown. It would mean opening every file with AVFoundation to read it; date
  and size come free from the directory scan.
- A window and a menu item, not a pane: the queue is what is running now, this is what
  happened before.

---

## ADR-022 — Finishing a recording does not wait for the worker
**Date:** 2026-10-03 · **Status:** accepted

**Context.** Pressing Finish left the sheet on screen for seconds, and longer the longer
you had talked without pausing. It looked like it was waiting for silence.

**What it was actually doing.** The live worker re-transcribes its uncommitted buffer every
1.5 seconds and commits only the segments that end before a stability margin. During
uninterrupted speech whisper produces no segment end, so nothing commits and the buffer grows
— up to 30 seconds. `stop` makes the worker transcribe that whole remaining buffer one last
time, and `RecordingController.finish()` awaited the process exit inline, with the sheet still
up. So the wait was real, it scaled with how long since the last natural pause, and a pause
made it short — which is why it looked like silence was the trigger.

**Decision.** `finish()` sends `stop` and returns. The wait became `waitForFinalText()`, which
`AppState.finishRecording()` calls **after** closing the sheet, with `isFinalizing` driving a
"Finishing the live text…" status in the toolbar.

This is safe because `apply(_:)` never checked the recording state: committed text arriving
after `finish()` has returned still reaches `transcript`, which is what the live text file is
then written from.

**The order is deliberate.** The accurate second pass is queued only after the live text has
landed. Starting it immediately would put two whisper processes on the machine at once, which
on an 8 GB Mac is precisely the memory problem ADR-018 was about.

**What was not done.** The wait itself was not removed — the last few seconds of speech
genuinely are not transcribed yet when you press Finish, and discarding them to make the
button feel fast would lose text the user said. Shortening `_STREAM_STABLE_MARGIN_SECONDS` or
the 30-second ceiling would trade accuracy for latency in the live preview; neither was
changed without a measurement to justify it.

**Consequences.**
- The sheet closes immediately. The work continues visibly in the main window.
- A recording finished while the Recordings window is open appears in it when the status
  clears, which is what that window watches `isFinalizing` for.
- `LiveSession.finish()` still exists as `requestStop()` + `awaitExit()`, so the old
  all-in-one behaviour is available where blocking is correct.

---

## ADR-023 — A menu bar item, present only while something is happening
**Date:** 2026-10-03 · **Status:** accepted

**Context.** Recording and transcribing both continue with the window closed or behind
something else. "Is it still recording?" meant finding the window, which is the wrong amount
of work for that question.

**Decision.** A `MenuBarExtra` showing a symbol plus a short piece of text: the elapsed time
while recording, the percentage while transcribing. Its menu says what is happening in words
and offers the one or two things worth doing from there — finish, pause, resume, stop — plus
a way back to the window.

**It is inserted only while the app is busy**, through `MenuBarExtra(isInserted:)`. A
permanent icon for an app used in bursts is clutter in a strip the user has already filled;
an icon that appears when work starts and leaves when it ends carries information by its
presence alone.

**`Activity` is a type, not three booleans read by the view.** The states are mutually
exclusive and have a precedence: a recording in progress outranks a queue draining behind it,
and `finalizing` outranks the queue too, because the recording just stopped is still being
finished (ADR-022). Deciding that in one place is what keeps the menu bar and the toolbar from
disagreeing about what the app is doing. `AppState.activity` is that place.

**Details that came out of writing it.**

- A running queue with **no active item** still reports `transcribing`, with an empty name.
  That gap is the moment between two jobs, and reporting idle there would make the item
  flicker out and back in between queued files.
- The text is monospaced-digit. Without it the whole menu bar shifts left and right every
  second as the clock counts up.
- The percentage is **rounded**, not truncated: 99.9% is 100% to someone watching a bar fill.
- The symbol is filled while recording and outlined while merely working, so the two read
  differently at a glance rather than only on inspection.

**Consequences.**
- One rename: `AppState`'s private `activity` — the `ProcessInfo` token that keeps the Mac
  awake — became `sleepAssertion`, which is what it actually is. The name was free to take
  because it was vague for the thing it held.
- The menu duplicates actions that exist in the window and the main menu. That is the point of
  a menu bar item; the duplication is not an accident to be factored away.
- A test asserts no two states share a symbol, because the symbol is the whole message when
  the text is absent.

---

## ADR-024 — One history, in the sidebar, for recordings and dropped files alike
**Date:** 2026-10-03 · **Status:** accepted · **Amends:** ADR-021

**Context.** ADR-021 put past recordings in a window of their own, reachable only by ⇧⌘L —
a feature you had to already know about. And it covered recordings only: a file dropped in
and transcribed left no trace in the app once the queue was cleared, even though that is the
same question from the user's side. *What have I transcribed, and where did the text go?*

**Decision.** The left pane becomes two tabs, **Queue** and **History**. Queue is what is
running now; History is everything that has been through before, recordings and dropped files
in one list. The separate window is gone, ⇧⌘L selects the tab instead, and selecting a row
reads its transcript into the output pane — so a recording from last week can be read without
leaving the app.

**Two sources, because the two kinds leave different traces.**

- A **recording** lives in a known folder, so it can be found by scanning (ADR-021). That
  still holds, and a recording never transcribed still shows up because of it.
- A **dropped file** can be anywhere on disk and its outputs sit beside it or in a chosen
  folder. Nothing can be scanned. For those a written record is the only way, so completed
  jobs are appended to `history.json`.

The two are merged by standardized source path, and the stored entry wins: it is the one
that knows what the run produced. This is not a contradiction of ADR-021's "no index" — that
decision was about not keeping an index of something the disk already answers. Here the disk
does not answer it.

**Details that are deliberate.**

- Running the same file again **replaces** its row rather than adding one. The list answers
  "what have I done", not "how many times".
- An entry whose source file has since been deleted is **kept** and marked, not dropped.
  It is still a record of work done, and quietly removing it would be the app deciding the
  user's history for them. Its outputs, though, are filtered against the disk every time it
  is read, so the list never offers to open a transcript that is gone.
- The list is capped at 500, so a file that is read and written whole stays trivial.
- "Remove from History" forgets the row and touches no files. "Move Audio to Trash" is
  offered for recordings only, and still goes to the Trash (ADR-021).

**Consequences.**
- `JobQueue` gained `onItemCompleted`, which is how a finished job reaches the history.
- The output pane now has two sources of text: the job being produced, and a finished
  transcript read off disk. Which one shows is decided by the sidebar tab.
- A recording is listed once whether it was transcribed or not, because the merge is keyed
  on the source rather than on the kind.

---

## ADR-025 — The live transcript is always kept, and offered beside the accurate one
**Date:** 2026-10-03 · **Status:** accepted

**Context.** `LiveTranscriptWriter` wrote only the formats the user had ticked, and the live
text can produce only `txt` and `notes` — it has segment text and a timestamp, not the fields
`srt`/`vtt`/`json`/`tsv` need. With **srt and vtt** selected, which is an ordinary choice for
anyone doing subtitles, the live text could produce neither, so nothing was written. It was
shown on screen while recording and then dropped.

**Decision.** `txt` is written for every live transcript regardless of the chosen formats,
plus `notes` when that is selected. The History tab lists both transcripts of a recording and
the output pane picks between them.

**Why it is not filtered like the second pass.** The chosen formats say what the *accurate*
pass should produce, and that pass can produce any of them. The live text is a different
artifact: it is the only record of what was heard while recording, and the accurate pass
produces different text rather than the same text again. Discarding it because the user wants
subtitles throws away the one thing that cannot be made again. The second pass stays filtered
exactly as before.

**The accurate text is the default, not the live one.** This went the other way first, on the
reasoning that the live text is what someone opening a past recording is after — a test
written against that comment is what showed it up. The accurate pass is simply the better
transcript; opening the preview by default would hand the user the worse of the two every
time. The live version is one click away in the picker, labelled `txt · live`.

**The live file has to be discovered, not stored.** It is written when the recording ends,
*before* the job whose completion gets recorded in the history, so it was never in the stored
outputs. `JobHistory.refreshed` therefore scans beside the source as well as filtering what is
stored — which also means a transcript produced later shows up without any bookkeeping.

**Consequences.**
- A recording now always leaves at least one text file behind, even when the settings ask
  only for subtitles. That is one more file than before in that case, and it is the point.
- The output pane has two different pickers depending on the sidebar tab: TEXT/LOG for a
  running job, the available transcripts for a history row.
- `LiveTranscriptWriter.formats(for:)` is the one place that decides, so the rule is testable
  without writing files.

## ADR-026 — System audio is captured per **app**, and its level is shown separately

**Status.** Accepted. Amends ADR-021's audio-source design.

**Context.** The report was "AirPods on, YouTube playing in Chrome, but only the microphone is
recorded". Measuring it with a probe that rebuilds the tap and aggregate exactly as the app
does, and reports the RMS of each input buffer separately, turned up three separate things.
Only the first explains that particular recording; the other two are worse.

1. The saved `recordingSource` was `microphone`. The app recorded exactly what it was told,
   and nothing anywhere on screen said system audio was being left out.
2. **The app picker could not offer Chrome at all.** Core Audio reports *processes*; Chrome
   plays through a renderer helper whose `NSRunningApplication` is `nil`, so the list showed
   `com.google.Chrome.helper` and no entry called "Google Chrome". Worse, a tap installed on
   Chrome's main process — the one a user would pick if it were offered — produced **nothing**:
   over six seconds with audio playing the IOProc was not called once, while a tap on the
   helper delivered the audio at full level (rms 0.131). `AudioHardwareCreateProcessTap`
   returns `noErr` either way, so no error was raised and the recording "succeeded".
3. **`SystemAudioCapture` never stored `onSamples`.** The field was declared, read in
   `emitSamples` and cleared in `stop()`, but never assigned — `MicrophoneCapture` assigned
   its copy. Live transcription therefore produced nothing at all whenever the source was
   anything other than the microphone alone.
4. **A tap whose processes produce nothing kills the whole recording**, not just the system
   side. The aggregate then has no input stream, so the IOProc is never called — *including*
   for the microphone sub-device — and the file comes out zero seconds long and is deleted as
   too short by the existing length check. Measured: `duration written: 0.00 s`, zero level
   reports, zero samples, and no error anywhere. This is what picking an app and then letting
   its audio stop looks like.

**Decision.**

*The unit of selection is the app, not the process.* `AudioApplication` replaces the
per-process entry. `AudioProcessList.group` collapses every audio-producing process under the
app that owns it, found by walking the parent-pid chain until a process macOS considers an
application. Chrome's helpers are therefore one entry called "Google Chrome".

*The app's processes are resolved when recording starts, not when the picker was filled.*
Renderer helpers come and go with the tabs, so the pids behind an entry are stale within
seconds. `AudioProcessList.objectIDs(for:)` matches on the bundle id at tap time, which makes
"Google Chrome" mean "whatever Chrome is playing through right now". The app's `id` is the
bundle id rather than a pid, so the selection survives a refresh.

*A tap with nothing behind it is refused up front.* Before the tap is created, at least one
of the resolved processes must have an active output stream; otherwise `noAudioProcess` is
raised, whose existing text — "The selected app isn't playing any audio right now", "Start the
audio in the app and try again" — is exactly the advice needed. And because that guard only
covers the cause we know about, `RecordingController` also watches for having received nothing
at all: the ticker, not the level handler, has to be what notices, since the level handler is
the thing not being called.

*The two sources are metered apart.* `CaptureLevels` carries the combined level plus the
microphone's and system audio's own contributions. The aggregate lays its input channels out as
the sub-devices in list order followed by the taps — measured, not assumed — so the first
`microphoneChannels` channels are the microphone and the rest are the tap. The recording sheet
shows one meter per source when both are captured, and after five seconds of a tap delivering
nothing it says so in words.

**Why a separate meter rather than an error.** A silent tap is not a failure: the tap is
installed, the device is running, the file is being written, and the microphone side is
perfectly good. There is nothing to fail. What was missing was any way for the user to find
out — and a single meter fed by the *sum* of a live microphone and a dead tap dances
convincingly, which is why the problem survived to be reported from the transcript instead.

**Unknown is not zero.** If the channel arithmetic doesn't add up, both halves are reported as
`nil` and the warning stays away. Telling the user there is no system audio on the strength of
a layout we failed to parse would be worse than saying nothing.

**Why the default source stays `microphone`.** `.both` installs a tap, and a tap means a
system permission prompt on first use. Making it the default would put that prompt in front of
someone who only wanted to dictate a note. The fix for the original confusion is that the
sheet now *shows* which sources are live, not that the default changed.

**Consequences.**
- `SystemAudioScope.processes` becomes `.apps`, and `AudioProcess` becomes
  `AudioApplication` with `pids` rather than a single pid and object id.
- `AudioCapturing.start` takes `onLevels: LevelHandler` instead of `onLevel: (Float) -> Void`.
  Both capturers and the test fake report the breakdown; the microphone's is the level twice.
- Live transcription works in System audio and Both mode for the first time.
- The channel attribution is relied on only for the meters. The file is the sum of every input
  channel either way, so a layout we read wrongly costs a meter, never the recording.
- Picking an app whose audio has stopped is now refused at the start of the recording rather
  than producing a zero-second file with no explanation.
- `RecordingController.silenceGrace` is an instance property, not a constant, so the tests can
  shorten it; waiting out the real five seconds twice added ten seconds to a suite that
  otherwise runs in half a second.
