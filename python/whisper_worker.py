#!/usr/bin/env python3
"""The Whisper Transcriber background worker.

The protocol contract: docs/PROTOCOL.md (normative).

stdout is the NDJSON protocol channel and NOTHING else. Never use a plain ``print()`` —
use ``emit()``. At startup the real fd 1 is duplicated and kept, then ``sys.stdout`` and
``sys.stderr`` are each replaced with a log shim; that way everything torch, numba and
whisper write turns into a ``log`` event instead of corrupting the protocol.

Usage:
    whisper_worker.py capabilities      # capability discovery, loads no model
    whisper_worker.py transcribe        # the job definition is one line of JSON on stdin
    whisper_worker.py stream            # live mode: audio in on stdin, text out on stdout
"""

from __future__ import annotations

import base64
import io
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from typing import Any

PROTOCOL_VERSION = 1
# Live mode carries its own version; the batch job definition stays valid as v1.
STREAM_PROTOCOL_VERSION = 2
WORKER_VERSION = "0.1.0"

# --- live mode constants -----------------------------------------------------
# The rationale for each was established by measurement: docs/LIVE_TRANSCRIPTION.md.

# The buffer is re-decoded once it grows this big. Because the loop is sequential it brakes
# itself: if decoding takes longer than a tick, the next round starts with more audio.
# 3 s was tried and the worst commit latency came out at 8.1 s; lowered to 1.5 s.
_STREAM_TICK_SECONDS = 1.5
# A segment is considered "done growing" if it ends at least this far back from the end of
# the buffer. A plain "everything but the last segment" rule held a segment back until the
# next one appeared, which during a pause in speech could be a long time.
_STREAM_STABLE_MARGIN_SECONDS = 1.0
# whisper's natural window. Past it, the last segment is force-committed too.
_STREAM_MAX_BUFFER_SECONDS = 30.0
# The tail of the committed text is passed to the next call as context.
_STREAM_PROMPT_CHARS = 200
# The digital-silence gate. 10 s of zeros produces severe hallucination with the small model
# (even with no_speech_prob at 0.841). Real room noise is far above this threshold, so no
# speech is filtered out.
_STREAM_SILENCE_RMS = 1e-4
# The live preview can't use beam search: the same work takes 6.79 s.
_STREAM_DECODE_OPTIONS = {"beam_size": None, "best_of": None, "temperature": 0.0}

# whisper.audio constants; needed to convert a frame count to seconds.
# We delay the import (torch is expensive on the paths other than capabilities), which is why
# the values aren't pinned here — they are read inside _frames_to_seconds.
_SAMPLE_RATE = 16000
_HOP_LENGTH = 160

SUPPORTED_FORMATS = ("txt", "vtt", "srt", "tsv", "json", "notes")

# Format name → file extension. In whisper's writers the two are the same; "notes" is the
# format we added and it is written as markdown (ADR-014).
_FORMAT_EXTENSIONS = {"notes": "md"}

# The formats that use our own writer. Everything else goes through whisper's get_writer() —
# being bit-for-bit identical to the CLI depends on that.
_OWN_FORMATS = ("notes",)

# The segment line in whisper's verbose output:
#   [00:00.000 --> 00:02.400]  Merhaba.
#   [01:02:05.123 --> 01:02:08.000]  Uzun kayıt.
_SEGMENT_LINE = re.compile(r"^\[(?P<start>[\d:]+\.\d{3}) --> (?P<end>[\d:]+\.\d{3})\] (?P<text>.*)$")


# ---------------------------------------------------------------------------
# The protocol channel
# ---------------------------------------------------------------------------

_proto = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")


# The channel's protocol version. The version is a property of **the channel**, not of the
# individual events: in live mode the log and status events must carry v2 too, or the Swift
# decoder sees two versions in one stream. `cmd_stream` pulls this to v2.
_protocol_version = PROTOCOL_VERSION


def set_protocol_version(version: int) -> None:
    global _protocol_version
    _protocol_version = version


def emit(event: dict[str, Any]) -> None:
    """Emits a single protocol event and flushes immediately."""
    event.setdefault("v", _protocol_version)
    _proto.write(json.dumps(event, ensure_ascii=False) + "\n")
    _proto.flush()


def log(message: str, level: str = "info") -> None:
    emit({"type": "log", "level": level, "message": message})


class _LogShim(io.TextIOBase):
    """Stands in for sys.stdout/stderr and turns every line written into a log event.

    It emits nothing until a line is complete, so the updates tqdm makes with ``\\r``
    don't each produce an event.
    """

    def __init__(self, level: str) -> None:
        self._level = level
        self._buf = ""

    def write(self, s: str) -> int:
        self._buf += s
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            line = line.replace("\r", "").strip()
            if line:
                log(line, self._level)
        return len(s)

    def flush(self) -> None:  # pragma: no cover - no behaviour
        pass

    def isatty(self) -> bool:
        return False


def install_log_shims() -> None:
    sys.stdout = _LogShim("info")
    sys.stderr = _LogShim("warning")


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class WorkerError(Exception):
    """A classified error that can be shown to the user."""

    code = "INTERNAL_ERROR"
    recoverable = False

    def __init__(self, message: str, detail: str = "") -> None:
        super().__init__(message)
        self.message = message
        self.detail = detail


class BadJob(WorkerError):
    code = "BAD_JOB"


class AudioDecodeFailed(WorkerError):
    code = "AUDIO_DECODE_FAILED"


class ModelDownloadFailed(WorkerError):
    code = "MODEL_DOWNLOAD_FAILED"
    recoverable = True


class ModelLoadFailed(WorkerError):
    code = "MODEL_LOAD_FAILED"


class OutOfMemory(WorkerError):
    code = "OUT_OF_MEMORY"


class OutputExists(WorkerError):
    code = "OUTPUT_EXISTS"


class WorkerCancelled(WorkerError):
    code = "CANCELLED"

    def __init__(self) -> None:
        super().__init__("The job was cancelled.")


# ---------------------------------------------------------------------------
# Cancellation
# ---------------------------------------------------------------------------

_cancelled = False


def _on_sigterm(_signum: int, _frame: object) -> None:
    global _cancelled
    _cancelled = True


def check_cancelled() -> None:
    if _cancelled:
        raise WorkerCancelled()


def install_signal_handlers() -> None:
    signal.signal(signal.SIGTERM, _on_sigterm)
    signal.signal(signal.SIGINT, _on_sigterm)


# ---------------------------------------------------------------------------
# Progress: we replace whisper's tqdm with a class of our own
# ---------------------------------------------------------------------------

# The active progress receiver. Its signature: (done, total | None) -> None
_progress_sink = None


def _set_progress_sink(sink) -> None:
    global _progress_sink
    _progress_sink = sink


def _make_progress_tqdm(base):
    """Produces a subclass of the ``base`` tqdm class that emits its update calls.

    whisper constructs the progress bar with ``disable=verbose is not False``; because we
    call it with ``verbose=True`` the bar ends up disabled and tqdm's own ``update()``
    body returns early. That is why we keep the counter ourselves — on a disabled bar
    ``self.n`` can't be trusted.
    """

    class ProgressTqdm(base):  # type: ignore[misc, valid-type]
        def __init__(self, *args, **kwargs):
            self._wt_total = kwargs.get("total")
            self._wt_n = 0
            super().__init__(*args, **kwargs)

        def update(self, n=1):
            check_cancelled()
            self._wt_n += n or 0
            if _progress_sink is not None:
                _progress_sink(self._wt_n, self._wt_total)
            return super().update(n)

    return ProgressTqdm


def _frames_to_seconds(frames: float) -> float:
    return float(frames) * _HOP_LENGTH / _SAMPLE_RATE


# ---------------------------------------------------------------------------
# Environment: ffmpeg and the model directory
# ---------------------------------------------------------------------------


def find_ffmpeg() -> str:
    """Returns the ffmpeg at a known path. We never trust PATH.

    First ``runtime/bin/ffmpeg`` in the runtime (the symlink the app installs), then the
    static binary imageio-ffmpeg brings along.
    """
    runtime_bin = os.path.join(os.path.dirname(os.path.dirname(sys.prefix)), "bin", "ffmpeg")
    if os.path.exists(runtime_bin):
        return runtime_bin
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception as exc:  # pragma: no cover - if the environment is broken
        raise AudioDecodeFailed(
            "ffmpeg was not found.",
            f"runtime/bin/ffmpeg is missing and imageio-ffmpeg would not load: {exc}",
        ) from exc


def default_model_dir() -> str:
    return os.path.join(os.path.expanduser("~"), ".cache", "whisper")


def decode_audio(path: str, ffmpeg: str):
    """Decodes the audio to 16 kHz mono float32.

    It does the same job as whisper.load_audio, but calls ffmpeg at a known path rather
    than looking for it on PATH, and makes the failure classifiable.
    """
    import numpy as np

    cmd = [
        ffmpeg,
        "-nostdin",
        "-threads",
        "0",
        "-i",
        path,
        "-f",
        "s16le",
        "-ac",
        "1",
        "-acodec",
        "pcm_s16le",
        "-ar",
        str(_SAMPLE_RATE),
        "-",
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, check=False)
    except OSError as exc:
        raise AudioDecodeFailed("ffmpeg could not be run.", str(exc)) from exc

    if proc.returncode != 0:
        tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise AudioDecodeFailed(
            "The audio file could not be decoded.",
            f"ffmpeg exit code {proc.returncode}: " + " | ".join(tail[-3:]),
        )
    if not proc.stdout:
        raise AudioDecodeFailed(
            "The audio file contains no audio stream to process.",
            "ffmpeg produced no output (the file may be empty or video only).",
        )

    return np.frombuffer(proc.stdout, np.int16).flatten().astype(np.float32) / 32768.0


# ---------------------------------------------------------------------------
# capabilities
# ---------------------------------------------------------------------------


def cmd_capabilities() -> int:
    import whisper
    from whisper.tokenizer import LANGUAGES

    emit(
        {
            "type": "hello",
            "worker": WORKER_VERSION,
            "python": sys.version.split()[0],
            "whisper": getattr(whisper.version, "__version__", "?"),
            "torch": _torch_version(),
            "ffmpeg": _ffmpeg_version(),
            "device": "cpu",
            "mps_available": _mps_available(),
        }
    )

    model_dir = default_model_dir()
    available = set(whisper.available_models())
    # The **real on-disk** size of the downloaded models. For those not downloaded we report
    # no size: whisper doesn't know it before downloading, and embedding a table by hand
    # would silently go wrong at the next version upgrade.
    sizes: dict[str, int] = {}
    if os.path.isdir(model_dir):
        for entry in os.listdir(model_dir):
            name = entry[:-3] if entry.endswith(".pt") else None
            if name is None or name not in available:
                continue
            try:
                sizes[name] = os.path.getsize(os.path.join(model_dir, entry))
            except OSError:
                continue
    cached = sorted(sizes)

    emit(
        {
            "type": "capabilities",
            "models": list(whisper.available_models()),
            "models_cached": cached,
            "models_bytes": {name: sizes[name] for name in cached},
            "model_dir": model_dir,
            "languages": [{"code": c, "name": n} for c, n in sorted(LANGUAGES.items())],
            "output_formats": list(SUPPORTED_FORMATS),
            "tasks": ["transcribe", "translate"],
            "devices": ["cpu"] + (["mps"] if _mps_available() else []),
        }
    )
    return 0


def _torch_version() -> str:
    try:
        import torch

        return torch.__version__
    except Exception:  # pragma: no cover
        return "?"


def _mps_available() -> bool:
    try:
        import torch

        return bool(torch.backends.mps.is_available())
    except Exception:  # pragma: no cover
        return False


def _ffmpeg_version() -> str:
    try:
        out = subprocess.run([find_ffmpeg(), "-version"], capture_output=True, check=False, text=True)
        first = out.stdout.splitlines()[0]
        return first.split()[2]
    except Exception:  # pragma: no cover
        return "?"


# ---------------------------------------------------------------------------
# transcribe
# ---------------------------------------------------------------------------

# Options passed straight to transcribe(), skipped when None.
_PASSTHROUGH_OPTIONS = (
    "temperature",
    "compression_ratio_threshold",
    "logprob_threshold",
    "no_speech_threshold",
    "condition_on_previous_text",
    "initial_prompt",
    "carry_initial_prompt",
    "word_timestamps",
    "prepend_punctuations",
    "append_punctuations",
    "clip_timestamps",
    "hallucination_silence_threshold",
    # the ones passed as **decode_options
    "beam_size",
    "best_of",
    "patience",
    "length_penalty",
    "suppress_tokens",
    "fp16",
)

_WRITER_OPTIONS = (
    "highlight_words",
    "max_line_width",
    "max_line_count",
    "max_words_per_line",
)

# The whisper CLI's argparse defaults differ from the library's defaults.
# The important ones are beam_size/best_of: the CLI does beam search, the library greedy.
# To match the output the user gets today exactly, we take the CLI's side.
# Verified: without these three the output text differs (docs/PLAN.md, Phase 1).
_CLI_PARITY_DEFAULTS = {
    "beam_size": 5,
    "best_of": 5,
    "temperature": (0.0, 0.2, 0.4, 0.6, 0.8, 1.0),
}


def read_job() -> dict[str, Any]:
    raw = sys.__stdin__.read()
    if not raw.strip():
        raise BadJob("No job definition arrived.", "stdin was empty.")
    try:
        job = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BadJob("The job definition could not be read.", f"invalid JSON: {exc}") from exc
    if not isinstance(job, dict):
        raise BadJob("The job definition could not be read.", "a JSON object was expected.")
    return job


def validate_job(job: dict[str, Any]) -> dict[str, Any]:
    input_path = os.path.expanduser(str(job.get("input_path") or ""))
    if not input_path:
        raise BadJob("No input file was given.", "input_path is empty.")
    if not os.path.isfile(input_path):
        raise BadJob("The input file was not found.", input_path)
    if os.path.getsize(input_path) == 0:
        raise AudioDecodeFailed("The audio file is empty.", f"{input_path} is zero bytes.")

    formats = job.get("output_formats") or ["txt"]
    if not isinstance(formats, list) or not formats:
        raise BadJob("No output format was given.", f"output_formats: {formats!r}")
    unknown = [f for f in formats if f not in SUPPORTED_FORMATS]
    if unknown:
        raise BadJob(
            "Unsupported output format.",
            f"unknown: {unknown}, supported: {list(SUPPORTED_FORMATS)}",
        )

    task = job.get("task") or "transcribe"
    if task not in ("transcribe", "translate"):
        raise BadJob("Invalid task.", f"task: {task!r}")

    output_dir = job.get("output_dir") or os.path.dirname(input_path)
    output_dir = os.path.expanduser(str(output_dir))

    return {
        "job_id": job.get("job_id"),
        "input_path": input_path,
        "output_dir": output_dir,
        "output_formats": formats,
        "model": job.get("model") or "small",
        "model_dir": os.path.expanduser(str(job.get("model_dir") or default_model_dir())),
        "language": job.get("language"),
        "task": task,
        "device": job.get("device") or "cpu",
        "options": job.get("options") or {},
        "writer_options": job.get("writer_options") or {},
        "overwrite": bool(job.get("overwrite", False)),
        "emit_segments": bool(job.get("emit_segments", True)),
    }


def format_extension(fmt: str) -> str:
    return _FORMAT_EXTENSIONS.get(fmt, fmt)


def expected_outputs(job: dict[str, Any]) -> dict[str, str]:
    stem = os.path.splitext(os.path.basename(job["input_path"]))[0]
    return {
        fmt: os.path.join(job["output_dir"], f"{stem}.{format_extension(fmt)}")
        for fmt in job["output_formats"]
    }


def clock(seconds: float) -> str:
    """`04:12`, or `1:04:12` once it passes an hour."""
    total = int(seconds)
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def write_notes(result: dict[str, Any], file) -> None:
    """A timestamped note list — the one format with no counterpart in whisper.

    Every segment becomes a bullet: `- [04:12] text`. Empty segments are skipped; during
    silence whisper occasionally produces segments with empty text, and those showed up
    as empty bullets in the note list.
    """
    for segment in result.get("segments", []):
        text = str(segment.get("text", "")).strip()
        if not text:
            continue
        print(f"- [{clock(float(segment.get('start', 0.0)))}] {text}", file=file)


def install_patches(module, whisper_mod, emit_segments: bool) -> None:
    """Replaces whisper's tqdm and make_safe hooks with our own.

    - ``module.tqdm`` is the tqdm *module*, while ``whisper_mod.tqdm`` is the tqdm *class*
      (``from tqdm import tqdm``). They are two separate targets.
    - ``make_safe`` is wrapped only to capture the segment line in the verbose output; it
      emits the line and returns an empty string, cutting the print noise.
    """
    progress_cls = _make_progress_tqdm(module.tqdm.tqdm)

    class _TqdmModuleShim:
        tqdm = progress_cls

    module.tqdm = _TqdmModuleShim
    whisper_mod.tqdm = _make_progress_tqdm(whisper_mod.tqdm)

    if not emit_segments:
        return

    original_make_safe = module.make_safe
    counter = {"n": 0}

    def capturing_make_safe(line: str) -> str:
        match = _SEGMENT_LINE.match(line)
        if match is None:
            return original_make_safe(line)
        emit(
            {
                "type": "segment",
                "id": counter["n"],
                "start": _parse_timestamp(match.group("start")),
                "end": _parse_timestamp(match.group("end")),
                "text": match.group("text"),
            }
        )
        counter["n"] += 1
        return ""

    module.make_safe = capturing_make_safe


def _parse_timestamp(value: str) -> float:
    """``MM:SS.mmm`` or ``HH:MM:SS.mmm`` → seconds."""
    parts = value.split(":")
    seconds = float(parts[-1])
    if len(parts) > 1:
        seconds += int(parts[-2]) * 60
    if len(parts) > 2:
        seconds += int(parts[-3]) * 3600
    return seconds


def build_transcribe_kwargs(job: dict[str, Any]) -> dict[str, Any]:
    kwargs: dict[str, Any] = {"verbose": True, "task": job["task"]}
    kwargs.update(_CLI_PARITY_DEFAULTS)
    if job["language"]:
        kwargs["language"] = job["language"]

    options = job["options"]
    for key in _PASSTHROUGH_OPTIONS:
        if key not in options:
            continue
        value = options[key]
        if value is None:
            # An option sent explicitly as null means "whisper's own default"; it overrides
            # the CLI-parity default too.
            kwargs.pop(key, None)
            continue
        kwargs[key] = tuple(value) if key == "temperature" and isinstance(value, list) else value
    return kwargs


def load_model(job: dict[str, Any]):
    import whisper

    name = job["model"]
    model_dir = job["model_dir"]
    available = whisper.available_models()
    if name not in available:
        raise BadJob("Unknown model.", f"{name!r} — options: {', '.join(available)}")

    cached = os.path.isfile(os.path.join(model_dir, f"{name}.pt"))
    if not cached:
        emit({"type": "status", "phase": "downloading_model", "model": name})
        _set_progress_sink(
            lambda done, total: emit(
                {
                    "type": "progress",
                    "phase": "downloading_model",
                    "processed": done,
                    "total": total,
                    "pct": round(100.0 * done / total, 1) if total else None,
                }
            )
        )
    else:
        emit({"type": "status", "phase": "loading_model", "model": name})

    try:
        model = whisper.load_model(name, device=job["device"], download_root=model_dir)
    except WorkerCancelled:
        raise
    except (OSError, RuntimeError) as exc:
        if not cached and _looks_like_network_error(exc):
            raise ModelDownloadFailed(
                "The model could not be downloaded.",
                f"{name}: {exc}",
            ) from exc
        if _looks_like_oom(exc):
            raise OutOfMemory(
                "Not enough memory for the model.",
                f"{name}: {exc}",
            ) from exc
        raise ModelLoadFailed("The model could not be loaded.", f"{name}: {exc}") from exc
    finally:
        _set_progress_sink(None)

    if not cached:
        emit({"type": "status", "phase": "loading_model", "model": name})
    return model


def _looks_like_network_error(exc: Exception) -> bool:
    text = str(exc).lower()
    return any(k in text for k in ("urlopen", "connection", "network", "resolve", "timed out", "ssl"))


def _looks_like_oom(exc: Exception) -> bool:
    text = str(exc).lower()
    return "out of memory" in text or "cannot allocate" in text


def write_outputs(job: dict[str, Any], result: dict[str, Any]) -> list[dict[str, Any]]:
    """Writes the outputs atomically.

    whisper's formats go through its own writers; only "notes" is ours (ADR-014).

    Everything is written to a temporary directory first, then moved into place one by one
    with os.replace. A job cut short leaves no half-written file in the destination.
    """
    os.makedirs(job["output_dir"], exist_ok=True)
    writer_options = {k: job["writer_options"].get(k) for k in _WRITER_OPTIONS}

    outputs: list[dict[str, Any]] = []
    tmp_dir = tempfile.mkdtemp(prefix=".whisper-tmp-", dir=job["output_dir"])
    try:
        for fmt, final_path in expected_outputs(job).items():
            tmp_path = os.path.join(tmp_dir, os.path.basename(final_path))
            if fmt in _OWN_FORMATS:
                with open(tmp_path, "w", encoding="utf-8") as handle:
                    write_notes(result, handle)
            else:
                # Inside: a job asking only for "notes" can write its output without loading
                # whisper at all.
                from whisper.utils import get_writer

                writer = get_writer(fmt, tmp_dir)
                writer(result, job["input_path"], **writer_options)
            os.replace(tmp_path, final_path)
            outputs.append({"format": fmt, "path": final_path, "bytes": os.path.getsize(final_path)})
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
    return outputs


def cmd_transcribe() -> int:
    job = validate_job(read_job())

    if not job["overwrite"]:
        existing = [p for p in expected_outputs(job).values() if os.path.exists(p)]
        if existing:
            raise OutputExists(
                "The output file already exists.",
                "will not be overwritten: " + ", ".join(existing),
            )

    import whisper

    module = sys.modules["whisper.transcribe"]

    emit(
        {
            "type": "hello",
            "worker": WORKER_VERSION,
            "python": sys.version.split()[0],
            "whisper": getattr(whisper.version, "__version__", "?"),
            "torch": _torch_version(),
            "ffmpeg": _ffmpeg_version(),
            "device": job["device"],
            "mps_available": _mps_available(),
        }
    )

    threads = job["options"].get("threads") or 0
    if threads:
        import torch

        torch.set_num_threads(int(threads))

    started = time.monotonic()

    emit({"type": "status", "phase": "decoding_audio"})
    audio = decode_audio(job["input_path"], find_ffmpeg())
    duration = len(audio) / _SAMPLE_RATE
    emit({"type": "status", "phase": "audio_ready", "duration": round(duration, 3)})
    check_cancelled()

    model = load_model(job)
    check_cancelled()

    install_patches(module, whisper, job["emit_segments"])
    _set_progress_sink(
        lambda done, total: emit(
            {
                "type": "progress",
                "phase": "transcribing",
                "processed": round(_frames_to_seconds(done), 2),
                "total": round(_frames_to_seconds(total), 2) if total else None,
                "pct": round(100.0 * done / total, 1) if total else None,
            }
        )
    )

    emit({"type": "status", "phase": "transcribing"})
    try:
        result = whisper.transcribe(model, audio, **build_transcribe_kwargs(job))
    except WorkerCancelled:
        raise
    except RuntimeError as exc:
        if _looks_like_oom(exc):
            raise OutOfMemory("Not enough memory for the transcription.", str(exc)) from exc
        raise
    finally:
        _set_progress_sink(None)

    check_cancelled()
    emit({"type": "status", "phase": "writing_output"})
    outputs = write_outputs(job, result)

    elapsed = time.monotonic() - started
    text = result.get("text", "")
    emit(
        {
            "type": "result",
            "job_id": job["job_id"],
            "language": result.get("language"),
            "duration": round(duration, 3),
            "elapsed": round(elapsed, 3),
            "rtf": round(elapsed / duration, 3) if duration else None,
            "outputs": outputs,
            "segment_count": len(result.get("segments", [])),
            "text_chars": len(text),
        }
    )
    return 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# stream — live mode
# ---------------------------------------------------------------------------


def read_line_job() -> dict[str, Any]:
    """Live mode's first line: the configuration.

    `read_job` reads the whole of stdin; because the stream carries on in live mode, only
    the first line is taken.
    """
    raw = sys.__stdin__.readline()
    if not raw.strip():
        raise BadJob("No job definition arrived.", "the first line from stdin was empty.")
    try:
        job = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BadJob("The job definition could not be read.", f"invalid JSON: {exc}") from exc
    if not isinstance(job, dict):
        raise BadJob("The job definition could not be read.", "a JSON object was expected.")
    return job


def validate_stream_job(job: dict[str, Any]) -> dict[str, Any]:
    task = job.get("task") or "transcribe"
    if task not in ("transcribe", "translate"):
        raise BadJob("Invalid task.", f"task: {task!r}")
    return {
        "job_id": job.get("job_id"),
        "model": job.get("model") or "small",
        "model_dir": os.path.expanduser(str(job.get("model_dir") or default_model_dir())),
        "language": job.get("language"),
        "task": task,
        "device": job.get("device") or "cpu",
        "options": {},
    }


class StreamReader(threading.Thread):
    """Reads stdin on a separate thread.

    Transcription blocks the main thread for seconds at a time, and audio keeps arriving
    meanwhile. Without separating the reading we would lose the incoming audio.

    The protocol: one JSON event per line.
        {"type":"audio","seq":41,"pcm":"<base64 int16le>"}
        {"type":"stop"}
    """

    def __init__(self, stream) -> None:
        super().__init__(daemon=True)
        self._stream = stream
        self._lock = threading.Lock()
        self._chunks: list[Any] = []
        self._finished = False
        self.decode_errors = 0

    def run(self) -> None:
        import numpy as np

        try:
            for line in self._stream:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    self.decode_errors += 1
                    continue
                kind = event.get("type")
                if kind == "audio":
                    try:
                        raw = base64.b64decode(event.get("pcm") or "")
                    except Exception:
                        self.decode_errors += 1
                        continue
                    if not raw:
                        continue
                    samples = np.frombuffer(raw, np.int16).astype(np.float32) / 32768.0
                    with self._lock:
                        self._chunks.append(samples)
                elif kind == "stop":
                    break
        finally:
            with self._lock:
                self._finished = True

    def drain(self):
        """Takes the accumulated audio as one piece and empties the queue."""
        import numpy as np

        with self._lock:
            chunks = self._chunks
            self._chunks = []
        if not chunks:
            return np.zeros(0, dtype=np.float32)
        return np.concatenate(chunks)

    @property
    def finished(self) -> bool:
        with self._lock:
            return self._finished and not self._chunks


def _rms(samples) -> float:
    import numpy as np

    if samples.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))


def cmd_stream() -> int:
    """Live transcription: audio in on stdin, committed and provisional text out on stdout.

    The algorithm (docs/LIVE_TRANSCRIPTION.md → The streaming algorithm): on every tick
    **all** of the audio in the buffer is re-decoded greedily; everything but the trailing
    segment counts as committed and is dropped from the buffer. Because the last segment
    is still growing, the cut point stays inside it — the first word of a window cut
    mid-sentence gets corrupted (measured).
    """
    import numpy as np
    import whisper

    set_protocol_version(STREAM_PROTOCOL_VERSION)
    job = validate_stream_job(read_line_job())

    emit(
        {
            "type": "hello",
            "worker": WORKER_VERSION,
            "mode": "stream",
            "python": sys.version.split()[0],
            "whisper": getattr(whisper.version, "__version__", "?"),
            "torch": _torch_version(),
            "device": job["device"],
            "mps_available": _mps_available(),
        }
    )

    model = load_model(job)
    emit({"type": "status", "phase": "ready"})

    reader = StreamReader(sys.__stdin__)
    reader.start()

    tick_samples = int(_STREAM_TICK_SECONDS * _SAMPLE_RATE)
    max_samples = int(_STREAM_MAX_BUFFER_SECONDS * _SAMPLE_RATE)

    buffer = np.zeros(0, dtype=np.float32)
    offset = 0.0
    prompt = ""
    committed_texts: list[str] = []
    started = time.monotonic()

    def transcribe(audio):
        kwargs = dict(_STREAM_DECODE_OPTIONS)
        kwargs["task"] = job["task"]
        kwargs["verbose"] = None
        if job["language"]:
            kwargs["language"] = job["language"]
        if prompt:
            kwargs["initial_prompt"] = prompt
        return whisper.transcribe(model, audio, **kwargs)

    while True:
        check_cancelled()

        incoming = reader.drain()
        if incoming.size:
            buffer = np.concatenate([buffer, incoming])

        final = reader.finished
        over = buffer.size >= max_samples
        if buffer.size < tick_samples and not final and not over:
            time.sleep(0.05)
            continue

        if buffer.size == 0:
            if final:
                break
            continue

        # Digital silence produces hallucination; skip it without decoding.
        if _rms(buffer) < _STREAM_SILENCE_RMS:
            if final:
                break
            if over:
                offset += buffer.size / _SAMPLE_RATE
                buffer = np.zeros(0, dtype=np.float32)
            continue

        result = transcribe(buffer)
        segments = result.get("segments", [])
        if final or over:
            stable = segments
        else:
            # The segments are ordered and the condition monotonic, so the result is a prefix.
            cutoff = buffer.size / _SAMPLE_RATE - _STREAM_STABLE_MARGIN_SECONDS
            stable = [s for s in segments if float(s.get("end", 0.0)) <= cutoff]

        for segment in stable:
            text = str(segment.get("text", "")).strip()
            if not text:
                continue
            committed_texts.append(text)
            emit(
                {
                    "type": "committed",
                    "text": text,
                    "start": round(offset + float(segment.get("start", 0.0)), 3),
                    "end": round(offset + float(segment.get("end", 0.0)), 3),
                }
            )

        if stable:
            cut = float(stable[-1].get("end", 0.0))
            cut_samples = min(int(cut * _SAMPLE_RATE), buffer.size)
            buffer = buffer[cut_samples:]
            offset += cut_samples / _SAMPLE_RATE
            prompt = (" ".join(committed_texts))[-_STREAM_PROMPT_CHARS:]
        elif over:
            # It hit the ceiling but no segment came out: audio that makes no sense. Without
            # dropping the buffer it would grow forever.
            offset += buffer.size / _SAMPLE_RATE
            buffer = np.zeros(0, dtype=np.float32)

        if final:
            break

        # The provisional text is **everything uncommitted**, not just the last segment.
        # Sending only the last one made the not-yet-committed segments in the middle never
        # appear on screen at all: the user saw the committed text, then a gap, then the very
        # last sentence.
        pending = segments[len(stable) :]
        emit(
            {
                "type": "partial",
                "text": " ".join(str(s.get("text", "")).strip() for s in pending).strip(),
            }
        )

    text = " ".join(committed_texts)
    emit(
        {
            "type": "result",
            "job_id": job["job_id"],
            "duration": round(offset + buffer.size / _SAMPLE_RATE, 3),
            "elapsed": round(time.monotonic() - started, 3),
            "segment_count": len(committed_texts),
            "text_chars": len(text),
            "text": text,
        }
    )
    return 0


def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else ""
    if mode not in ("capabilities", "transcribe", "stream"):
        usage = f"{os.path.basename(argv[0])} (capabilities|transcribe|stream)"
        emit(
            {
                "type": "error",
                "code": "BAD_USAGE",
                "message": "Invalid run mode.",
                "detail": f"usage: {usage}, given: {mode!r}",
                "recoverable": False,
            }
        )
        return 1

    install_signal_handlers()
    install_log_shims()

    commands = {
        "capabilities": cmd_capabilities,
        "transcribe": cmd_transcribe,
        "stream": cmd_stream,
    }
    try:
        return commands[mode]()
    except WorkerError as exc:
        emit(
            {
                "type": "error",
                "code": exc.code,
                "message": exc.message,
                "detail": exc.detail,
                "recoverable": exc.recoverable,
            }
        )
        return 1
    except Exception as exc:  # unexpected: carry the raw trace through for diagnosis
        emit(
            {
                "type": "error",
                "code": "INTERNAL_ERROR",
                "message": "An unexpected error occurred.",
                "detail": f"{type(exc).__name__}: {exc}\n{traceback.format_exc()}",
                "recoverable": False,
            }
        )
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
