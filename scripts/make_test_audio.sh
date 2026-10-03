#!/usr/bin/env bash
# Generates reproducible test audio files (macOS TTS + ffmpeg).
# The generated files are not committed; the reference text lives in this script.
# The spoken text stays Turkish on purpose — it is the fixture the tests transcribe.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/python/tests/fixtures"
RUNTIME="$HOME/Library/Application Support/WhisperTranscriber/runtime"
FFMPEG="$RUNTIME/bin/ffmpeg"
mkdir -p "$OUT"

TEXT="Merhaba, bu bir test kaydıdır. Bugünkü toplantının ana konusu bütçe kalemleriydi.
Üç ayrı başlık üzerinde konuştuk: personel giderleri, yazılım lisansları ve pazarlama bütçesi.
Toplantı sonunda, yazılım lisanslarının gözden geçirilmesine karar verildi.
Şırnak, Iğdır ve Çanakkale şubelerinden gelen raporlar da değerlendirildi."

echo "$TEXT" > "$OUT/speech.reference.txt"

# 1) An m4a with speech in it (the main acceptance-test file)
say -v Yelda -o "$OUT/speech.aiff" "$TEXT"
"$FFMPEG" -y -loglevel error -i "$OUT/speech.aiff" -c:a aac -b:a 64k "$OUT/speech.m4a"
"$FFMPEG" -y -loglevel error -i "$OUT/speech.aiff" -c:a libmp3lame -b:a 64k "$OUT/speech.mp3"
rm -f "$OUT/speech.aiff"

# 2) A file name with Turkish characters, spaces and an emoji (acceptance test #4)
cp "$OUT/speech.m4a" "$OUT/SAMPLE recording 🎙 şçğü.m4a"

# 3) A long recording (~3 min) — for the cancellation and progress-granularity tests
printf "file '%s'\n" "$OUT/speech.m4a" > "$OUT/.concat.txt"
for _ in $(seq 2 8); do printf "file '%s'\n" "$OUT/speech.m4a" >> "$OUT/.concat.txt"; done
"$FFMPEG" -y -loglevel error -f concat -safe 0 -i "$OUT/.concat.txt" -c:a aac -b:a 64k "$OUT/long.m4a"
rm -f "$OUT/.concat.txt"

# 4) A corrupt file (acceptance test #3)
head -c 4096 /dev/urandom > "$OUT/corrupt.m4a"

# 5) A zero-byte file (acceptance test #3)
: > "$OUT/empty.m4a"

echo "--- generated ---"
ls -lh "$OUT"
"$FFMPEG" -i "$OUT/speech.m4a" 2>&1 | grep -E "Duration|Audio:" || true
