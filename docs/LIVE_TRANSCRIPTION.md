# Live recording and real-time transcription — design

**Status:** implemented. Phases 7.1–7.4 shipped in v0.3.0. The decisions are recorded
as ADRs in `docs/DECISIONS.md`; the phase breakdown is in `docs/PLAN.md` → Phase 7.
This document remains the design reference: the measurements below are what the
constants in the code are derived from.

The goal: start recording from inside the app, watch the text appear while speaking,
and on finishing get both the audio file and the usual outputs (`txt`, `notes`, …).

## The user flow

```
[● Record]  →  ┌ Audio recording ──────────────────────────┐
               │  Name    [ Meeting                     ]  │
               │  Source  ( • Microphone + system audio  ) │
               │  App     [ Zoom                      ▾ ]  │
               │  ☑ Show the text live while speaking      │
               │  Live model   [ small · 462 MB       ▾ ]  │
               │  Folder  ~/Desktop/recordings  [Change…]  │
               ├───────────────────────────────────────────┤
               │  ●  00:42          ▁▃▆█▆▃▁ (level)        │
               │                                           │
               │  Bugünkü toplantının ana konusu bütçe     │  ← committed
               │  kalemleriydi. Üç ayrı başlık üzerinde    │
               │  konuştuk, personel giderleri             │  ← provisional (faded)
               │                                           │
               │           [Pause]    [Finish]             │
               └───────────────────────────────────────────┘
                              ↓ Finish
   Meeting.m4a                       (audio, written to disk as it streamed)
   Meeting (live).txt / .md          (the live text — instantly, from memory)
                              ↓ second pass (on by default)
   Meeting.txt / .md                 (the accurate, CLI-equivalent text)
```

## Feasibility — measured values

Apple Silicon, macOS 27, the `small` model, CPU. Model in memory, wall-clock time per
window (measured 2026-10-02):

| Window | CLI equivalence (`beam_size=5`) | Greedy (`beam_size=None`) |
|---|---|---|
| 5 s | 1.74 s (0.35×) | **0.70 s** (0.14×) |
| 10 s | 2.80 s (0.28×) | **1.01 s** (0.10×) |
| 20 s | 6.45 s (0.32×) | **1.65 s** (0.08×) |
| 30 s | 6.79 s (0.23×) | **1.89 s** (0.06×) |

Model loading: ~1.0–1.2 s (warm cache).

**Conclusion: feasible.** Re-decoding a 30-second buffer greedily takes 1.9 s, which
fits comfortably inside a tick interval of a few seconds. The same work with beam search
takes 6.8 s — **the live preview cannot use beam search.** That is the measured
rationale for the two-pass design below.

The measurement script was a one-off in that session; to reproduce the numbers, timing a
`whisper.transcribe` call with the model already in memory is all it takes.

## Three empirical findings

These determined the design directly and shouldn't be skipped when reading the plan.

### 1. Hallucination during silence is real and severe

Giving the `small` model 10 seconds of **digital silence**:

```
" Bu dizinin betimlemesi, Fikret Yeni'nin, Fikret Yeni'nin, Fikret Yeni'nin, …"
```

Text was produced even though `no_speech_prob` was **0.841** — with the default
`no_speech_threshold` at 0.6. The reason is that whisper's silence suppression requires
both `no_speech_prob > threshold` **and** `avg_logprob < logprob_threshold`; when the
second isn't met, the segment passes through.

**Implication:** whisper's own thresholds can't be trusted. An energy gate is
**mandatory**, and we never pad the buffer with zeros — only genuinely captured samples
are sent.

### 2. Real room noise is not a problem

Repeating the same test with very faint noise (σ≈0.0015, like a quiet room) produced
**empty** output. So the pathological case is specifically "microphone off / buffer
filled with zeros"; ordinary silence filters itself out. That's why the energy gate's
threshold can be kept very low.

### 3. A window starting mid-sentence corrupts the first word

Cutting the audio from 3.5 s to 9.5 s and decoding that:

```
" şantının ana konusu Bütçe kalemleriydi. 3 ayrı başlık üzerinde konuştuk. Personel"
```

"toplantının" → "şantının". The word at the cut point is corrupted, the rest is sound.
**Implication:** windows can't be cut arbitrarily; committed text may only be taken from
windows that ended on a segment boundary.

## The core decision: the two-pass design

| | Pass 1 — live preview | Pass 2 — the accurate output |
|---|---|---|
| When | while recording, every ~1.5 s | after "Finish" |
| Input | the audio buffer in memory | the recording file on disk |
| Decoding | **greedy**, a single temperature | the user's settings (CLI equivalence) |
| Output | the screen, plus a `… (live)` file | the `txt` / `notes` / … files |
| Correctness claim | **none** — it's a "preview" | covered by `test_output_is_identical_to_the_cli` |

Why this matters: the project's core correctness claim (output = the `whisper` CLI's
output) is **unaffected** by live mode. The live text is a preview; what the accurate
pass writes is always the product of pass 2. When the recording finishes, the file enters
the existing queue as an ordinary job, so the queue, the settings, the overwrite check
and the output formats all keep working exactly as they do.

Two kinds of text are distinguished on screen: **committed** (normal) and **provisional**
(faded). The provisional part can change on every tick.

### Persistence of the live text

The live text is held **in memory only** for the duration of the recording; it isn't
written to disk per tick. It is written the instant "Finish" is pressed — where it is
written depends on whether the accurate pass is enabled:

| Accurate pass | Live text | Accurate text |
|---|---|---|
| on (default) | `Meeting (live).txt` / `.md` | `Meeting.txt` / `.md` |
| off | `Meeting.txt` / `.md` | — |

**An earlier design wrote both to the same file**, and because the second pass overwrote
it, the live text was lost. Two separate files both preserve the live text (making it
possible to compare, and to see the difference between greedy and beam) and remove the
need for an exception to the overwrite check: there is no colliding name any more, and
the accurate pass enters the queue with the user's own `overwrite` preference.

The live text only ever produces `txt` and `notes`: we have the segment text and a
timestamp, we don't have the fields `srt`/`vtt`/`json`/`tsv` need, and we don't imitate
whisper's formats. Any other selected formats are produced by the second pass.

**The second pass can be turned off** (it's on by default). An hour-long recording means
~18 minutes of CPU with `small`; if the user finds the live text good enough, they
shouldn't have to wait. With it off, the live text is the final output.

If the app crashes mid-recording the live text is lost — the recording itself isn't,
because the audio file is streamed to disk continuously and can be added to the queue by
hand. That's a deliberate trade: writing to disk per tick is both needless I/O and a
risk of half-written files.

## Audio sources

The user picks one of three:

| Source | What it captures | Technology |
|---|---|---|
| **Microphone** | only the person speaking | an `AVAudioEngine` input tap |
| **System audio** | only the other side (the Zoom/Meet speaker output) | a Core Audio **process tap** |
| **Microphone + system audio** | both sides of the call | both on a single aggregate device |

When system audio is selected, a second choice appears: **all system audio** or **a
specific app** (Zoom, Chrome, Safari…). Because Meet runs in a browser, the browser
process is the one to pick.

### Why a Core Audio process tap rather than ScreenCaptureKit

Both exist in the SDK (MacOSX26.4) and both can deliver system audio:

| | Core Audio process tap | ScreenCaptureKit |
|---|---|---|
| Availability | `AudioHardwareCreateProcessTap` — macOS **14.2+** | audio: 13.0+, `captureMicrophone`: 15.0+ |
| Permission | audio-recording permission | **screen-recording permission** |
| Mono mixdown | `initMonoMixdownOfProcesses:` — built in | mix by hand |
| Process selection | a PID list, directly | through `SCShareableContent` |
| Scope | audio only | drags the video stack along too |

**Decision: the Core Audio process tap.** The deciding factor is the permission: this is
an audio app, asking the user for screen-recording permission is disproportionate, and
since macOS 15 the system re-asks for that permission periodically, which is intrusive.
`CATapDescription`'s `initMonoMixdownOfProcesses:` and
`initMonoGlobalTapButExcludeProcesses:` initialisers give us exactly what we need:
**mono**, ready to be converted to 16 kHz, with our own audio excluded.

The price: reading samples from the tap requires setting up an **aggregate device** and
attaching an `IOProc` — lower-level work than `AVAudioEngine`.

When the microphone and system audio are both wanted, the two become sub-devices of **the
same aggregate device**. That leaves clock drift to Core Audio's own rate converter;
there's no need to align two separate streams by hand.

> `CATapDescription.bundleIDs` is macOS 26+ only, so process selection uses
> `AudioObjectID` instead, which works on the 14.4 target.

**The deployment target rises from 14.0 to 14.4.** 14.2 is where the API arrived, 14.4 is
where the audio-capture permission flow settled. For a single-user app that costs
nothing.

## Architecture

### Audio capture — on the Swift side

A tap is attached to the `AVAudioEngine` input node. The hardware format (usually 48 kHz
float32 stereo) is converted to **16 kHz mono int16** with `AVAudioConverter`.

That format is no coincidence: `whisper_worker.decode_audio` already takes
`s16le / mono / 16000` from ffmpeg and converts it to float32 by dividing by 32768.0. If
the live path uses the same representation, it produces data **bit-identical** to audio
coming from a file, and no unexplained difference remains between the two passes.

The same converted buffer goes to two places:
1. to disk via `AVAudioFile` (the recording file),
2. to the worker (the live preview).

### Transport — base64, over the existing stdin channel

Foundation's `Process` only gives us fds 0, 1 and 2; opening another fd requires
`posix_spawn` file actions and complicates `ProcessRunner`. Instead the audio flows as
base64 on the existing NDJSON channel:

```json
{"v":2,"type":"audio","seq":41,"pcm":"<base64 int16le>"}
```

Bandwidth: 16 kHz × 2 bytes = 32 KB/s → ~**43 KB/s** once base64-encoded. With 200 ms
chunks that's ~5 lines a second. Negligible for a pipe.

The price: `ProcessRunner` currently writes to stdin and closes it immediately ("the
worker waits for stdin to close"). Live mode needs a second path that keeps stdin open.

### The worker — a third mode

```bash
python3 whisper_worker.py stream     # a long-lived process, audio in on stdin, text out on stdout
```

The process lives for the duration of the recording. That makes the "keep the worker
alive" decision **deferred in ADR-008** mandatory for live mode; the batch queue side
doesn't change.

The event stream (the existing `hello` / `status` / `log` / `error` are preserved, with
two new ones):

```json
{"v":2,"type":"committed","text":"Bugünkü toplantının ana konusu bütçe kalemleriydi.","start":0.0,"end":4.2}
{"v":2,"type":"partial","text":"Üç ayrı başlık üzerinde konuştuk, personel"}
```

`partial` may change completely on every tick; `committed` is only ever appended to.

### The protocol version

The new mode and the two new events are **v2**. The batch job definition stays valid as
v1; the worker accepts both versions. `docs/PROTOCOL.md` is updated in the same commit
(CLAUDE.md, architecture rule 2). The version belongs to the channel, not the event: in
stream mode even `log` and `status` carry `v: 2`.

### The engine layer

The `TranscriptionEngine` protocol is left untouched. The live capability lives in a
**separate** protocol:

```swift
protocol LiveTranscriptionEngine: TranscriptionEngine {
    func startLiveSession(_ config: LiveConfig) async throws -> LiveSession
}
```

That way ADR-003 isn't broken: the `WhisperCppEngine` arriving in v2 doesn't have to
support live mode, and if it does, it conforms to this protocol.

## Choosing the model and the recording folder

**Model.** The live preview's model is chosen **separately** from the batch job's: speed
is what matters on the live side, accuracy on the batch side. In the list on the
recording screen, each model shows whether it has been downloaded and how big it is (the
same list as everywhere else, from `capabilities`).

The default is `small` — measured, and sufficient. Smaller models (`tiny`, `base`) give
lower latency but aren't in the cache and are noticeably weak for Turkish; they are
downloaded if the user selects one.

The model **cannot be changed while recording** (the worker would have to be restarted);
the list is disabled during a recording.

**Recording folder.** A preference under Settings → General (`recordingDirectory`),
defaulting to the existing output-folder setting. It also appears on the recording screen
and can be changed from there — starting a recording shouldn't mean going to Settings to
choose a folder.

The file name is the given name, or `Recording 2026-10-02 14-30.m4a` when left blank. If a
file of that name exists, a number is appended; a recording **never, under any
circumstances**, overwrites an existing file — the recording itself is unrecoverable
data.

## The streaming algorithm

On every tick (every 1.5 s) the worker re-decodes **all** the audio in the buffer
greedily, and then:

1. Every segment that ends at least 1 s before the end of the buffer is considered
   committed → sent as `committed`.
2. The audio up to the last committed segment's `end` is dropped from the buffer.
3. Everything still uncommitted is sent as `partial`.

Why the segment at the end is held back: finding 3 shows that the word at the cut point
gets corrupted. The last segment is still growing, so the cut point is inside it; on the
next tick it is re-decoded in full.

The 1 s stability margin (`_STREAM_STABLE_MARGIN_SECONDS`) exists because a plain
"everything but the last segment" rule held a segment back until the next one appeared,
which during a pause in speech could be a long time.

The tick interval was measured: at 3 s the worst commit latency came out at 8.1 s, so it
was lowered to 1.5 s. The loop is sequential and therefore self-braking — if decoding
takes longer than a tick, the next round simply starts with more audio.

`partial` carries **everything** uncommitted, not just the last segment. Sending only the
last one made the segments in the middle never appear on screen at all.

Limits:
- **A 30 s buffer ceiling** (whisper's natural window). Past it, the last segment is
  force-committed too; otherwise the cost leaves the table above.
- **Energy gate:** if the buffer's RMS is below `_STREAM_SILENCE_RMS` (1e-4) it is
  skipped without being decoded (finding 1). The gate lives in the worker, on the buffer
  it is about to decode. The audio is still **written** to the recording file — the
  recording must be complete.
- **Context:** the last ~200 characters of committed text are passed to the next call as
  `initial_prompt`. That reduces the loss of context at a window boundary.
- **Back-pressure:** the loop is sequential, so a tick never overlaps another. The buffer
  keeps growing and force-commits when it hits the ceiling.

If this algorithm ever proves insufficient, the known alternative is
**LocalAgreement-2**: committing the longest common prefix of two consecutive
hypotheses. More accurate, more complex; not attempted in v1.

## Permissions and signing

This feature **required the exception to ADR-007** (the empty entitlement list).

| Required | Why |
|---|---|
| `NSMicrophoneUsageDescription` (Info.plist) | the text of the microphone TCC dialog; without it the app crashes |
| `com.apple.security.device.audio-input` (entitlements) | with Hardened Runtime on, microphone access is refused without this entitlement |

The microphone side was settled by measurement: it was run without the entitlement, the
system refused without ever showing the dialog, and the app didn't appear in the Privacy
list; the evidence is in ADR-016.

**System audio needs no permission and no entitlement.** The same method was followed:
it was tried without one first. A capture with `source: both` recorded 51.9 s
successfully, so nothing was added. `SystemAudioCapture` writes every failed Core Audio
step to `logs/recording.log` as `CaptureError.tapFailed(step:status:)`, which is what
made that verifiable.

App Sandbox is still not added. The signing and notarization flow doesn't change, but the
entitlement change does require a new notarization round.

## Interface

- A **🎙 Record** button in the toolbar (⇧⌘R).
- A **name** field on the recording screen; left blank it becomes
  `Recording 2026-10-02 14-30`. The name is given **before** recording because the output
  files derive from it; renaming afterwards would touch three files at once. Because `/`
  and `:` can't appear in a file name they are turned into hyphens, leading dots are
  dropped (so it isn't a hidden file), and the name is truncated at 120 characters.
- A **live-transcription toggle** on the same screen. With it off, only audio is recorded
  and the text is produced afterwards. Turning live transcription off makes the accurate
  pass **mandatory** — with both off, the recording would never become text at all.
- The recording sheet shows the selections at the top (name, source, app, live toggle,
  live model, folder), and below them the duration, the level meter, the live text and
  `[Pause]` `[Finish]`.
- If the source is "system audio" or "microphone + system audio", the app list appears;
  "all system audio" is one of its options. The list is populated from the processes
  actually producing audio, never hard-coded.
- Once recording starts, the source, the app and the model are locked.
- The live text is shown in two styles: committed (primary) and provisional
  (secondary/faded).
- `[Finish]` → the recording file is closed, added to the queue, and the normal flow
  continues.
- Closing the window does **not** stop the recording (consistent with the queue's
  behaviour); quitting asks for confirmation.

Accessibility: the level meter reports a percentage through `accessibilityValue`, and the
duration and state are read to VoiceOver as a single element.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Hallucination during silence | **measured, high** | energy gate, no zero padding (finding 1) |
| A corrupted word at a window boundary | **measured, certain** | don't commit the trailing segment (finding 3) |
| Silent failure if microphone permission is refused | medium | `AVCaptureDevice.authorizationStatus` is checked first, and on refusal an explicit error points at System Settings |
| Memory on a long recording | low | the buffer is capped at 30 s; the file streams to disk |
| The live text differing from the second pass's output | **certain** | the UI calls it a "preview" explicitly; the accurate file always comes from the second pass |
| `small` not being fast enough | low (measured) | raise the tick interval; the model is selectable and `tiny`/`base` can be downloaded |
| Clock drift between the microphone and system audio | medium | both are sub-devices of a single aggregate device; Core Audio does the conversion |
| The aggregate-device setup being low-level work | medium | Phase 7.2 is independent; the microphone-only version is already working after 7.1 |
| The second pass replacing the live file being surprising | low | resolved: they are two separate files, and the second pass can be turned off |
| The worker dying mid-recording | low | the audio file is written on the Swift side, so the recording isn't lost; the preview stops and an error is shown |

## Phases

### Phase 7.1 — Microphone capture and recording (without touching the worker)
- `AVAudioEngine` + `AVAudioConverter` → 16 kHz mono int16
- The microphone permission flow; **try it without the entitlement first and observe the
  refusal**, then add `com.apple.security.device.audio-input` +
  `NSMicrophoneUsageDescription`
- Writing `.m4a` via `AVAudioFile`, the recording-folder preference, a non-colliding file
  name
- Recording state, level metering, pause/finish
- "Finish" → add the file to the existing queue

**Acceptance test.** The recording file is created, transcribed in the queue like an
ordinary job, and its output is **byte-for-byte identical** to feeding the same audio in
as a file. No live text yet.

### Phase 7.2 — System audio and source selection
- Core Audio process tap + aggregate device + `IOProc`
- Listing the processes producing audio, selecting an app, "all system audio"
- Microphone and system audio together: both on the same aggregate device
- Finding and documenting the audio-capture permission **by trying it**
- Deployment target 14.0 → 14.4

**Acceptance test.** A recording can be made from audio playing in Zoom or a browser;
with "microphone + system audio" selected, both sides are audible and stay in sync in the
recording file. The app's own audio doesn't leak into the recording.

### Phase 7.3 — The worker's `stream` mode
- `python3 whisper_worker.py stream`, `audio` events on stdin
- The segment-commit algorithm and the energy gate
- The `committed` / `partial` events, protocol v2
- Python tests: commit boundaries with synthetic PCM, the buffer ceiling, silence

**Acceptance test.** When audio read from a file is fed to the worker at real-time speed,
the committed text it produces **matches the meaning** of the same file's batch output
(not byte-for-byte — greedy vs beam).

### Phase 7.4 — The live interface and the two-pass flow
- The recording screen, two-tone text, model selection
- The `LiveTranscriptionEngine` protocol, the `ProcessRunner` path that keeps stdin open
- "Finish" → write the live text at once, queue the second pass
- The preference for turning the second pass off
- Back-pressure, error and cancellation paths

**Acceptance test.** Across a 5-minute conversation the text flows without a break, the
latency stays under 5 s, the files are created the instant "Finish" is pressed, and the
accurate text arrives when the second pass finishes.

## Decisions (2026-10-02, confirmed with the user)

1. **Both microphone and system audio**, with the user choosing. With system audio, the
   app can be chosen too (the browser, for Meet). → the Core Audio process tap.
2. **The model is selectable**, separately for the live side; the default is `small`.
3. **The recording folder belongs to the user**: a preference in Settings, changeable
   from the recording screen.
4. **The live text stays in memory** and is written to a file on "Finish".
5. **The live text gets its own file** (`… (live).txt`) when the accurate pass is on, so
   the second pass can't overwrite it.

### What remains open

- The live quality of the `tiny` / `base` models for Turkish hasn't been measured; if the
  user selects one it gets downloaded and measured then.
- LocalAgreement-2 stays deferred. It becomes worth implementing only if the measured
  commit latency of the segment-commit rule turns out to be inadequate in real use.
