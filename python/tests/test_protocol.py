"""Tests for the protocol contract — docs/PROTOCOL.md.

Nothing here downloads a model or runs a real transcription; whisper is monkeypatched.
The real transcription tests live in test_transcribe_real.py.
"""

import io
import json
import pathlib
import time
from typing import ClassVar

import pytest

import whisper_worker as ww

# ---------------------------------------------------------------------------
# emit / the log shim
# ---------------------------------------------------------------------------


def test_emit_writes_ndjson_with_a_version_field(events):
    ww.emit({"type": "status", "phase": "transcribing"})
    ww.emit({"type": "log", "level": "info", "message": "hello"})

    assert events.raw.count("\n") == 2, "every event must be one line"
    assert [e["v"] for e in events.all] == [ww.PROTOCOL_VERSION] * 2


def test_emit_does_not_escape_turkish_characters(events):
    ww.emit({"type": "log", "level": "info", "message": "şçğü İÖÜ"})
    assert "şçğü İÖÜ" in events.raw, "ensure_ascii=False is required"


def test_log_shell_emits_nothing_before_a_line_completes(events):
    shim = ww._LogShim("info")
    shim.write("half")
    assert events.all == []

    shim.write(" line\n")
    assert events.one("log")["message"] == "half line"


def test_log_shell_strips_tqdm_carriage_return_noise(events):
    shim = ww._LogShim("warning")
    shim.write("\r 50%|███       | 1/2\r 100%|██████| 2/2\n")

    message = events.one("log")["message"]
    assert "\r" not in message
    assert message.endswith("2/2")


def test_log_shell_swallows_empty_lines(events):
    shim = ww._LogShim("info")
    shim.write("\n\n   \n")
    assert events.all == []


# ---------------------------------------------------------------------------
# Parsing the segment line
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("00:00.000", 0.0),
        ("00:02.400", 2.4),
        ("01:05.400", 65.4),
        ("01:02:05.123", 3725.123),
    ],
)
def test_timestamp_parsing(value, expected):
    assert ww._parse_timestamp(value) == pytest.approx(expected)


def test_segment_line_parsing():
    match = ww._SEGMENT_LINE.match("[00:02.400 --> 00:06.120]  Today's meeting.")
    assert match is not None
    # The separator space is consumed; whisper's own leading space is preserved.
    assert match.group("text") == " Today's meeting."


def test_a_non_segment_line_does_not_match():
    assert ww._SEGMENT_LINE.match("Detected language: Turkish") is None


# ---------------------------------------------------------------------------
# Job-definition validation
# ---------------------------------------------------------------------------


def _job(tmp_path, **overrides):
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"fake audio data")
    job = {"input_path": str(audio), "output_dir": str(tmp_path)}
    job.update(overrides)
    return job


def test_validate_job_fills_in_the_defaults(tmp_path):
    job = ww.validate_job(_job(tmp_path))

    assert job["model"] == "small"
    assert job["task"] == "transcribe"
    assert job["device"] == "cpu"
    assert job["output_formats"] == ["txt"]
    assert job["overwrite"] is False
    assert job["emit_segments"] is True
    assert job["model_dir"] == ww.default_model_dir()


def test_validate_job_uses_the_input_directory_when_no_output_dir(tmp_path):
    job = _job(tmp_path)
    del job["output_dir"]
    assert ww.validate_job(job)["output_dir"] == str(tmp_path)


def test_validate_job_expands_a_tilde(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    audio = tmp_path / "audio.m4a"
    audio.write_bytes(b"x")
    job = ww.validate_job({"input_path": "~/audio.m4a", "output_dir": "~/output"})
    assert job["input_path"] == str(audio)
    assert job["output_dir"] == str(tmp_path / "output")


def test_validate_job_missing_file(tmp_path):
    with pytest.raises(ww.BadJob):
        ww.validate_job({"input_path": str(tmp_path / "missing.m4a")})


def test_validate_job_gives_an_audio_error_for_an_empty_file(tmp_path):
    empty = tmp_path / "empty.m4a"
    empty.touch()
    with pytest.raises(ww.AudioDecodeFailed):
        ww.validate_job({"input_path": str(empty)})


def test_validate_job_unsupported_format(tmp_path):
    with pytest.raises(ww.BadJob, match="format"):
        ww.validate_job(_job(tmp_path, output_formats=["docx"]))


def test_validate_job_rejects_the_all_format(tmp_path):
    """The CLI's 'all' has to be sent as an explicit list in the protocol."""
    with pytest.raises(ww.BadJob):
        ww.validate_job(_job(tmp_path, output_formats=["all"]))


def test_validate_job_invalid_task(tmp_path):
    with pytest.raises(ww.BadJob, match="task"):
        ww.validate_job(_job(tmp_path, task="summarise"))


def test_validate_job_ignores_unknown_keys(tmp_path):
    job = ww.validate_job(_job(tmp_path, future_field={"a": 1}))
    assert "future_field" not in job


def test_expected_outputs_keeps_the_file_name(tmp_path):
    job = ww.validate_job(_job(tmp_path, output_formats=["txt", "srt"]))
    outputs = ww.expected_outputs(job)
    assert outputs["txt"] == str(tmp_path / "audio.txt")
    assert outputs["srt"] == str(tmp_path / "audio.srt")


def test_read_job_empty_stdin(monkeypatch):
    import io as _io

    monkeypatch.setattr(ww.sys, "__stdin__", _io.StringIO("  \n"))
    with pytest.raises(ww.BadJob, match="arrived"):
        ww.read_job()


def test_read_job_malformed_json(monkeypatch):
    import io as _io

    monkeypatch.setattr(ww.sys, "__stdin__", _io.StringIO("{malformed"))
    with pytest.raises(ww.BadJob, match="could not be read"):
        ww.read_job()


# ---------------------------------------------------------------------------
# transcribe() arguments — CLI equivalence
# ---------------------------------------------------------------------------


def test_the_cli_parity_defaults_are_applied(tmp_path):
    """Without beam_size/best_of the output differs from the CLI's (a Phase 1 finding)."""
    job = ww.validate_job(_job(tmp_path, language="tr"))
    kwargs = ww.build_transcribe_kwargs(job)

    assert kwargs["beam_size"] == 5
    assert kwargs["best_of"] == 5
    assert kwargs["temperature"] == (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)
    assert kwargs["verbose"] is True
    assert kwargs["task"] == "transcribe"
    assert kwargs["language"] == "tr"


def test_language_is_not_passed_when_unspecified(tmp_path):
    job = ww.validate_job(_job(tmp_path))
    assert "language" not in ww.build_transcribe_kwargs(job)


def test_a_user_option_overrides_the_parity_default(tmp_path):
    job = ww.validate_job(_job(tmp_path, options={"beam_size": 1}))
    assert ww.build_transcribe_kwargs(job)["beam_size"] == 1


def test_an_explicit_null_removes_the_default(tmp_path):
    """null = "use whisper's own default" — it removes the parity value too."""
    job = ww.validate_job(_job(tmp_path, options={"beam_size": None}))
    assert "beam_size" not in ww.build_transcribe_kwargs(job)


def test_a_temperature_list_becomes_a_tuple(tmp_path):
    job = ww.validate_job(_job(tmp_path, options={"temperature": [0.0, 0.5]}))
    assert ww.build_transcribe_kwargs(job)["temperature"] == (0.0, 0.5)


def test_an_unknown_option_is_not_passed(tmp_path):
    job = ww.validate_job(_job(tmp_path, options={"made_up_option": 3}))
    assert "made_up_option" not in ww.build_transcribe_kwargs(job)


# ---------------------------------------------------------------------------
# The progress hook
# ---------------------------------------------------------------------------


class _FakeTqdm:
    """The part of tqdm's surface that is enough for the test."""

    def __init__(self, *_args, **kwargs):
        self.total = kwargs.get("total")
        self.n = 0

    def update(self, n=1):
        self.n += n

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False


def test_the_progress_hook_counts_cumulatively():
    seen = []
    ww._set_progress_sink(lambda done, total: seen.append((done, total)))

    cls = ww._make_progress_tqdm(_FakeTqdm)
    bar = cls(total=100)
    bar.update(30)
    bar.update(20)

    assert seen == [(30, 100), (50, 100)]


def test_the_progress_hook_catches_cancellation():
    cls = ww._make_progress_tqdm(_FakeTqdm)
    bar = cls(total=10)
    ww._cancelled = True

    with pytest.raises(ww.WorkerCancelled):
        bar.update(1)


def test_frame_to_second_conversion():
    # whisper: HOP_LENGTH=160, SAMPLE_RATE=16000 -> 100 frames = 1 second
    assert ww._frames_to_seconds(3000) == pytest.approx(30.0)


# ---------------------------------------------------------------------------
# main()'s error mapping
# ---------------------------------------------------------------------------


def test_an_invalid_mode_is_bad_usage(events):
    assert ww.main(["whisper_worker.py", "summarise"]) == 1
    error = events.one("error")
    assert error["code"] == "BAD_USAGE"
    assert "summarise" in error["detail"]


def test_download_mode_is_a_valid_mode(events, monkeypatch, tmp_path):
    """`download` fetches one model on its own — ADR-019. It introduces no event type of its
    own: the status and progress events are a transcription's, and success is a clean exit."""
    calls = {}

    class FakeWhisper:
        _MODELS: ClassVar[dict] = {"small": "https://example.invalid/small.pt"}
        tqdm = object

        class version:
            __version__ = "20250625"

        @staticmethod
        def available_models():
            return ["small", "medium"]

        @staticmethod
        def _download(url, root, in_memory):
            calls["url"] = url
            calls["root"] = root
            return str(pathlib.Path(root) / "small.pt")

    monkeypatch.setitem(ww.sys.modules, "whisper", FakeWhisper)
    monkeypatch.setattr(ww, "_make_progress_tqdm", lambda base: base)
    monkeypatch.setattr(
        ww.sys, "__stdin__", io.StringIO(json.dumps({"model": "small", "model_dir": str(tmp_path)}))
    )

    assert ww.main(["whisper_worker.py", "download"]) == 0
    assert calls["root"] == str(tmp_path)
    assert calls["url"] == "https://example.invalid/small.pt"
    assert [e["type"] for e in events.all] == ["hello", "status", "log"]
    assert events.one("status")["phase"] == "downloading_model"


def test_download_mode_refuses_an_unknown_model(events, monkeypatch, tmp_path):
    class FakeWhisper:
        _MODELS: ClassVar[dict] = {}
        tqdm = object

        class version:
            __version__ = "20250625"

        @staticmethod
        def available_models():
            return ["small"]

    monkeypatch.setitem(ww.sys.modules, "whisper", FakeWhisper)
    monkeypatch.setattr(
        ww.sys, "__stdin__", io.StringIO(json.dumps({"model": "nope", "model_dir": str(tmp_path)}))
    )

    assert ww.main(["whisper_worker.py", "download"]) == 1
    assert events.one("error")["code"] == "BAD_JOB"


def test_download_mode_needs_a_model_name(events, monkeypatch):
    monkeypatch.setattr(ww.sys, "__stdin__", io.StringIO(json.dumps({"model": ""})))
    assert ww.main(["whisper_worker.py", "download"]) == 1
    assert events.one("error")["code"] == "BAD_JOB"


def test_download_progress_is_throttled_to_whole_percents():
    """whisper reads in 8 KB chunks: unthrottled, `tiny` emits about 9 000 events and
    `large-v3` roughly 375 000 (ADR-019)."""
    seen = []
    sink = ww._download_progress_sink()
    original_emit = ww.emit
    try:
        ww.emit = lambda event: seen.append(event)
        total = 8192 * 1000
        for i in range(1, 1001):
            sink(8192 * i, total)
    finally:
        ww.emit = original_emit

    # One per whole percent, never more, and the last one always lands on 100.
    assert len(seen) <= 101, len(seen)
    assert seen[-1]["pct"] == 100.0
    assert seen[-1]["processed"] == total
    assert all(e["phase"] == "downloading_model" for e in seen)


def test_download_progress_reports_an_unknown_total():
    seen = []
    sink = ww._download_progress_sink()
    original_emit = ww.emit
    try:
        ww.emit = lambda event: seen.append(event)
        sink(1024, None)
    finally:
        ww.emit = original_emit

    assert seen[0]["pct"] is None
    assert seen[0]["total"] is None


def test_running_without_a_mode_is_bad_usage(events):
    assert ww.main(["whisper_worker.py"]) == 1
    assert events.one("error")["code"] == "BAD_USAGE"


def test_a_worker_error_is_turned_into_an_event(events, monkeypatch):
    def patlat():
        raise ww.ModelDownloadFailed("The model could not be downloaded.", "no network")

    monkeypatch.setattr(ww, "cmd_transcribe", patlat)
    monkeypatch.setattr(ww, "install_log_shims", lambda: None)

    assert ww.main(["whisper_worker.py", "transcribe"]) == 1
    error = events.one("error")
    assert error["code"] == "MODEL_DOWNLOAD_FAILED"
    assert error["recoverable"] is True
    assert error["detail"] == "no network"


def test_an_unexpected_error_becomes_internal_error(events, monkeypatch):
    def patlat():
        raise ZeroDivisionError("division by zero")

    monkeypatch.setattr(ww, "cmd_transcribe", patlat)
    monkeypatch.setattr(ww, "install_log_shims", lambda: None)

    assert ww.main(["whisper_worker.py", "transcribe"]) == 1
    error = events.one("error")
    assert error["code"] == "INTERNAL_ERROR"
    assert "ZeroDivisionError" in error["detail"], "the trace must be carried through for diagnosis"


def test_cancellation_ends_with_the_cancelled_code(events, monkeypatch):
    def patlat():
        raise ww.WorkerCancelled()

    monkeypatch.setattr(ww, "cmd_transcribe", patlat)
    monkeypatch.setattr(ww, "install_log_shims", lambda: None)

    assert ww.main(["whisper_worker.py", "transcribe"]) == 1
    assert events.one("error")["code"] == "CANCELLED"


# ---------------------------------------------------------------------------
# Writing the output
# ---------------------------------------------------------------------------


def test_output_is_written_atomically_and_leaves_no_temp_dir(tmp_path, monkeypatch):
    job = ww.validate_job(_job(tmp_path, output_formats=["txt"]))

    def fake_get_writer(fmt, output_dir):
        def writer(result, audio_path, **_kwargs):
            stem = ww.os.path.splitext(ww.os.path.basename(audio_path))[0]
            with open(ww.os.path.join(output_dir, f"{stem}.{fmt}"), "w") as handle:
                handle.write(result["text"])

        return writer

    monkeypatch.setitem(ww.sys.modules, "whisper.utils", type("M", (), {"get_writer": fake_get_writer}))

    outputs = ww.write_outputs(job, {"text": "hello"})

    assert outputs == [{"format": "txt", "path": str(tmp_path / "audio.txt"), "bytes": 5}]
    assert (tmp_path / "audio.txt").read_text() == "hello"
    leftovers = [p.name for p in tmp_path.iterdir() if p.name.startswith(".whisper-tmp-")]
    assert leftovers == [], "the temporary directory must be cleaned up"


def test_a_write_error_leaves_no_half_file_at_the_target(tmp_path, monkeypatch):
    job = ww.validate_job(_job(tmp_path, output_formats=["txt", "srt"]))

    def fake_get_writer(fmt, output_dir):
        def writer(result, audio_path, **_kwargs):
            if fmt == "srt":
                raise RuntimeError("the writer blew up")
            stem = ww.os.path.splitext(ww.os.path.basename(audio_path))[0]
            with open(ww.os.path.join(output_dir, f"{stem}.{fmt}"), "w") as handle:
                handle.write(result["text"])

        return writer

    monkeypatch.setitem(ww.sys.modules, "whisper.utils", type("M", (), {"get_writer": fake_get_writer}))

    with pytest.raises(RuntimeError):
        ww.write_outputs(job, {"text": "hello"})

    assert not (tmp_path / "audio.srt").exists()
    assert [p.name for p in tmp_path.iterdir() if p.name.startswith(".whisper-tmp-")] == []


# ---------------------------------------------------------------------------
# Audio decoding
# ---------------------------------------------------------------------------


def test_audio_decoding_classifies_an_ffmpeg_error(tmp_path, monkeypatch):
    def fake_run(*_args, **_kwargs):
        return type("P", (), {"returncode": 1, "stdout": b"", "stderr": b"Invalid data found"})

    monkeypatch.setattr(ww.subprocess, "run", fake_run)

    with pytest.raises(ww.AudioDecodeFailed, match="could not be decoded"):
        ww.decode_audio(str(tmp_path / "x.m4a"), "/bin/false")


def test_audio_decoding_passes_the_thread_limit_to_ffmpeg(tmp_path, monkeypatch):
    """The CPU limit has to reach ffmpeg too: decoding a long file is the other place the
    machine stalls (ADR-018). ffmpeg's own default, -threads 0, means every core."""
    seen = {}

    def fake_run(cmd, **_kwargs):
        seen["cmd"] = cmd
        return type("P", (), {"returncode": 0, "stdout": b"\x00\x01" * 100, "stderr": b""})

    monkeypatch.setattr(ww.subprocess, "run", fake_run)
    ww.decode_audio(str(tmp_path / "x.m4a"), "/bin/true", threads=3)

    cmd = seen["cmd"]
    assert cmd[cmd.index("-threads") + 1] == "3"


def test_audio_decoding_leaves_ffmpeg_unlimited_without_a_limit(tmp_path, monkeypatch):
    seen = {}

    def fake_run(cmd, **_kwargs):
        seen["cmd"] = cmd
        return type("P", (), {"returncode": 0, "stdout": b"\x00\x01" * 100, "stderr": b""})

    monkeypatch.setattr(ww.subprocess, "run", fake_run)
    ww.decode_audio(str(tmp_path / "x.m4a"), "/bin/true")

    cmd = seen["cmd"]
    assert cmd[cmd.index("-threads") + 1] == "0"


def test_audio_decoding_catches_empty_output(tmp_path, monkeypatch):
    def fake_run(*_args, **_kwargs):
        return type("P", (), {"returncode": 0, "stdout": b"", "stderr": b""})

    monkeypatch.setattr(ww.subprocess, "run", fake_run)

    with pytest.raises(ww.AudioDecodeFailed, match="audio stream"):
        ww.decode_audio(str(tmp_path / "x.m4a"), "/bin/true")


def test_an_error_event_is_json_serialisable(events, monkeypatch):
    """Error details contain user data; the NDJSON mustn't be corrupted."""

    def patlat():
        raise ww.BadJob("Failure.", 'path: /tmp/"quoted"\nand a newline')

    monkeypatch.setattr(ww, "cmd_transcribe", patlat)
    monkeypatch.setattr(ww, "install_log_shims", lambda: None)
    ww.main(["whisper_worker.py", "transcribe"])

    assert len(events.raw.strip().splitlines()) == 1
    assert json.loads(events.raw)["code"] == "BAD_JOB"


# ---------------------------------------------------------------------------
# capabilities
# ---------------------------------------------------------------------------


@pytest.fixture
def fake_whisper(tmp_path, monkeypatch):
    """Fakes `whisper` and points the model folder at tmp_path.

    Importing the real whisper loads torch as well (~9 s); the capability-discovery logic
    doesn't need that.
    """
    import sys
    import types

    models = tmp_path / "models"
    models.mkdir()

    module = types.ModuleType("whisper")
    module.available_models = lambda: ["tiny", "small", "medium"]
    module.version = types.SimpleNamespace(__version__="20250625")
    tokenizer = types.ModuleType("whisper.tokenizer")
    tokenizer.LANGUAGES = {"tr": "turkish", "en": "english"}

    monkeypatch.setitem(sys.modules, "whisper", module)
    monkeypatch.setitem(sys.modules, "whisper.tokenizer", tokenizer)
    monkeypatch.setattr(ww, "default_model_dir", lambda: str(models))
    monkeypatch.setattr(ww, "_torch_version", lambda: "2.14.1")
    monkeypatch.setattr(ww, "_ffmpeg_version", lambda: "7.1")
    monkeypatch.setattr(ww, "_mps_available", lambda: False)
    return models


def test_capabilities_reports_the_size_of_a_downloaded_model(fake_whisper, events):
    (fake_whisper / "small.pt").write_bytes(b"x" * 1234)

    assert ww.cmd_capabilities() == 0

    caps = events.one("capabilities")
    assert caps["models_cached"] == ["small"]
    assert caps["models_bytes"] == {"small": 1234}
    # The size of a model that hasn't been downloaded is unknown; it isn't invented.
    assert "medium" not in caps["models_bytes"]


def test_capabilities_ignores_an_unrecognised_pt_file(fake_whisper, events):
    (fake_whisper / "small.pt").write_bytes(b"x" * 10)
    (fake_whisper / "unknown-model.pt").write_bytes(b"y" * 10)
    (fake_whisper / "notes.txt").write_text("not a model")

    assert ww.cmd_capabilities() == 0

    caps = events.one("capabilities")
    assert caps["models_cached"] == ["small"]
    assert list(caps["models_bytes"]) == ["small"]


def test_capabilities_empty_model_folder(fake_whisper, events):
    assert ww.cmd_capabilities() == 0

    caps = events.one("capabilities")
    assert caps["models_cached"] == []
    assert caps["models_bytes"] == {}
    # The list still comes from whisper; it isn't hard-coded.
    assert caps["models"] == ["tiny", "small", "medium"]
    assert caps["devices"] == ["cpu"]


# ---------------------------------------------------------------------------
# the notes format (ADR-014)
# ---------------------------------------------------------------------------


def test_format_extension_differs_only_for_notes():
    assert ww.format_extension("notes") == "md"
    for fmt in ("txt", "srt", "vtt", "tsv", "json"):
        assert ww.format_extension(fmt) == fmt


@pytest.mark.parametrize(
    "seconds,expected",
    [(0, "00:00"), (7.9, "00:07"), (62, "01:02"), (252.4, "04:12"), (3912, "1:05:12")],
)
def test_clock_format(seconds, expected):
    assert ww.clock(seconds) == expected


def test_write_notes_produces_timestamped_bullets():
    import io

    buffer = io.StringIO()
    ww.write_notes(
        {
            "segments": [
                {"start": 0.0, "text": " Today the main topic was the budget lines."},
                {"start": 19.2, "text": " Alex objected to it."},
            ]
        },
        buffer,
    )

    assert buffer.getvalue() == (
        "- [00:00] Today the main topic was the budget lines.\n- [00:19] Alex objected to it.\n"
    )


def test_write_notes_skips_an_empty_segment():
    import io

    buffer = io.StringIO()
    # whisper can emit segments with empty text during silence; no empty bullets.
    ww.write_notes({"segments": [{"start": 1.0, "text": "   "}, {"start": 2.0, "text": "var"}]}, buffer)

    assert buffer.getvalue() == "- [00:02] var\n"


def test_write_notes_writes_an_empty_file_with_no_segments():
    import io

    buffer = io.StringIO()
    ww.write_notes({}, buffer)
    assert buffer.getvalue() == ""


def test_the_notes_format_is_written_with_an_md_extension(tmp_path):
    source = tmp_path / "meeting.m4a"
    source.write_bytes(b"x")
    job = {
        "input_path": str(source),
        "output_dir": str(tmp_path),
        "output_formats": ["notes"],
        "writer_options": {},
    }

    outputs = ww.write_outputs(job, {"segments": [{"start": 5.0, "text": "hello"}]})

    assert [o["format"] for o in outputs] == ["notes"]
    target = tmp_path / "meeting.md"
    assert target.exists()
    assert target.read_text(encoding="utf-8") == "- [00:05] hello\n"
    # No temporary directory should be left behind.
    assert [p.name for p in tmp_path.iterdir() if p.name.startswith(".whisper-tmp-")] == []


def test_the_notes_format_is_written_without_loading_whisper(tmp_path, monkeypatch):
    """A job asking only for notes must never touch whisper.utils."""
    import sys

    def patlat(*_a, **_k):
        raise AssertionError("whisper.utils should not have been loaded")

    monkeypatch.setitem(sys.modules, "whisper.utils", type("M", (), {"get_writer": patlat}))

    source = tmp_path / "a.m4a"
    source.write_bytes(b"x")
    ww.write_outputs(
        {
            "input_path": str(source),
            "output_dir": str(tmp_path),
            "output_formats": ["notes"],
            "writer_options": {},
        },
        {"segments": [{"start": 0.0, "text": "okay"}]},
    )
    assert (tmp_path / "a.md").read_text(encoding="utf-8") == "- [00:00] okay\n"


def test_validate_job_accepts_the_notes_format(tmp_path):
    source = tmp_path / "a.m4a"
    source.write_bytes(b"x")
    job = ww.validate_job({"input_path": str(source), "output_formats": ["notes", "txt"]})

    assert job["output_formats"] == ["notes", "txt"]
    assert ww.expected_outputs(job) == {
        "notes": str(tmp_path / "a.md"),
        "txt": str(tmp_path / "a.txt"),
    }


# ---------------------------------------------------------------------------
# stream — live mode (docs/LIVE_TRANSCRIPTION.md)
# ---------------------------------------------------------------------------


def _audio_line(samples: int, amplitude: int = 4000) -> str:
    import base64
    import json as _json

    import numpy as np

    pcm = (np.ones(samples, dtype=np.int16) * amplitude).tobytes()
    return _json.dumps({"v": 2, "type": "audio", "pcm": base64.b64encode(pcm).decode()})


def _silence_line(samples: int) -> str:
    return _audio_line(samples, amplitude=0)


class _PacedStream:
    """A fake stdin that hands over its lines with a pause between them.

    `io.StringIO` is exhausted instantly, and then the reader says "finished" on the very
    first round and the stream commits in a single call. To measure the behaviours that
    need several ticks (provisional text, carrying context over), the audio has to arrive
    in pieces the way it does in real life.
    """

    def __init__(self, lines: list[str], gap: float = 0.4) -> None:
        self._lines = lines
        self._gap = gap

    def __iter__(self):
        for index, line in enumerate(self._lines):
            if index:
                time.sleep(self._gap)
            yield line + "\n"

    def readline(self) -> str:
        return self._lines.pop(0) + "\n" if self._lines else ""


@pytest.fixture
def stream_whisper(monkeypatch):
    """Fakes whisper so the test decides what `transcribe` returns."""
    import sys
    import types

    responses: list[dict] = []
    calls: list[dict] = []

    def transcribe(model, audio, **kwargs):
        calls.append({"samples": len(audio), "kwargs": kwargs})
        return responses.pop(0) if responses else {"segments": [], "text": ""}

    module = types.ModuleType("whisper")
    module.version = types.SimpleNamespace(__version__="20250625")
    module.transcribe = transcribe
    monkeypatch.setitem(sys.modules, "whisper", module)
    monkeypatch.setattr(ww, "load_model", lambda job: object())
    monkeypatch.setattr(ww, "_torch_version", lambda: "2.14.1")
    monkeypatch.setattr(ww, "_mps_available", lambda: False)

    class Harness:
        def __init__(self):
            self.responses = responses
            self.calls = calls

        def run(self, lines: list[str]) -> int:
            config = json.dumps({"v": 2, "job_id": "t", "model": "small", "language": "tr"})
            monkeypatch.setattr(ww.sys, "__stdin__", io.StringIO("\n".join([config, *lines]) + "\n"))
            return ww.cmd_stream()

        def run_paced(self, lines: list[str], gap: float = 0.4) -> int:
            config = json.dumps({"v": 2, "job_id": "t", "model": "small", "language": "tr"})
            monkeypatch.setattr(ww.sys, "__stdin__", _PacedStream([config, *lines], gap=gap))
            return ww.cmd_stream()

    return Harness()


def test_stream_commits_segments_and_shifts_the_times(stream_whisper, events):
    # A stream that finishes in one round: every segment commits.
    stream_whisper.responses.append(
        {
            "segments": [
                {"start": 0.0, "end": 2.0, "text": " Hello."},
                {"start": 2.0, "end": 4.0, "text": " Second sentence."},
            ],
            "text": "Hello. Second sentence.",
        }
    )

    assert stream_whisper.run([_audio_line(16000 * 4), json.dumps({"type": "stop"})]) == 0

    committed = events.of("committed")
    assert [e["text"] for e in committed] == ["Hello.", "Second sentence."]
    assert [(e["start"], e["end"]) for e in committed] == [(0.0, 2.0), (2.0, 4.0)]

    result = events.one("result")
    assert result["segment_count"] == 2
    assert result["text"] == "Hello. Second sentence."


def test_stream_events_carry_v2(stream_whisper, events):
    stream_whisper.responses.append({"segments": [], "text": ""})
    stream_whisper.run([_audio_line(16000 * 2), json.dumps({"type": "stop"})])

    # Live mode carries its own protocol version; batch stays v1.
    assert {e["v"] for e in events.all} == {2}
    assert events.one("hello")["mode"] == "stream"


def test_stream_skips_digital_silence_without_decoding(stream_whisper, events):
    """10 s of zeros produces severe hallucination with the small model (measured)."""
    stream_whisper.run([_silence_line(16000 * 10), json.dumps({"type": "stop"})])

    assert stream_whisper.calls == [], "whisper must not be called for silence"
    assert events.of("committed") == []
    assert events.one("result")["text"] == ""


def test_stream_partial_text_carries_everything_uncommitted(stream_whisper, events):
    """Sending only the last segment lost the ones in the middle from the screen."""
    # First round: three segments, the last two near the end of the buffer → not committed.
    stream_whisper.responses.append(
        {
            "segments": [
                {"start": 0.0, "end": 2.0, "text": " Bir."},
                {"start": 2.0, "end": 5.5, "text": " Two."},
                {"start": 5.5, "end": 6.0, "text": " Three."},
            ],
            "text": "",
        }
    )
    stream_whisper.responses.append({"segments": [], "text": ""})

    stream_whisper.run_paced([_audio_line(16000 * 6), _audio_line(16000 * 2), json.dumps({"type": "stop"})])

    partials = [e["text"] for e in events.of("partial")]
    assert partials, "provisional text must be produced"
    assert "Two." in partials[0] and "Three." in partials[0]


def test_stream_carries_the_context_into_the_next_call(stream_whisper, events):
    stream_whisper.responses.append(
        {"segments": [{"start": 0.0, "end": 2.0, "text": " John Smith."}], "text": ""}
    )
    stream_whisper.responses.append({"segments": [], "text": ""})

    stream_whisper.run_paced([_audio_line(16000 * 4), _audio_line(16000 * 2), json.dumps({"type": "stop"})])

    # The second call must receive the committed text as initial_prompt.
    assert len(stream_whisper.calls) >= 2
    assert stream_whisper.calls[1]["kwargs"].get("initial_prompt") == "John Smith."


def test_stream_uses_greedy_decoding(stream_whisper, events):
    """The live preview can't use beam search: a 30 s buffer takes 6.79 s."""
    stream_whisper.responses.append({"segments": [], "text": ""})
    stream_whisper.run([_audio_line(16000 * 2), json.dumps({"type": "stop"})])

    kwargs = stream_whisper.calls[0]["kwargs"]
    assert kwargs["beam_size"] is None
    assert kwargs["best_of"] is None
    assert kwargs["temperature"] == 0.0


def test_stream_reader_ignores_a_malformed_line():
    reader = ww.StreamReader(io.StringIO("{malformed\n" + _audio_line(1600) + "\n"))
    reader.run()

    assert reader.decode_errors == 1
    assert reader.drain().size == 1600
    assert reader.finished


def test_stream_reader_stops_reading_after_stop():
    lines = [_audio_line(800), json.dumps({"type": "stop"}), _audio_line(800)]
    reader = ww.StreamReader(io.StringIO("\n".join(lines) + "\n"))
    reader.run()

    # Audio arriving after stop is not taken.
    assert reader.drain().size == 800
