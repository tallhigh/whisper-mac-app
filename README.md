# Whisper Transcriber

**A note taker with no bot, no cloud and no invented summaries.**

Every meeting note taker now wants to join your call, upload the recording to a
server and hand you a summary of things nobody said. This one doesn't. It is a
native Mac app that records and transcribes on the machine in front of you, and
gives you back what was actually said — word for word.

No bot in the meeting. No account. No API key. No upload. Works with Wi-Fi off.

### [⬇ Download for Mac](https://github.com/tallhigh/whisper-mac-app/releases/latest)

Apple Developer ID-signed and notarized, so it opens without a Gatekeeper warning.
~19 MB, and it keeps itself up to date from then on.

---

## Is this a "non-AI" note taker?

Worth answering properly, because it depends on what you mean.

**If you mean no bot, no cloud and no made-up summaries — yes, that is exactly what
this is.**

- **Nothing joins your meeting.** There is no participant called "Notetaker" in the
  call, nothing to admit, and nobody else in the room learns a recording is being
  taken by a third party. You press ⇧⌘R.
- **Nothing is uploaded.** No server, no account, no API key, no telemetry. Once it
  is set up, it works offline — turn Wi-Fi off and it behaves identically.
- **Nothing is summarised, rephrased or invented.** You get a transcript, not an
  interpretation. No "action items" that nobody agreed to, no confident summary of a
  conversation it misheard. If you want a summary, you write it, from a record you
  can trust.
- **Nothing is trained on your data**, because your data never leaves the Mac.

**If you mean no machine learning anywhere — then no, and here is the honest
detail.** Turning speech into text uses a neural network: OpenAI's
[Whisper](https://github.com/openai/whisper), which runs entirely on your own Mac
from a model file on your own disk. Nobody has built a speech recogniser worth using
without one.

The distinction that matters is not whether a model is involved. It is whether your
conversations leave the room, and whether software writes words you never said. On
both of those, this app is on the side you were looking for.

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

### Take notes in a meeting, without joining it

Press ⇧⌘R and recording starts immediately. Text appears about two seconds behind
your voice — settled words stay put, the tail stays faint until it is final. Nothing
is admitted to the call and nobody sees a bot arrive, because there isn't one: the
Mac records what it is already playing and hearing.

You choose the source:

| Source | What it captures |
|---|---|
| **Microphone** | Your voice |
| **System audio** | What the Mac is playing — pick which app |
| **Both** | A call, with both sides in one transcript |

When you finish, the sheet closes at once and the recording is saved, then goes
through a full-quality pass — so the live text is a preview and the file you keep is
the accurate version.

Past recordings stay in reach: **⇧⌘L** lists everything you have recorded, newest
first, with the transcripts found for each. From there you can transcribe one again,
open its text, or move the audio to the Trash — the transcripts stay.

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
- **Updates itself.** The app checks for a new version in the background and installs it
  on your say-so. Every update has to carry both Apple's notarization and the project's
  own signature before it will be accepted, so there is no "download it again by hand".
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
| ⇧⌘L | Past recordings |
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

## How it differs from an AI note taker

|  | A cloud AI note taker | Whisper Transcriber |
|---|---|---|
| Joins your meeting | Yes, as a participant | No — nothing to admit |
| Where the audio goes | Uploaded to a server | Stays on your Mac |
| Account required | Yes | No |
| Works offline | No | Yes, once set up |
| What you get back | A summary, and sometimes a transcript | The transcript, verbatim |
| Invents things | Sometimes, confidently | It writes down what it heard, nothing more |
| Per-month cost | Usually | None |
| Your data trains a model | Read the terms carefully | It never leaves the machine |

The trade is real and worth stating: nothing here writes your summary for you. What
you get is an accurate record, timestamped, that you can read and act on yourself.

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
