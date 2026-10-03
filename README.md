# Whisper Transcriber

**Turn recordings into text on your Mac. Nothing leaves the machine.**

A native macOS app that runs OpenAI Whisper locally. Drop in an audio or video
file and get a transcript — or hit ⇧⌘R and watch the words appear while you speak.
No terminal, no API key, no account, no upload.

### [⬇ Download the latest release](https://github.com/tallhigh/whisper-mac-app/releases/latest)

Signed with an Apple Developer ID, notarized and stapled, so it opens without a
Gatekeeper warning. ~18 MB.

---

## What it does

### Transcribe files

Drag files onto the window, or press ⌘O. Queue as many as you like and they run
one after another, each with its own progress, elapsed time and a cancel button.
Text streams into the window as it is produced, so you can start reading before a
long file finishes.

Audio and video both work: `m4a`, `mp3`, `wav`, `aiff`, `flac`, `ogg`, `opus`,
`aac`, `caf`, `wma`, `mp4`, `mov`, `m4v`, `mkv`, `webm`, `avi`. Drop a folder and
the supported files inside it are picked up.

### Record and watch it transcribe live

Press ⇧⌘R and recording starts immediately. Text appears about two seconds behind
your voice — settled words stay put, the tail stays faint until it is final.

You choose the source:

| Source | What it captures |
|---|---|
| **Microphone** | Your voice |
| **System audio** | What the Mac is playing — pick which app |
| **Both** | A call, with both sides in one transcript |

When you finish, the recording is saved and goes through a full-quality pass, so
the live text is a preview and the file you keep is the accurate version.

### Six output formats

| Format | Use it for |
|---|---|
| `txt` | Plain text |
| `srt` · `vtt` | Subtitles |
| `json` · `tsv` | Timestamps and segment data for further processing |
| `notes` | A timestamped list, written as Markdown |

The `notes` format turns a recording into something you can skim:

```markdown
- [00:00] Today the main topic was the budget lines.
- [02:17] We went over three separate headings.
- [05:48] It was decided to review the software licences.
```

Each line carries the moment it was said, so you can jump straight back to it in
the recording.

### Set it up the way you work

- **Whisper models**, from `tiny` for speed to `large-v3` for accuracy, plus the
  `turbo` variants. Size and language are separate choices, so picking *English only*
  is a deliberate act rather than something you stumble into. Download a model when it
  suits you instead of waiting for a transcription to fetch it, see what each one takes
  on disk, and delete one you no longer want.
- **100 languages**, or let Whisper detect it. The translate task writes the
  transcript in English whatever the source language is.
- **Presets** — four are built in (Quick note, Meeting notes, High quality,
  Subtitles) and you can save your own combinations of model, language and format.
- **Where files land** — next to the source file or in a folder you choose, with
  overwrite protection so an existing transcript is never silently replaced.
- **While it works** — keep the Mac awake, get a notification when it is done,
  reveal the finished files in Finder.
- **Apple Silicon GPU or CPU**, your choice. If the GPU path fails on a file, the
  app retries on the CPU instead of giving up.
- **A CPU budget**, so a transcription doesn't take the machine over. By default it
  leaves a fast core free and runs at a lower priority — about 5% slower, and you can
  keep working. Pick *Background* and it stays on the efficiency cores.

On a Mac with 8 GB of memory, the model matters more than any setting: `small` needs
about 2 GB while `medium` needs about 4.4 GB, which is where a small Mac starts
swapping. The app warns you when the model you picked is heavy for your machine.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⇧⌘R | Start recording |
| ⌘O | Add files |
| ⌘R | Start the queue |
| ⌘. | Stop the running job |
| ⇧⌘K | Clear finished jobs |
| ⌘, | Settings |

---

## Private by design

Transcription happens in a process on your own Mac. There is no server, no
telemetry and no account — the app works with Wi-Fi off once it is set up.

It also stays out of the rest of your system. The app installs a Python
environment of its own under `~/Library/Application Support/WhisperTranscriber/`
and uses only that; your system Python, your Homebrew installation and your `PATH`
are never touched. If you already have Whisper models in `~/.cache/whisper`, it
uses them as they are and downloads nothing twice.

## Requirements

- An Apple Silicon Mac (M series)
- macOS 14.4 or later
- About 1 GB of downloads the first time you launch it — the Python environment
  (~850 MB, once) and whichever model you pick
- Nothing preinstalled: no Python, no ffmpeg, no Homebrew

## Getting started

1. **Download** the `.dmg` from the
   [releases page](https://github.com/tallhigh/whisper-mac-app/releases/latest),
   open it and drag the app into **Applications**.
2. **Launch it** and press **Start Setup**. The Python environment installs in
   about a minute. This happens once.
3. **Drop a file** onto the window and press **Start** — or press ⇧⌘R and talk.

The first time you record, macOS asks for microphone permission. Recording system
audio needs no extra permission.

---

## Building it yourself

```bash
make doctor       # check the environment
make bootstrap    # fetch the embedded uv binary
make run          # build and launch
make test         # Swift tests + pytest
make lint         # swift-format + ruff
```

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`); the Xcode project is generated from `app/project.yml`
rather than committed.

The design documents live in [`docs/`](docs/) —
[architecture](docs/ARCHITECTURE.md),
the [app ↔ worker protocol](docs/PROTOCOL.md),
the [Python runtime](docs/PYTHON_RUNTIME.md),
[live transcription](docs/LIVE_TRANSCRIPTION.md),
[build and release](docs/BUILD_AND_RELEASE.md),
and the [decision record](docs/DECISIONS.md).

## Licence

MIT. [OpenAI Whisper](https://github.com/openai/whisper) is MIT licensed and
[ffmpeg](https://ffmpeg.org) is LGPL/GPL licensed; neither is bundled into the app,
both are fetched during setup.
