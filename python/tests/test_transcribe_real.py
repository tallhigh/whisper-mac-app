"""Real transcription tests — they load the model and are slow.

To run them: pytest -m slow
The default `make test-python` skips them.

The main test here pins the project's core correctness claim: the output the worker
produces must be byte-for-byte identical to what the `whisper` CLI command the user runs
today produces. If this test breaks when the whisper version is upgraded, the output has
changed and a deliberate decision is needed.
"""

import base64
import itertools
import json
import os
import pathlib
import subprocess
import sys
import threading
import time

import numpy as np
import pytest
from conftest import requires_fixture

import whisper_worker as ww

WORKER = pathlib.Path(__file__).resolve().parents[1] / "whisper_worker.py"
MODEL = "small"
LANGUAGE = "tr"

pytestmark = pytest.mark.slow


def _run_worker(job: dict) -> list[dict]:
    proc = subprocess.run(
        [sys.executable, str(WORKER), "transcribe"],
        input=json.dumps(job),
        capture_output=True,
        text=True,
        check=False,
    )
    events = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
    assert events, f"no events produced. stderr: {proc.stderr[-500:]}"
    return events


def _model_cached() -> bool:
    model_dir = pathlib.Path(os.path.expanduser("~")) / ".cache" / "whisper"
    return (model_dir / f"{MODEL}.pt").exists()


@pytest.fixture(scope="module", autouse=True)
def skip_without_model():
    if not _model_cached():
        pytest.skip(f"the {MODEL} model is not in ~/.cache/whisper; the test uses no network")


def test_output_is_identical_to_the_cli(tmp_path):
    """The worker's output == `whisper ... --model small --output_format txt`'s output.

    If they differ, the first place to look is whisper_worker._CLI_PARITY_DEFAULTS: the CLI
    does beam search with beam_size/best_of=5, while the library does greedy decoding.
    """
    audio = requires_fixture("speech.m4a")

    worker_dir = tmp_path / "worker"
    events = _run_worker(
        {
            "v": 1,
            "job_id": "parity",
            "input_path": str(audio),
            "output_dir": str(worker_dir),
            "output_formats": ["txt"],
            "model": MODEL,
            "language": LANGUAGE,
            "task": "transcribe",
            "device": "cpu",
        }
    )
    assert [e for e in events if e["type"] == "error"] == []

    cli_dir = tmp_path / "cli"
    cli_dir.mkdir()
    whisper_cli = pathlib.Path(sys.executable).parent / "whisper"
    subprocess.run(
        [
            str(whisper_cli),
            str(audio),
            "--language",
            "Turkish",
            "--task",
            "transcribe",
            "--model",
            MODEL,
            "--output_format",
            "txt",
            "--output_dir",
            str(cli_dir),
        ],
        capture_output=True,
        check=True,
    )

    worker_txt = (worker_dir / "speech.txt").read_text()
    cli_txt = (cli_dir / "speech.txt").read_text()
    assert worker_txt == cli_txt


def test_a_thread_limit_does_not_change_the_output(tmp_path):
    """The CPU limit must not cost correctness.

    Limiting torch's threads changes the order floating-point reductions happen in, so it
    could in principle flip a token and break the CLI equivalence above. Measured before the
    setting was shipped: the same fixture gave a byte-identical .txt at 2, 3, 4 and unlimited
    threads (ADR-018). This pins the two the app actually sends.
    """
    audio = requires_fixture("speech.m4a")
    produced = {}

    for label, threads in [("unlimited", 0), ("limited", 2)]:
        out = tmp_path / label
        out.mkdir()
        events = _run_worker(
            {
                "v": 1,
                "job_id": label,
                "input_path": str(audio),
                "output_dir": str(out),
                "output_formats": ["txt"],
                "model": MODEL,
                "model_dir": str(pathlib.Path(os.path.expanduser("~")) / ".cache" / "whisper"),
                "language": LANGUAGE,
                "task": "transcribe",
                "device": "cpu",
                "options": {"threads": threads},
                "writer_options": {},
                "overwrite": True,
                "emit_segments": False,
            }
        )
        assert not [e for e in events if e["type"] == "error"], events[-1]
        produced[label] = (out / "speech.txt").read_bytes()

    assert produced["limited"] == produced["unlimited"], (
        "a thread limit changed the transcript, which breaks CLI equivalence"
    )


def test_event_order_honours_the_contract(tmp_path):
    audio = requires_fixture("speech.m4a")
    events = _run_worker(
        {
            "v": 1,
            "job_id": "order",
            "input_path": str(audio),
            "output_dir": str(tmp_path),
            "output_formats": ["txt", "srt"],
            "model": MODEL,
            "language": LANGUAGE,
            "emit_segments": True,
        }
    )
    types = [e["type"] for e in events]

    assert types[0] == "hello", "hello is always the first event"
    assert types[-1] == "result", "on success the last event is result"
    assert "segment" in types and "progress" in types

    phases = [e["phase"] for e in events if e["type"] == "status"]
    assert phases == [
        "decoding_audio",
        "audio_ready",
        "loading_model",
        "transcribing",
        "writing_output",
    ]

    result = events[-1]
    assert result["language"] == LANGUAGE
    assert result["duration"] == pytest.approx(24.4, abs=0.2)
    assert {o["format"] for o in result["outputs"]} == {"txt", "srt"}
    assert all(pathlib.Path(o["path"]).exists() for o in result["outputs"])
    assert result["segment_count"] > 0

    # The live segment count and the final one have to agree.
    assert len([e for e in events if e["type"] == "segment"]) == result["segment_count"]


def test_segment_events_have_increasing_times(tmp_path):
    audio = requires_fixture("speech.m4a")
    events = _run_worker(
        {
            "v": 1,
            "input_path": str(audio),
            "output_dir": str(tmp_path),
            "output_formats": ["txt"],
            "model": MODEL,
            "language": LANGUAGE,
        }
    )
    segments = [e for e in events if e["type"] == "segment"]

    assert [s["id"] for s in segments] == list(range(len(segments)))
    assert all(s["end"] >= s["start"] for s in segments)
    assert all(b["start"] >= a["start"] for a, b in itertools.pairwise(segments))
    # The separator space must be consumed and whisper's own leading space preserved.
    assert not segments[0]["text"].startswith("  ")


def test_unicode_file_name(tmp_path):
    audio = requires_fixture("SAMPLE recording 🎙 şçğü.m4a")
    events = _run_worker(
        {
            "v": 1,
            "input_path": str(audio),
            "output_dir": str(tmp_path),
            "output_formats": ["txt"],
            "model": MODEL,
            "language": LANGUAGE,
        }
    )
    result = events[-1]
    assert result["type"] == "result"
    assert pathlib.Path(result["outputs"][0]["path"]).exists()
    assert "🎙" in result["outputs"][0]["path"]


def test_a_corrupt_file_does_not_stop_the_queue(tmp_path):
    audio = requires_fixture("corrupt.m4a")
    events = _run_worker(
        {
            "v": 1,
            "input_path": str(audio),
            "output_dir": str(tmp_path),
            "output_formats": ["txt"],
            "model": MODEL,
            "language": LANGUAGE,
        }
    )
    error = events[-1]
    assert error["type"] == "error"
    assert error["code"] == "AUDIO_DECODE_FAILED"
    assert list(tmp_path.iterdir()) == [], "no file must be written on failure"


def test_notes_format_produces_timestamps_from_real_audio(tmp_path):
    """The notes output gives txt's lines as timestamped bullets.

    Because both formats are written from the same `result` dictionary, the text has to be
    identical; the only difference is the `- [MM:SS] ` prefix.
    """
    audio = requires_fixture("speech.m4a")

    events = _run_worker(
        {
            "v": 1,
            "job_id": "notes",
            "input_path": str(audio),
            "output_dir": str(tmp_path),
            "output_formats": ["txt", "notes"],
            "model": MODEL,
            "language": LANGUAGE,
            "task": "transcribe",
            "device": "cpu",
        }
    )
    assert [e for e in events if e["type"] == "error"] == []

    result = next(e for e in events if e["type"] == "result")
    assert {o["format"] for o in result["outputs"]} == {"txt", "notes"}
    notes_path = next(o["path"] for o in result["outputs"] if o["format"] == "notes")
    assert notes_path.endswith("speech.md")

    txt_lines = [line for line in (tmp_path / "speech.txt").read_text().splitlines() if line.strip()]
    note_lines = (tmp_path / "speech.md").read_text().splitlines()

    assert note_lines, "the note file must not be empty"
    assert len(note_lines) == len(txt_lines)
    for note, text in zip(note_lines, txt_lines, strict=True):
        assert note.startswith("- [")
        stamp, _, body = note[2:].partition("] ")
        assert body == text.strip()
        # The timestamp is MM:SS or H:MM:SS
        assert all(part.isdigit() for part in stamp.lstrip("[").split(":"))


def test_live_mode_produces_committed_text_from_real_audio(tmp_path):
    """Live mode turns real audio fed in from a file into text without a break.

    **Byte-for-byte** equality with the batch output is not expected: the live side decodes
    greedily, the batch side with beam search (docs/LIVE_TRANSCRIPTION.md → the two-pass
    design). What is looked for here is that the text agrees in meaning and that the
    timeline is consistent.
    """
    audio = ww.decode_audio(str(requires_fixture("speech.m4a")), ww.find_ffmpeg())
    pcm = (np.clip(audio, -1, 1) * 32767).astype(np.int16)

    proc = subprocess.Popen(
        [sys.executable, str(WORKER), "stream"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    events: list[dict] = []

    def read() -> None:
        for line in proc.stdout:
            if line.strip():
                events.append(json.loads(line))

    reader = threading.Thread(target=read, daemon=True)
    reader.start()

    config = {
        "v": 2,
        "job_id": "live",
        "model": MODEL,
        "language": LANGUAGE,
        "task": "transcribe",
        "device": "cpu",
    }
    proc.stdin.write(json.dumps(config) + "\n")
    proc.stdin.flush()

    # 200 ms chunks at four times real-time speed: the streaming logic gets exercised
    # without the test taking 25 seconds.
    chunk = 3200
    for start in range(0, len(pcm), chunk):
        block = pcm[start : start + chunk]
        proc.stdin.write(
            json.dumps(
                {
                    "v": 2,
                    "type": "audio",
                    "pcm": base64.b64encode(block.tobytes()).decode(),
                }
            )
            + "\n"
        )
        proc.stdin.flush()
        time.sleep((chunk / 16000) / 4)

    proc.stdin.write(json.dumps({"v": 2, "type": "stop"}) + "\n")
    proc.stdin.flush()
    proc.stdin.close()
    proc.wait(timeout=180)
    reader.join(timeout=10)

    assert [e for e in events if e["type"] == "error"] == []
    assert all(e["v"] == 2 for e in events), "live mode events must carry v2"

    committed = [e for e in events if e["type"] == "committed"]
    assert committed, "no committed text arrived"

    # The timeline increases without gaps: each segment starts where the previous one ended.
    for previous, current in itertools.pairwise(committed):
        assert current["start"] >= previous["start"]
        assert current["start"] == pytest.approx(previous["end"], abs=0.05)

    result = next(e for e in events if e["type"] == "result")
    assert result["segment_count"] == len(committed)

    text = result["text"].lower()
    # The distinctive words in the fixture must appear in the live output too.
    for word in ("merhaba", "bütçe", "toplantı", "lisans"):
        assert word in text, f"{word!r} is missing from the live text: {text[:200]}"
