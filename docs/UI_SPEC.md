# Interface design

A single-window macOS app with three panes. Extra windows: Settings (the standard
`Settings` scene) and the setup screen shown on first launch.

The minimum window size is 900×600, the default 1100×720. The window size and the
pane widths are remembered via `@SceneStorage`.

## Main window

```
┌─ Whisper Transcriber ───────────────────────────────────── ⚙︎ ─┐
│ [+ Add Files]  [▶ Start] [⏹ Stop]    Quick note ▾     ⬤ Ready  │
├───────────────────────────┬────────────────────────────────────┤
│  QUEUE                    │  SETTINGS                          │
│                           │                                    │
│  ✓ interview.m4a          │  Quick note  Meeting notes  Subt.. │
│    txt · 4.8 KB · 2.1x    │  Model      [ small · 462 MB  ▾ ]  │
│                           │  Language   [ Turkish         ▾ ]  │
│  ⟳ mehmet.m4a       29%   │  Task       ( Transcribe | Trans ) │
│    ▓▓▓▓▓░░░░░░░░░░        │  Format     [✓txt ☐srt ☐vtt     ]  │
│    03:02 / 10:12          │             [☐json ☐tsv ☐notes  ]  │
│                           │  Output     ( • Beside the source) │
│  ○ meeting.mp3            │             ( ○ Choose a folder… ) │
│    queued                 │                                    │
│                           ├────────────────────────────────────┤
│  ✕ broken.wav             │  TEXT  |  LOG                      │
│    could not be decoded   │                                    │
│                           │  …the main subject of today's      │
│  [Clear completed]        │  meeting was the budget. ▌         │
│                           │  [Copy] [Reveal in Finder]         │
└───────────────────────────┴────────────────────────────────────┘
```

### Top toolbar
- **Add Files** — `NSOpenPanel`, multiple selection, permitted types are
  `UTType.audio` plus video (ffmpeg can extract the audio from a video file;
  m4a/mp3/wav/flac/ogg/opus/mp4/mov are accepted)
- **Start / Stop** — works the queue; while it runs, Stop replaces Start
- **Preset dropdown** — the saved setting bundles plus "save the current settings…"
- **Status indicator** — `⬤ Ready` / `⬤ Installing 62%` / `⬤ Runtime broken`
  (clickable)

### Drag and drop
The entire window is a drop target. While something is being dragged, a dashed border
and the text "Drop audio files" appear over the queue pane. If a folder is
dropped, the supported files inside it are collected (one level deep). Unsupported
extensions are not discarded silently — the UI reports "3 files are not supported".

### Queue pane
Per row: a status icon, the file name, and information below it that depends on the
state.

| State | Icon | Second line |
|---|---|---|
| `queued` | ○ | "queued" plus a time estimate, if one is known |
| `preparing` | ⟳ | "loading the model" / "decoding the audio" |
| `transcribing` | ⟳ + percentage | progress bar + `elapsed / total` time |
| `writing` | ⟳ | "writing the file" |
| `completed` | ✓ | formats · size · speed factor (`2.1x`) |
| `failed` | ✕ (red) | a short error; clicking it opens the detail |
| `cancelled` | ⊘ | "cancelled" |

Row actions (right-click / hover): reveal in Finder, copy the text, retry, remove from
the queue. Reordering by dragging is supported (for `queued` jobs only).

### Settings pane
The preset buttons sit at the top, and five controls below them: **model, language,
task, format, output**. There is **no** collapsible "Advanced" section — the decoding
parameters are not in the interface at all (ADR-015). Device selection lives in the
Settings window.

The format checkboxes are two rows of three: `txt srt vtt` / `json tsv notes`. Six
checkboxes don't fit on one line and overflowed in a narrow window.

Changing a setting **does not affect the running job**; it takes effect from the next
one onwards — stated in small type at the bottom of the pane.

If a model that hasn't been downloaded is selected, a warning appears beneath the
control: "`large-v2` will be downloaded. The first run may be slow."

### Bottom pane: the TEXT / LOG tabs
- **TEXT** — accumulates live from incoming `segment` events, with the cursor pinned
  to the bottom (auto-scroll stops if the user scrolls up). The full text once the job
  completes. Plain text, not editable, selectable. `[Copy]` and `[Reveal in Finder]`.
- **LOG** — the `log` events plus the worker's stderr, timestamped, monospaced.
  Coloured by line level. A `[Copy]` button, for reporting problems.

## Recording sheet

**🎙 Record** in the toolbar (⇧⌘R) opens a sheet. Recording starts the moment the
sheet opens — a separate "start" button would be asking a second time for a decision
the user has already made.

```
┌ Audio recording ────────────────────────┐
│  When recording stops, the file joins…  │
├─────────────────────────────────────────┤
│  Name    [ 2026-10-02 14-22           ] │
│  Source  ( • Microphone               ) │
│          ( ○ System audio             ) │
│          ( ○ Microphone + system audio) │
│  ☑ Show the text live while speaking    │
│  Live model   [ small           ▾ ]     │
├─────────────────────────────────────────┤
│         ●  00:42                        │
│   ▊▊▊▊▊▊▊▊▊▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁              │
├─────────────────────────────────────────┤
│  Merhaba, bu bir test kaydıdır. Bugünkü │
│  toplantının ana konusu bütçe…          │
├─────────────────────────────────────────┤
│   ~/Documents/Whisper Transcriber       │
│            Change Folder…               │
├─────────────────────────────────────────┤
│  [Cancel]        [Pause]      [Finish]  │
└─────────────────────────────────────────┘
```

- The **name** is given before recording starts, because the output files are derived
  from it; renaming afterwards would touch three files at once.
- **Source** — microphone, system audio, or both. With system audio, a second picker
  chooses which app to capture (or all system audio).
- **Show the text live while speaking** toggles real-time transcription. When it's off,
  only audio is recorded and the text is produced afterwards. The live preview has its
  own model picker, separate from the one used for the accurate transcript.
- **Finish** → the file enters the queue and is transcribed with the usual settings.
- **Cancel** → the recording is deleted.
- A recording shorter than 0.3 seconds is **not** added to the queue and its file is
  deleted: a button pressed by accident shouldn't come back to the user as an error.
- Without microphone permission the sheet moves into its failure state and shows a
  button that opens Privacy Settings.
- The level meter is not decorative: it reports a percentage through
  `accessibilityValue`. The duration and the state are read as a single accessibility
  element.

The full design of live transcription — the audio sources, the streaming algorithm and
the two-pass write — is in `LIVE_TRANSCRIPTION.md`.

## Setup screen (first launch)

Shown instead of the main window when the environment isn't ready. Setup **does not
start on its own**; what is about to be downloaded is spelled out first.

```
┌────────────────────────────────────────────────────────┐
│                     Setup required                     │
│                                                        │
│  Whisper Transcriber installs an isolated Python       │
│  environment of its own to transcribe audio files.     │
│                                                        │
│  • About 850 MB to download, 890 MB on disk            │
│  • ~1 minute on a fast connection, once only           │
│  • Your system Python and Homebrew installations are   │
│    left alone                                          │
│  • Installed in: ~/Library/Application Support/…       │
│                                                        │
│         [ Start Setup ]        [ Details ]             │
└────────────────────────────────────────────────────────┘
```

During setup: the step name (`3/8 Installing dependencies`), a **real** progress bar
rather than an indeterminate one, a collapsible section that opens the live log, and a
cancel button. On failure: what happened, at which step, the last 20 log lines, and
the `[Try Again]` and `[Copy Log]` buttons.

## Settings window

Opened with ⌘,. The settings here are **the app's behaviour**; a job's settings (model,
language, format, device) stay in the main window's top-right pane — that pane is
copied onto every job added to the queue, this window is not.

| Tab | Contents |
|---|---|
| **General** | Start as soon as a file is added, prevent sleep, confirm on quit, notify on completion, reveal in Finder on completion, the default output folder and "overwrite" |
| **Models** | The model folder path (`~/.cache/whisper` by default, changeable) and the list of models; downloaded ones show their on-disk size, the others show ⬇︎ and `—`. Each row carries the one action that applies to it: a **trash button** for a downloaded model, which asks for confirmation and names the space it frees (ADR-017), a **download button** for one that isn't, and a progress bar for the download in flight (ADR-019). The folder itself is never removed, there is no "delete all", and one download runs at a time. |
| **Runtime** | The Python/whisper/torch/imageio-ffmpeg versions read from `runtime.json`, the installation date, how much disk it occupies, the install path, **device selection (CPU / MPS experimental)**, the **CPU use** picker (ADR-018), and the `[Health Check]` `[Reinstall…]` `[Delete Environment…]` `[Reveal in Finder]` `[Open Logs]` buttons |
| **About** | Version plus build number, a short description ("the audio is never sent to any server"), the installed versions, **[Check for Updates…]** with a *check automatically* box and the last check's date (all hidden in a build with no `SUFeedURL` — ADR-020), a repository link (hidden when `Info.plist` → `WTRepositoryURL` is empty), and the licence |

The two destructive actions (`Reinstall…`, `Delete Environment…`) end in an ellipsis and ask
for confirmation; both state explicitly that they do not touch the user's model cache.
The "on disk" row is computed by walking the directory tree, so it runs once when the
tab is opened, and inside an actor.

## Accessibility and behavioural details

- Every control is reachable by keyboard; progress bars report a percentage to VoiceOver.
- Dropdown labels **are written out** and merely hidden visually with
  `labelsHidden()`. `Picker("", …)` is a common pattern but gives VoiceOver no name at
  all.
- A queue row is a single accessibility element
  (`accessibilityElement(children: .combine)`): its name is the file name, its value is
  the state plus the percentage. Without that, VoiceOver walks the file name, the state
  and the percentage separately.
- The coloured dot in the status indicator is `accessibilityHidden` — the text beside
  it already carries the information, and colour alone carries no meaning.
- Keyboard shortcuts: ⌘O add files, ⌘R start, ⌘. stop, ⇧⌘K clear completed,
  ⌘, settings, ⇧⌘R record.
- On long jobs the app keeps running even if the window is closed (it stays in the
  Dock); quitting while the queue is running asks for confirmation.
- When the queue finishes while the user is in another app, a
  `UNUserNotificationCenter` notification is sent ("4 files completed, 1 failed").
- Dark and light appearance and Dynamic Type are supported; no fixed font sizes are
  used.
- The app prevents the machine from sleeping: while a job runs, activity is held with
  `ProcessInfo.beginActivity(.userInitiated)`.
