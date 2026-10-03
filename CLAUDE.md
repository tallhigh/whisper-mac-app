# CLAUDE.md

This file is the standing instruction set for Claude Code sessions working in this
repository. Read the active phase in `docs/PLAN.md` before writing any code.

## What the project is

**Whisper Transcriber** — a native SwiftUI app for Apple Silicon Macs.
It turns audio files (m4a, mp3, wav, …) into text with OpenAI Whisper and writes the
result to disk as `txt / srt / vtt / json / tsv / notes`. It can also record live
(microphone, system audio or both) and transcribe as you speak.

The CLI command it has a direct equivalent of — the behaviour the app imitates:

```bash
whisper ~/Desktop/whisper/mehmet.m4a --language Turkish --task transcribe --model small --output_format txt
```

Audience: a single user (the developer). It is **not** going to the App Store; it is
distributed as a Developer ID-signed, notarized `.dmg` through GitHub Releases.

## Language policy

**Everything written in this repository is in English.** That is the default for anything
new, with no exceptions to look for: documentation, code comments and docstrings, commit
messages, release notes, build-script output, `make help`, ADRs, error text in the
diagnostics channel, and whatever file or tool gets added later. If you are about to write
a sentence in Turkish anywhere other than the one case named below, that is the signal
that you are breaking this rule.

This includes the app's **user-facing interface**: every string the user reads on screen is
English. User-facing text still has to be **localizable** (the details are at the end of
this section) — the catalog's source language is `en`, so a Turkish translation can be added
later without touching the code.

The one thing that is **not** English is **Turkish that is the data under test or the data
being quoted** — never prose. Three kinds of thing qualify, and nothing else does:

- **A quoted sample.** A comment or a document that cites whisper's output, the spoken
  fixture text in `scripts/make_test_audio.sh`, and the log excerpt in ADR-016 (a record of
  a measurement taken while the app was still Turkish). Translating these would make the
  text disagree with the thing it describes.
- **Characters that are the point of the test.** `SAMPLE recording 🎙 şçğü.m4a`, the paths with
  Turkish characters and NFD unicode, `sanitize` inputs, the `ensure_ascii=False` check.
  The coding rules *require* this coverage; replacing it with ASCII would delete the test.
- **Turkish as a transcription language.** `language = "tr"`, `.en`-model warnings, and the
  fixtures that exercise them. This is what the user transcribes, not what the repo is
  written in.

Everything else is English, test names included: `@Suite("…")`/`@Test("…")` display names,
the Python `test_*` function names, `#expect` failure messages, and filler test data (a
preset called `Interview`, a file called `Meeting.m4a`). If a Turkish string in a test is
not one of the three cases above, it is incidental and belongs in English.

Where the rule lands in practice:

- **Code, identifiers and comments: English.** Every comment and docstring in `app/`,
  `python/`, `scripts/` and the `Makefile`, as are the `say`/`warn`/`die` messages and the
  `make help` text.
- **Documentation: English.** `README.md`, this file, everything under `docs/` and the
  generated release notes.
- **Git: English.** Commit messages and tag annotations; `scripts/release_notes.sh` builds
  the release notes straight out of the commit subjects, so a Turkish subject would show up
  on the GitHub release page.
- **User-facing text: English**, and every string must be **localizable**, i.e.
  extractable into the `Localizable.xcstrings` catalog (source language `en`, 256 keys):
  - In SwiftUI, string literals in calls like `Text("…")`, `Button("…")`, `.help("…")`
    and `.accessibilityLabel("…")` **already** count as keys; don't wrap them.
  - Anywhere a plain `String` is returned (an `enum`'s `title`, `NSAlert` text,
    `LocalizedError.errorDescription`) use `String(localized: "…")`.
  - `Text(someString)` does **not** localize (the `StringProtocol` overload); that string
    must already have been through `String(localized:)`.
  - When there is nothing to translate, such as a number or a format, use
    `Text(verbatim:)` — don't pollute the catalog with meaningless keys like `"%@ — %@"`.
  - **Diagnostic text is not localized:** worker output that goes to the LOG tab and the
    log files, `RuntimeError.detail` and `verificationFailed(_:)` details stay technical.
  - The catalog does not fill itself on a command-line build; after adding or changing a
    string, run **`make strings`**.

## The invariant architecture rules

1. **There are two processes.** The SwiftUI app never links Python or torch code into
   itself. Transcription always runs in a separate Python child process
   (`whisper_worker.py`).
2. **Communication has one shape:** a single line of JSON job definition into stdin → an
   NDJSON event stream out of stdout. The protocol is defined in `docs/PROTOCOL.md` and is
   **versioned**. If you change the protocol, bump the `v` field and update both the Swift
   decoder and the document in the same commit.
3. **The Python environment belongs to the app.** The user's system Python, their Homebrew
   installation and the `whisper` command on their PATH are **never** used. The app
   installs its own isolated environment under
   `~/Library/Application Support/WhisperTranscriber/runtime/` using the embedded `uv`
   binary. Details: `docs/PYTHON_RUNTIME.md`.
4. **The engine is swappable.** The UI layer talks to the `TranscriptionEngine` protocol.
   In v1 the only implementation is `PythonWhisperEngine`. Don't leak assumptions specific
   to `openai-whisper` into the UI — in v2 a Metal-accelerated `WhisperCppEngine` plugs
   into the same protocol. The live capability lives in a separate protocol,
   `LiveTranscriptionEngine`, so a future engine isn't obliged to support it.
5. **We don't format whisper's formats.** For `txt/vtt/srt/tsv/json` the worker uses
   whisper's own `whisper.utils.get_writer()` writers; the output comes out bit-identical
   to what the CLI produces. The single exception is `notes`: it has no counterpart in
   whisper, so the worker uses its own writer (`_OWN_FORMATS`, ADR-014). That is the
   condition for adding a new format — never rewrite a format whisper already produces.
6. **Decoding parameters are not written into the job definition.** `beam_size`,
   temperature, the thresholds, `initial_prompt` and the like are absent from the
   interface and are not sent; CLI equivalence is provided single-handedly by
   `_CLI_PARITY_DEFAULTS` in the worker (ADR-015). The protocol still carries them — if an
   "expert mode" is added, filling the fields on the Swift side is enough.
   `options` is asserted as a **closed set** of exactly two keys, neither of which can
   change the transcript: `fp16` (silences a CPU warning) and `threads` (a resource limit,
   ADR-018). Before adding a third, establish by measurement that it cannot alter the
   output — a key that can belongs behind an expert mode, not in the default job.

## Directory layout

```
.
├── CLAUDE.md                 # this file
├── README.md                 # for the end user
├── Makefile                  # every development and release command
├── docs/                     # design documents (see the map below)
├── app/                      # the Xcode project (Swift / SwiftUI)
│   └── WhisperTranscriber/
│       ├── Core/             # the engine protocol, provisioner, queue, NDJSON decoder, preset store, audio capture
│       ├── Models/           # TranscriptionJob, WhisperSettings, Capabilities, Recording
│       ├── Views/            # the SwiftUI screens
│       └── Resources/
│           ├── bin/uv        # the embedded uv binary (make bootstrap downloads it; not committed)
│           ├── Assets.xcassets/        # AppIcon (generated by make icon; committed)
│           └── Localizable.xcstrings   # user-facing text (generated by make strings)
│   ├── WhisperTranscriberTests/   # Swift Testing unit tests
│   ├── project.yml           # the source of the Xcode project (ADR-011)
│   └── Version.xcconfig
├── python/                   # the worker source — the ONE source of truth
│   ├── whisper_worker.py
│   ├── requirements.txt
│   └── tests/
└── scripts/                  # build / sign / notarize / dmg / release steps
```

Edit the files in `python/`; Xcode copies them as a folder reference into
`Contents/Resources/python/`. Don't keep a second copy.

## Commands

```bash
make doctor        # audit the environment (xcode, uv, runtime, signature, gh)
make bootstrap     # download the embedded uv binary + verify its sha256
make provision     # install the isolated Python environment (what first launch does)
make generate      # generate the Xcode project from project.yml
make build         # Debug build (generates first)
make run           # build and launch the app
make fixtures      # generate the test audio files (macOS TTS + ffmpeg)
make icon          # generate the app icon from the vector (scripts/make_icon.swift)
make strings       # update Localizable.xcstrings from the strings in the source
make test          # Swift tests + the fast pytest run
make test-python-slow  # the real transcription tests (loads the model, ~42 s)
make lint          # swift-format --lint + ruff
make format        # format the code in place
make archive       # Release archive + Developer ID signature
make notarize      # notarytool submit --wait + staple
make dmg           # build a signed/stapled .dmg (dist/)
make release VERSION=0.1.0   # archive → notarize → dmg → gh release create
```

The one-off setup needed before a release is in `docs/BUILD_AND_RELEASE.md` under
"Prerequisites".

**The `.xcodeproj` is not in git** — it is generated from `app/project.yml` (ADR-011).
Don't change a build setting from the Xcode UI; edit `project.yml`, or the change is lost
at the next `make generate`. Adding a new Swift file needs no pbxproj edit, just put it in
the directory.

## Coding rules

- **Swift 6, strict concurrency.** `RuntimeProvisioner` and the `*Engine` types are each an
  `actor` (that's where the heavy work and the child-process management live). `AppState`,
  `JobQueue` and `TranscriptionItem` are `@MainActor @Observable`: they hold the state the
  views read directly, making them actors would mean copying every read onto the main
  actor, and all they do is coordination. Comment the justification before reaching for
  `Task.detached`.
- **Don't use `Process.waitUntilExit()` to await a child process.** It blocks the calling
  thread; under Swift concurrency that holds a thread from the cooperative pool, and with
  a few processes running at once the pool is exhausted and everything deadlocks (which
  genuinely happened in Phase 3). Use `ProcessRunner.waitForExit(_:)`.
- **Force unwraps and `try!` are forbidden** (tests excepted). Type the error paths under
  `TranscriptionError` and produce an actionable suggestion for every error shown to the
  user ("an internet connection is required to download the model", and so on).
- **The icon is not edited by hand.** The contents of
  `app/.../Assets.xcassets/AppIcon.appiconset` are the output of
  `scripts/make_icon.swift`; to change the shape, the colour or the grid, edit that file
  and run `make icon`. The PNGs are committed (so the build doesn't depend on generating
  the icon); `dist/icon-preview*.png` is not.
- **The Python side is limited to the stdlib plus `whisper`.** Adding a dependency to the
  worker grows the first-launch download; write the rationale into `docs/DECISIONS.md`.
- **Swift has exactly one third-party dependency: Sparkle** (ADR-020), and it earns that by
  doing the one thing an app cannot safely do in-process — replace itself while running.
  Anything else belongs in the standard library or in this repository. A second dependency
  needs an ADR arguing the same kind of case.
- **Sparkle is only touched through `UpdateController`.** No view imports it, for the same
  reason no view knows which engine transcribes.
- The worker's **stdout is the protocol channel.** Never use a plain `print()` on the
  Python side — go through the `emit(event)` function. Details: `docs/PROTOCOL.md`.
- The worker is coupled to whisper's internal API at **four** points:
  `sys.modules["whisper.transcribe"].tqdm`, `whisper.tqdm`,
  `whisper.transcribe.make_safe`, and `whisper._download` with `whisper._MODELS` (the
  `download` mode — ADR-019). When bumping the `openai-whisper` version, verify all four
  **together** with the CLI equivalence test.
- File paths are user data: make sure the tests include paths with spaces, emoji, Turkish
  characters and NFD unicode.

## Never do this

- Don't delete, move or rename the user's `~/.cache/whisper` **directory** — it holds 4.8 GB
  of downloaded models (small, large-v3, large-v3-turbo) and it is **the** default model
  directory. Deleting a single model *file* from it is allowed, but only the way ADR-017 sets
  out: through `ModelStore`, for a name the worker reported, on a confirmed request, one
  model at a time. Nothing else in the app may call `removeItem` on that folder, and there is
  no "delete all".
- Don't write to the system Python, to Homebrew or to the global PATH. The app never calls
  `brew install`.
- Don't add an App Sandbox entitlement (there is no App Store target; the sandbox breaks
  file access).
- Don't commit a certificate, a `.p12`, an app-specific password, a `notarytool`
  credential or **Sparkle's EdDSA private key**. Those live in the keychain (the
  `WHISPER_NOTARY` profile, and the `ed25519` account) and in `scripts/local.env`; none of
  them goes into git. `SUPublicEDKey` in `app/project.yml` is the *public* half and is
  committed on purpose.
- Don't skip the overwrite check when writing into the input file's directory — never
  silently clobber an existing `.txt`.
- Don't embed the model or torch inside the `.app` (see `docs/DECISIONS.md` ADR-001).

## Testing

- **Swift:** Swift Testing (`import Testing`, `#expect`). The NDJSON decoder, the queue
  state machine and job-definition generation are covered by unit tests. The engine tests
  run against a fake "echo worker" script rather than real Python — the tests download no
  model and use no network.
- **Python:** `pytest` against the worker's protocol output, with whisper monkeypatched to
  produce fake segments. The real transcription tests are marked `@pytest.mark.slow` and
  run via `make test-python-slow`.
- **The most critical test is `test_output_is_identical_to_the_cli`.** That the worker's output
  is identical to the `whisper` CLI's is the project's core correctness claim. If that test
  breaks, look at `_CLI_PARITY_DEFAULTS`: the CLI does beam search with
  `beam_size`/`best_of=5` while the library does greedy decoding (see
  `docs/WHISPER_OPTIONS.md`).
- **When adding a field to `WhisperSettings` or `AppPreferences`,** update `init(from:)`
  and (if needed) `encode(to:)`, and add a line to the "older block" test in
  `PreferencesTests`. The synthesised decoder throws on a missing key, which means **all**
  of the user's settings are silently reset (ADR-013). If you add an optional field whose
  default isn't `nil`, read it with `nullable(...)` or CLI equivalence silently drops.
- The manual verification scenarios are the "acceptance-test list" in `docs/PLAN.md`.

## Git

- Commit straight to `main` (a single developer, no PR flow).
- Conventional Commits: `feat:`, `fix:`, `docs:`, `build:`, `refactor:`, `test:`, `chore:`.
  Commit messages are written in English, because `scripts/release_notes.sh` builds the
  release notes straight out of the commit subjects. The history was squashed into a single
  commit at v1.0.0, so every subject from here on reaches a release page.
- Version tags are `vX.Y.Z`; `make release` creates the tag itself, so don't `git tag` by
  hand.
- **Release notes are the changelog, except for v1.0.0.** A version can override the
  generated sections by committing `docs/release-notes/vX.Y.Z.md`, which is then used
  verbatim; v1.0.0 does that because a first release has nothing to list changes against and
  describes the app's features instead. Later versions leave the file out and get the
  changelog.
- End commit messages with this line:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## Document map

| File | Contents |
|---|---|
| `docs/PLAN.md` | The implementation plan broken into phases, acceptance tests, open questions |
| `docs/ARCHITECTURE.md` | Process model, Swift layers, data flow |
| `docs/PROTOCOL.md` | The worker ↔ app NDJSON protocol (a versioned contract) |
| `docs/PYTHON_RUNTIME.md` | Setting up the isolated environment with uv, ffmpeg, the model directory |
| `docs/WHISPER_OPTIONS.md` | The mapping between UI controls and whisper parameters |
| `docs/UI_SPEC.md` | Screen layout, states, empty and error screens |
| `docs/LIVE_TRANSCRIPTION.md` | The live recording design — measurements, the streaming algorithm, the two passes |
| `docs/BUILD_AND_RELEASE.md` | Signing, notarization, dmg, GitHub release |
| `docs/DECISIONS.md` | The ADR record — decisions and their rationale |

When you make a decision (a library choice, a protocol change, a packaging method), add a
new ADR to `docs/DECISIONS.md`. If a document and the code disagree, **the code is right**;
fix the document in the same commit.
