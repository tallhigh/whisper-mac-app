# Architecture

## Overview

The app is made of two processes. The SwiftUI layer never loads Python or torch
code into its own address space; all the heavy work runs in a separate child
process.

```
┌──────────────────────────────────────────────────────────────┐
│  WhisperTranscriber.app          (Swift 6 / SwiftUI, signed) │
│                                                              │
│  Views ──► AppState ──► JobQueue ──► TranscriptionEngine     │
│   (UI)     (@MainActor)  (actor)      (protocol)             │
│                                           │                  │
│                               PythonWhisperEngine (actor)    │
│                                           │ Process + pipe   │
└───────────────────────────────────────────┼──────────────────┘
                                            │ stdin: job JSON
                                            │ stdout: NDJSON events
                                            ▼
┌──────────────────────────────────────────────────────────────┐
│  python3 whisper_worker.py                                   │
│  ~/Library/Application Support/WhisperTranscriber/runtime/   │
│     venv/bin/python3  →  openai-whisper + torch + ffmpeg     │
└──────────────────────────────────────────────────────────────┘
```

## Why two processes

- torch pulls in hundreds of dylibs, roughly 1 GB of them; embedding those in the
  `.app` would mean signing each one and uploading 3 GB for notarization on every
  release (see ADR-001).
- Even if the Python process dies (OOM, corrupt model, numba JIT failure) the app
  stays up; the queue marks that file as failed and carries on.
- Cancellation becomes as simple as killing a process — in-process cancellation is
  not reliable inside torch.
- Swapping the engine (whisper.cpp) doesn't touch the UI; a different child process
  is launched, and that's all.

## Swift layers

### `Core/TranscriptionEngine.swift`
```swift
protocol TranscriptionEngine: Sendable {
    var id: EngineID { get }                      // .pythonWhisper | .whisperCpp
    func capabilities() async throws -> EngineCapabilities
    func transcribe(
        _ job: TranscriptionJob,
        onEvent: @Sendable (EngineEvent) -> Void
    ) async throws -> TranscriptionResult
}
```
`EngineCapabilities` is read from the worker **at runtime** (supported languages,
models, output formats, version information). The UI hard-codes none of these
lists, so when the whisper version is updated, new languages and models show up by
themselves.

### `Core/RuntimeProvisioner.swift` (actor)
Sets up the isolated Python environment on first launch and health-checks it on
every launch after that. Its states:
`.notInstalled → .installing(step, pct) → .ready(RuntimeInfo) → .broken(reason)`.
Details: `PYTHON_RUNTIME.md`.

### `Core/JobQueue.swift` (@MainActor @Observable)
Processes files **sequentially**, not in parallel — a single model already saturates
RAM and CPU. Job states:

```
queued → preparing → transcribing(pct) → writing → completed
                            │
                            ├─► cancelled   (user cancellation, SIGTERM)
                            └─► failed(TranscriptionError)
```
The queue keeps `completed` and `failed` jobs in the list; there is a "clear
completed" action.

### `Core/ProcessRunner.swift`
The only way to run a child process. Three rules:
1. Environment variables are passed explicitly; the user's shell profile is not
   inherited.
2. stdout and stderr are read **concurrently** — waiting on one side deadlocks once
   the pipe fills up.
3. Process exit is awaited **without blocking**, via `waitForExit(_:)`.
   `Process.waitUntilExit()` blocks the calling thread; under Swift concurrency that
   holds a thread from the cooperative pool, and with a few processes running at
   once the pool is exhausted and the reader tasks never get scheduled.
   During Phase 3 this really did deadlock the tests while they ran in parallel.

### `Core/WorkerEventStream.swift`
Reads the child process's stdout line by line and decodes each line into the
`EngineEvent` enum. A malformed or unrecognised line is **not an error**: it is
surfaced as `.log(level: .warning)` — forward compatibility, so a newer protocol
version doesn't break an older decoder.

### `Models/WhisperSettings.swift`
All of the user's settings. A single pure function turns them into a worker job
definition: `func jobPayload(for url: URL) -> TranscriptionJob`. That function is
the main target of the unit tests — independent of the UI and deterministic.

### Views
Covered in `UI_SPEC.md`. Views only read `AppState`; they hold no business logic.

## Data flow (the life of one file)

1. The user drops a file on the window → `AppState.enqueue(urls:)`
2. `JobQueue` picks up the next job and builds a `TranscriptionJob` from `WhisperSettings`
3. `PythonWhisperEngine` starts the child process, writes the job definition to
   stdin, then closes stdin
4. The worker emits its event stream: `hello → status → progress* → segment* → result`
5. Every event reaches the UI through `AppState` (progress bar, live log, live text)
6. The file paths in the `result` event are attached to the job → "Reveal in Finder"
   and "Copy" become available
7. If the process exits with a non-zero code, or an `error` event arrives, the job
   becomes `failed`

## Error classification

The worker-side counterparts are the subclasses of `whisper_worker.WorkerError`.
When a new code is added, this table, `PROTOCOL.md` and the worker are updated
together.

| Code | Meaning | UI behaviour |
|---|---|---|
| `BAD_USAGE` | the worker was invoked with the wrong mode | Error — this is a programming mistake, never shown raw to the user |
| `BAD_JOB` | the job definition is invalid (missing file, unknown model/format/task) | Skip the file, state why |
| `RUNTIME_NOT_READY` | the venv is missing or broken | Send the user to the setup screen |
| `MODEL_DOWNLOAD_FAILED` | the model couldn't be downloaded | Retry + network hint (`recoverable: true`) |
| `MODEL_LOAD_FAILED` | the model file exists but wouldn't load | Offer to download the model again |
| `AUDIO_DECODE_FAILED` | ffmpeg couldn't open the file, or the file is empty | Skip the file, show ffmpeg's real error in the detail |
| `OUTPUT_EXISTS` | the output file exists and `overwrite` is off | Ask for overwrite confirmation, retry if confirmed |
| `OUT_OF_MEMORY` | large model + not enough RAM | Suggest a smaller model |
| `CANCELLED` | user cancellation | Silent, show no error |
| `INTERNAL_ERROR` | an unexpected exception in the worker | Show the traceback from the error detail in the diagnostics panel |
| `WORKER_CRASHED` | the process died without emitting an event (produced app-side) | Put the last 50 log lines in the error detail |

## Concurrency rules

- `AppState`, `JobQueue` and `TranscriptionItem` are `@MainActor @Observable`.
  They hold the state the views read directly; making them actors would mean
  copying every read onto the main actor, and all they do is coordination.
- `RuntimeProvisioner` and `PythonWhisperEngine` are each an `actor`; the heavy work
  and the child-process management live there, and that work already runs in a
  separate OS process.
- Child-process reads go through `AsyncStream<String>`; prefer `bytes.lines` over
  `FileHandle.readabilityHandler` (cleaner back-pressure and cancellation).
- Cancellation: SIGTERM → 10 s → SIGKILL. The UI shows the cancellation at once and
  reaps the process in the background (the worker only notices cancellation at a
  30-second window boundary; measured latency with the `small` model is 7 s).
  SIGKILL is safe — writing the output is atomic and happens at the very end of the
  job.
- The event rate into the UI is **not** throttled, and doesn't need to be: measured,
  whisper emits `progress` once per 30-second window and `segment` once per segment,
  seconds apart. A throttling machine would be complexity with nothing to show for
  it. `log` events can arrive more often, so they go into a 500-line ring buffer per
  job.

## What changes in v2 (whisper.cpp)

`WhisperCppEngine` will run a `whisper-cli` binary embedded in the `.app` and turn
its output into the same `EngineEvent` stream. What has to change:
- Model files are different (GGML `.bin`, not `.pt`) → separate model management and downloading
- The settings surface is narrower → unsupported controls are greyed out in the UI via `EngineCapabilities`
- Writing the output is either left to whisper.cpp or produced from the segments by our own writer

The UI, queue and settings-persistence layers **do not change**. Don't take a
shortcut that breaks that separation.
