# Worker protocol (v1)

The contract between the Swift app and `whisper_worker.py`. **This file is
normative:** every commit that changes the protocol must update it too.

## Transport

| Channel | Use |
|---|---|
| `stdin` | A single line of JSON, the job definition. stdin is **closed** once it is written. |
| `stdout` | The NDJSON event stream — one JSON object per line, terminated by `\n`. |
| `stderr` | Free-form text. Diagnostics only; the app keeps the last 200 lines in a ring buffer. |
| exit code | `0` success, `1` a handled error (an `error` event precedes it), anything else = crash |

### Protecting stdout

torch, numba and whisper all write to `sys.stdout`, and those lines corrupt the
protocol. **At startup** the worker duplicates the real fd 1 and keeps it as the
protocol channel:

```python
_proto_fd = os.dup(1)
_proto = os.fdopen(_proto_fd, "w", buffering=1, encoding="utf-8")
sys.stdout = _LogShim(level="info")   # turns every line into a {"type":"log"} event
sys.stderr = _LogShim(level="warning")
```

Plain `print()` is **forbidden** on the Python side; every event goes through
`emit(obj)`, which writes to `_proto` and flushes immediately.

## Invocation modes

```bash
# 1) Capability discovery — fast, loads no model, uses no network
python3 whisper_worker.py capabilities

# 2) Transcription — the job definition arrives on stdin
python3 whisper_worker.py transcribe

# 3) Live mode — see below, protocol v2
python3 whisper_worker.py stream

# 4) Fetch one model and exit — the request arrives on stdin
python3 whisper_worker.py download
```

### `download` mode

Transcribing already fetches a missing model on the way, so this mode exists only so the
interface can fetch one **without** tying a 1.5 GB download to a job the user wanted
finished now (ADR-019). The request is small — the rest of the job definition does not
apply:

```json
{"v": 1, "model": "medium", "model_dir": "/Users/you/.cache/whisper"}
```

It emits **no event type of its own**: a `hello`, then the same
`status{phase:"downloading_model"}` and `progress` events a transcription sends, and a
`log` when the file is ready. Success is a clean exit, failure is an `error` event. Because
nothing here is new, an older app has nothing to fail to understand and `v` is unchanged.

Two things it deliberately does not do. It does **not** treat an existing file as "already
downloaded" — an interrupted download leaves a truncated `.pt`, and whisper's own SHA256
check is what decides whether to fetch again. And the progress events are **throttled to one
per whole percent**: whisper reads in 8 KB chunks, which unthrottled is about 9 000 events
for `tiny` and roughly 375 000 for `large-v3`. A download with no `Content-Length` falls
back to one event per megabyte.

## Live mode (`stream`) — protocol v2

A long-lived process. The first line is the configuration, everything after it is
audio; committed and provisional text come back on stdout. **The whole channel
carries `v: 2`** — including `log` and `status`. The version is a property of the
channel, not of the event; seeing two versions in one stream breaks the decoder.

The batch job definition **remains valid as v1**; the worker supports both modes.

```bash
python3 whisper_worker.py stream
```

**app → worker** (one event per line):

```json
{"v":2,"job_id":"live","model":"small","model_dir":"…","language":"tr","task":"transcribe","device":"cpu"}
{"v":2,"type":"audio","seq":41,"pcm":"<base64 int16le, 16 kHz mono>"}
{"v":2,"type":"stop"}
```

The audio is in **exactly** the same representation as the file path produces:
16 kHz mono int16 (`decode_audio` takes `s16le` from ffmpeg and divides by 32768).
That is 32 KB/s of bandwidth, ~43 KB/s once base64-encoded. It travels over the same
NDJSON channel rather than a separate fd, because Foundation's `Process` only hands
us fds 0, 1 and 2.

Malformed lines and base64 that won't decode are **skipped silently** (forward
compatibility); audio that arrives after `stop` is not read.

**worker → app:**

```json
{"v":2,"type":"hello","worker":"0.1.0","mode":"stream","whisper":"20250625","device":"cpu"}
{"v":2,"type":"status","phase":"ready"}
{"v":2,"type":"partial","text":"Üç ayrı başlık üzerinde konuştuk, personel"}
{"v":2,"type":"committed","text":"Merhaba, bu bir test kaydıdır.","start":0.0,"end":2.3}
{"v":2,"type":"result","job_id":"live","duration":24.4,"segment_count":6,"text_chars":322,"text":"…"}
```

| Event | Meaning |
|---|---|
| `committed` | Will never change again. Timestamps are absolute from the start of the recording. |
| `partial` | **Everything not yet committed** — not just the last segment. May change entirely on every tick. |

It is mandatory that `partial` carries every uncommitted segment: sending only the
last one made the segments in the middle never appear on screen at all.

## Job definition (app → worker)

```json
{
  "v": 1,
  "job_id": "F0E1D2C3-...",
  "input_path": "/Users/tallhigh/Desktop/whisper/mehmet.m4a",
  "output_dir": "/Users/tallhigh/Desktop/whisper",
  "output_formats": ["txt"],
  "model": "small",
  "model_dir": "/Users/tallhigh/.cache/whisper",
  "language": "tr",
  "task": "transcribe",
  "device": "cpu",
  "options": {
    "temperature": [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
    "beam_size": null,
    "best_of": 5,
    "initial_prompt": null,
    "condition_on_previous_text": true,
    "word_timestamps": false,
    "fp16": false,
    "no_speech_threshold": 0.6,
    "compression_ratio_threshold": 2.4,
    "logprob_threshold": -1.0,
    "hallucination_silence_threshold": null,
    "threads": 0
  },
  "writer_options": {
    "highlight_words": false,
    "max_line_width": null,
    "max_line_count": null,
    "max_words_per_line": null
  },
  "overwrite": false,
  "emit_segments": true
}
```

Rules:
- `language` is sent as an **ISO code** (`"tr"`), not as a human-readable name
  (`"Turkish"`). `null` means automatic detection.
- `output_formats` is always an array. The equivalent of the CLI's
  `--output_format all` is sent out explicitly as `["txt","vtt","srt","tsv","json"]`
  — the worker does not accept `"all"`.
- `notes` is the one format with no counterpart in whisper: a timestamped bullet
  list, written to disk with an **`.md`** extension (the only place where the format
  name and the extension diverge). Its writer lives in the worker; the rationale is
  in `docs/DECISIONS.md` → ADR-014.
- Most of the option keys are **never sent at all** by the v1 interface; for every
  key that isn't sent, the worker applies the command-line default (ADR-015). The
  protocol still carries them. Exactly two are sent: `fp16`, to stop whisper warning
  on the CPU, and `threads`.
- `options.threads` is a **resource limit, not a decoding parameter**. The worker
  passes it to `torch.set_num_threads()` and to ffmpeg's `-threads`. Absent or `0`
  means "leave the defaults alone"; any other value caps both. It changes how long a
  run takes and never what it produces, which was measured rather than assumed
  (ADR-018) — so unlike a decoding key, sending it does not threaten CLI equivalence.
  The child process's scheduling priority goes with it, but that is set by the app
  when it spawns the worker and is deliberately **not** part of this protocol.
- A `null` value means "use whisper's default"; the worker does **not** pass those
  through to the `transcribe()` call.
- Unknown keys are ignored silently on the worker side (forward compatibility).

## Events (worker → app)

`v` and `type` are mandatory on every event. The unit of time is **seconds** (float).

### `hello` — the first event, always
```json
{"v":1,"type":"hello","worker":"0.1.0","python":"3.13.3","whisper":"20250625",
 "torch":"2.14.1","ffmpeg":"8.1.2","device":"cpu","mps_available":true}
```

### `capabilities` — only in `capabilities` mode
```json
{"v":1,"type":"capabilities",
 "models":["tiny","tiny.en","base","base.en","small","small.en","medium","medium.en",
           "large-v1","large-v2","large-v3","large","large-v3-turbo","turbo"],
 "models_cached":["small","large-v3","large-v3-turbo"],
 "models_bytes":{"small":483617219,"large-v3":3095033483,"large-v3-turbo":1623555571},
 "languages":[{"code":"tr","name":"turkish"},{"code":"en","name":"english"}],
 "model_dir":"/Users/tallhigh/.cache/whisper",
 "output_formats":["txt","vtt","srt","tsv","json","notes"],
 "tasks":["transcribe","translate"],
 "devices":["cpu","mps"]}
```
Measured values (openai-whisper 20250625): **14 models, 100 languages**.
The `models` and `languages` lists are derived **at runtime** from the
`whisper._MODELS` and `whisper.tokenizer.LANGUAGES` dictionaries — never hand-written.
`models_cached` = those with a `.pt` file present inside `model_dir` (so the UI can
warn "this will be downloaded").
`models_bytes` only gives the on-disk size of models that **have** been downloaded;
the size of one that hasn't is unknown (whisper doesn't report it before
downloading), and next to that model the UI shows only ⬇︎ instead of a size. The
field is backward compatible: older workers don't send it and the Swift side treats
its absence as normal.

### `status` — phase transitions
```json
{"v":1,"type":"status","phase":"resolving_model"}
{"v":1,"type":"status","phase":"downloading_model","model":"small","bytes":483617219}
{"v":1,"type":"status","phase":"loading_model","model":"small"}
{"v":1,"type":"status","phase":"decoding_audio"}
{"v":1,"type":"status","phase":"audio_ready","duration":612.4}
{"v":1,"type":"status","phase":"detecting_language"}
{"v":1,"type":"status","phase":"transcribing"}
{"v":1,"type":"status","phase":"writing_output"}
```

### `progress`
```json
{"v":1,"type":"progress","phase":"transcribing","processed":182.0,"total":612.4,"pct":29.7}
```
`phase` is either `transcribing` (measured in seconds) or `downloading_model`
(measured in bytes).

The source is the `tqdm` bar inside whisper's `transcribe()`. There are two separate
monkeypatch targets and they are of **different kinds**:

| Target | What it is | What it's for |
|---|---|---|
| `sys.modules["whisper.transcribe"].tqdm` | the tqdm **module** | transcription progress |
| `whisper.tqdm` | the tqdm **class** (`from tqdm import tqdm`) | model-download progress |

> The name `whisper.transcribe` is shadowed by the function of the same name, so the
> module is reached through `sys.modules` — `whisper.transcribe.tqdm` does not work.

whisper constructs the bar with `disable=verbose is not False`, and because the
worker uses `verbose=True` the bar ends up disabled, which makes tqdm's own
`update()` body return early. That is why the counter is kept **by us** in the
subclass; `self.n` cannot be trusted.

`total` is converted from frames to seconds (`HOP_LENGTH=160`, `SAMPLE_RATE=16000`
→ 100 frames = 1 second).

**Granularity (measured):** whisper calls `pbar.update()` once per 30-second window.
A 3-minute recording produces 8 `progress` events (steps of ~12.5%). A 24-second
recording produces a single event, and it goes straight to 100%. The UI has to be
designed knowing this — no intermediate values are synthesised.

### `segment` — when `emit_segments: true`
```json
{"v":1,"type":"segment","id":7,"start":32.5,"end":36.1,"text":" This is a sample sentence."}
```
For the live text preview in the UI. The file written to disk is **not produced from
these events**; writing belongs to whisper's own writer.

`text` preserves whisper's own leading space; the separator space from the format
line is consumed. Segments arrive in `id` order with increasing `start`.

The source: with `verbose=True`, whisper prints every segment via
`print(make_safe(f"[{start} --> {end}] {text}"))`. The worker wraps `make_safe`: it
captures the line, emits it as an event, and returns an empty string to suppress the
print noise. Fields such as `avg_logprob` and `no_speech_prob` are **not** available
on this path — they exist only in the final result whisper returns, and are added to
the `result` event if needed.

### `log`
```json
{"v":1,"type":"log","level":"info","message":"Detected language: turkish"}
```
`level`: `debug | info | warning | error`.

### `result` — the last event on success
```json
{"v":1,"type":"result","job_id":"F0E1...","language":"tr","duration":612.4,
 "elapsed":188.3,"rtf":0.31,
 "outputs":[{"format":"txt","path":"/Users/.../mehmet.txt","bytes":4821}],
 "segment_count":142,"text_chars":4718}
```
`rtf` = the real-time factor (`elapsed / duration`), so the UI can show "2.1x speed".

### `error` — the last event on failure
```json
{"v":1,"type":"error","code":"AUDIO_DECODE_FAILED",
 "message":"The audio file could not be decoded.",
 "detail":"ffmpeg exited 1: Invalid data found when processing input",
 "recoverable":false}
```
The permitted values for `code` are in the `ARCHITECTURE.md` → "Error
classification" table. Their worker-side counterparts are the subclasses of
`whisper_worker.WorkerError`; when adding a new code, update both places together.
`message` is shown to the user, `detail` stays in the diagnostics panel verbatim.

## Cancellation

1. The app sends `SIGTERM` to the child process.
2. The worker catches `SIGTERM` and sets a flag; on the next `update()` call the
   `tqdm` hook raises `WorkerCancelled` → transcription ends cleanly.
3. The worker emits `{"type":"error","code":"CANCELLED"}` and exits with `1`.
4. If the app doesn't see the process exit within **10 seconds**, it sends `SIGKILL`.
5. **No half-written output file is left behind:** outputs are first written to a
   temporary `.whisper-tmp-*` folder inside the destination directory, then moved
   into place one by one with `os.replace`; the temporary folder is cleaned up in all
   cases.

**Measured latency.** Cancellation is only noticed at 30-second window boundaries.
Measured with the `small` model on this machine: a clean exit **7 seconds** after
SIGTERM. It can take longer with larger models, which is why the SIGKILL deadline is
10 seconds.

**The UI does not wait for that latency.** The moment the user hits cancel the job is
shown as `cancelled`; the process is reaped in the background. SIGKILL carries no
risk of data loss — writing the output is atomic and happens at the very end of the
job, so an early death leaves no files behind.

## Versioning

- Every event and the job definition carry a `v` field.
- If the app sees a `v` in the `hello` event that is higher than it expects, it keeps
  running but surfaces the event types it doesn't recognise as `log` (forward
  compatible).
- If an incompatible break is needed, `v` is bumped and a separate decoder is added
  on the Swift side; the old decoder is not deleted (the user may still have an older
  runtime installed).
