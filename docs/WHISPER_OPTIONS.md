# Whisper options ↔ UI mapping

This table defines the correspondence between the UI controls and the `whisper` CLI
parameters. The worker does not invoke the CLI; it calls the `whisper.transcribe()`
function directly with identically named arguments — so the CLI column is a reference
to "the command the user already knows".

> **Verified (Phase 1, openai-whisper 20250625):** the table was corrected by reading
> `inspect.signature(whisper.transcribe)` and the CLI's `argparse` definitions.

## ⚠ The CLI defaults differ from the library defaults

Calling whisper as a library does **not** give the same output as calling the CLI. The
CLI's argparse defaults override `transcribe()`'s own defaults:

| Parameter | CLI default | Library default | Consequence |
|---|---|---|---|
| `beam_size` | **5** | `None` | the CLI does beam search, the library does greedy decoding |
| `best_of` | **5** | `None` | number of candidates while temperature > 0 |
| `temperature` | `(0.0 … 1.0)` in steps of 0.2 | the same | no difference |

Measured in Phase 1: without those two, the output text for the same audio file comes
out different (for example "3 ayrı başlık" instead of "Üç ayrı başlık"). Because
matching the output the user gets today exactly is this project's core correctness
claim, the worker takes the CLI's side via `_CLI_PARITY_DEFAULTS`. That behaviour is
pinned permanently by `test_output_is_identical_to_the_cli`.

## The core controls (main panel)

| UI control | CLI | Worker field | Default | Note |
|---|---|---|---|---|
| **Model** (dropdown) | `--model` | `model` | `small` | The list comes from `whisper._MODELS`. Downloaded models show their on-disk size, the others show ⬇︎ — whisper doesn't report the size before downloading and we don't invent one (see `docs/PROTOCOL.md` → `models_bytes`). |
| **Language** (searchable list) | `--language` | `language` | `tr` | `whisper.tokenizer.LANGUAGES` (100 languages) plus "detect automatically" (`null`) at the top. The UI shows the names in its own language, the worker receives the ISO code. |
| **Task** (segmented control) | `--task` | `task` | `transcribe` | `transcribe` = write it out in the same language, `translate` = translate into English. |
| **Output format** (multiple selection) | `--output_format` | `output_formats` | `["txt"]` | Multiple selection; the formats are listed explicitly rather than using `all`. On top of whisper's five there is `notes` — see below. |
| **Output folder** | `--output_dir` | `output_dir` | the input file's folder | A choice between "next to the source file" and "a specific folder". |
| **Model folder** | `--model_dir` | `model_dir` | `~/.cache/whisper` | The user's existing 4.8 GB of models lives here. |
| **Device** | `--device` | `device` | `cpu` | `mps` is marked experimental. Not on the main panel but under **Settings → Runtime environment**: it isn't something that changes per job. |
| **CPU use** | `--threads` | `options.threads` | `balanced` | Three budgets (ADR-018). It also sets the child process's quality of service, which is **not** in the protocol. Measured: it changes the run time and never the output. |

## Parameters **not** in the interface

The v1 interface shows only the core controls above. Every decoding parameter —
`beam_size`, `best_of`, `temperature` and the fallback ladder,
`no_speech_threshold`, `compression_ratio_threshold`, `logprob_threshold`,
`hallucination_silence_threshold`, `initial_prompt`, `carry_initial_prompt`,
`condition_on_previous_text`, `word_timestamps`, `highlight_words`,
`max_line_width`, `max_line_count`, `max_words_per_line`, `fp16`,
`suppress_tokens`, `patience`, `length_penalty`, `clip_timestamps`,
`prepend_punctuations`, `append_punctuations` — is **not written into the job
definition**.

The rationale is in `docs/DECISIONS.md` → ADR-015. In short: not sending a key is
safer than sending it. The worker applies the command line's `beam_size=5`,
`best_of=5` and temperature ladder through `_CLI_PARITY_DEFAULTS`; equivalence is
defined in exactly one place.

The protocol did not shrink: the worker still accepts all of these keys. If an "expert
mode" is added later, filling the fields on the Swift side is all it takes.

The single exception is **`fp16`**: it isn't a user setting, it is derived from the
device. On CPU it is sent explicitly as `false` (to suppress the "FP16 is not
supported on CPU" warning whisper prints on every job); on MPS the key is absent
altogether.

## `null` semantics

In the job definition, an option being **absent** is different from it being `null`:

| What is sent | Meaning |
|---|---|
| no key | the worker's default applies (including CLI parity) |
| `"beam_size": null` | whisper's own default — the parity value is removed too |
| `"beam_size": 1` | the user's value |

The UI's "reset to default" action **removes** the key; it does not send `null`.

The same distinction holds where settings are written to disk: when `WhisperSettings`
is encoded, `language`, `beam_size` and `best_of` are written as an **explicit `null`**
when empty (because their defaults are not `nil`), while the other optionals are
omitted. That way a missing key in an older settings block falls back to the default,
while a field the user deliberately cleared stays cleared. Rationale:
`docs/DECISIONS.md` → ADR-013.

## `notes` — the timestamped note list

The one format whisper does not produce. Every segment becomes a bullet:

```markdown
- [00:00] Merhaba, bu bir test kaydıdır.
- [00:02] Bugünkü toplantının ana konusu bütçe kalemleriydi.
- [00:06] Üç ayrı başlık üzerinde konuştuk,
```

| Aspect | Value |
|---|---|
| Format name (in the protocol) | `notes` |
| File extension | `.md` — the only format whose name and extension diverge |
| Timestamp | `MM:SS`, or `H:MM:SS` past the hour; the segment's **start** |
| Text | identical to `txt`; the only difference is the `- [MM:SS] ` prefix |
| Empty segment | skipped (whisper can emit segments with empty text during silence) |

The writer lives in the worker (`write_notes`). Rationale and limits: ADR-014.

## Device selection and falling back to CPU

`mps` is **experimental**: `openai-whisper` is not reliable on MPS. If a job fails with
MPS, the queue does not drop it — it switches the device to `cpu` and retries **once**.
The log lines from the failed attempt are preserved and
`[warning] MPS failed, retrying on the CPU.` is appended to the log.
Rationale and limits: `docs/DECISIONS.md` → ADR-012.

## Validation rules (UI side)

Now that the advanced section is gone, producing an invalid combination is no longer
possible; what's left is three informational warnings and one block:

1. If the selected model hasn't been downloaded, the UI says it will be downloaded and
   that the first run may take a while.
2. Models ending in `.en` are English-only; a warning appears unless the language is
   `en` or automatic.
3. When `task == "translate"` the output language is English — the UI states this
   explicitly (a frequent misunderstanding: "translate" does not mean translating into the source
   language).
4. If no output format is selected at all, **Start** is disabled.

In addition, if the output file already exists and `overwrite` is off, confirmation is
asked for before the job starts.

## Presets

The user's own bundles are stored in `presets.json`. The app ships with four built-in
ones:

| Preset | Model | Language | Format | Note |
|---|---|---|---|---|
| **Quick note** | `small` | `tr` | `txt` | The exact equivalent of the user's existing command. |
| **Meeting notes** | `small` | `tr` | `notes` | A timestamped bullet list. |
| **High quality** | `large-v3` | `tr` | `txt` + `srt` | Better recognition, slower. |
| **Subtitles** | `large-v3-turbo` | `tr` | `srt` + `vtt` | Subtitle formats. |

Presets carry only the model, the language and the formats; they contain no decoding
parameters (ADR-015).

All four presets use a model that is already in the user's cache — no waiting for a
download on first use.
