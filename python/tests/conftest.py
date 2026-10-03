import io
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import whisper_worker as ww

FIXTURES = pathlib.Path(__file__).parent / "fixtures"


@pytest.fixture
def events(monkeypatch):
    """Collects the events emit() writes.

    The protocol channel is duplicated from fd 1 as the module loads; in the test we point
    it at a buffer, so pytest's own output capture doesn't interfere.
    """
    buffer = io.StringIO()
    monkeypatch.setattr(ww, "_proto", buffer)

    class Collected:
        @property
        def raw(self) -> str:
            return buffer.getvalue()

        @property
        def all(self) -> list[dict]:
            import json

            return [json.loads(line) for line in buffer.getvalue().splitlines() if line.strip()]

        def types(self) -> list[str]:
            return [e["type"] for e in self.all]

        def of(self, type_name: str) -> list[dict]:
            return [e for e in self.all if e["type"] == type_name]

        def one(self, type_name: str) -> dict:
            matches = self.of(type_name)
            assert len(matches) == 1, f"{type_name}: found {len(matches)}"
            return matches[0]

    return Collected()


@pytest.fixture(autouse=True)
def reset_cancel_flag():
    ww._cancelled = False
    ww._set_progress_sink(None)
    yield
    ww._cancelled = False
    ww._set_progress_sink(None)


def requires_fixture(name: str) -> pathlib.Path:
    path = FIXTURES / name
    if not path.exists():
        pytest.skip(f"fixture missing: {name} — run 'make fixtures'")
    return path
