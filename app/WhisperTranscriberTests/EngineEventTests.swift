import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("NDJSON event decoding")
struct EngineEventDecodingTests {

    @Test("hello")
    func hello() throws {
        let event = EngineEvent.decode(
            line: #"{"v":1,"type":"hello","worker":"0.1.0","python":"3.13.15","whisper":"20250625","torch":"2.14.1","ffmpeg":"7.1","device":"cpu","mps_available":true}"#
        )
        guard case .hello(let hello) = event else { Issue.record("expected hello"); return }

        #expect(hello.worker == "0.1.0")
        #expect(hello.whisper == "20250625")
        #expect(hello.mpsAvailable == true)
    }

    @Test("capabilities")
    func capabilities() throws {
        let event = EngineEvent.decode(
            line: #"{"v":1,"type":"capabilities","models":["tiny","small"],"models_cached":["small"],"model_dir":"/Users/t/.cache/whisper","languages":[{"code":"tr","name":"turkish"}],"output_formats":["txt","srt"],"tasks":["transcribe","translate"],"devices":["cpu","mps"]}"#
        )
        guard case .capabilities(let capabilities) = event else {
            Issue.record("expected capabilities")
            return
        }

        #expect(capabilities.models == ["tiny", "small"])
        #expect(capabilities.isCached("small"))
        #expect(!capabilities.isCached("tiny"))
        #expect(capabilities.supportsMPS)
        #expect(capabilities.languages.first?.code == "tr")
    }

    @Test("status and the phases")
    func status() throws {
        let event = EngineEvent.decode(line: #"{"v":1,"type":"status","phase":"audio_ready","duration":612.4}"#)
        guard case .status(let status) = event else { Issue.record("expected status"); return }

        #expect(status.phase == .audioReady)
        #expect(status.duration == 612.4)
        #expect(status.phase.title == "audio ready")
    }

    @Test("progress turns the percentage into a ratio")
    func progress() throws {
        let event = EngineEvent.decode(
            line: #"{"v":1,"type":"progress","phase":"transcribing","processed":182.0,"total":612.4,"pct":29.7}"#
        )
        guard case .progress(let progress) = event else { Issue.record("expected progress"); return }

        #expect(progress.fraction == 0.297)
        #expect(progress.processed == 182.0)
    }

    @Test("the progress ratio is clamped to 0...1")
    func progressClamped() {
        let over = EngineEvent.decode(line: #"{"type":"progress","pct":140}"#)
        guard case .progress(let progress) = over else { Issue.record("expected progress"); return }
        #expect(progress.fraction == 1.0)
    }

    @Test("segment")
    func segment() throws {
        let event = EngineEvent.decode(
            line: #"{"v":1,"type":"segment","id":7,"start":32.5,"end":36.1,"text":" This is a sample sentence."}"#
        )
        guard case .segment(let segment) = event else { Issue.record("expected segment"); return }

        #expect(segment.id == 7)
        #expect(segment.start == 32.5)
        // whisper's own leading space is preserved.
        #expect(segment.text == " This is a sample sentence.")
    }

    @Test("result and the speed multiplier")
    func result() throws {
        let event = EngineEvent.decode(
            line: #"{"v":1,"type":"result","job_id":"t1","language":"tr","duration":24.4,"elapsed":8.7,"rtf":0.356,"outputs":[{"format":"txt","path":"/tmp/a.txt","bytes":4821}],"segment_count":6,"text_chars":326}"#
        )
        guard case .result(let result) = event else { Issue.record("expected result"); return }

        #expect(result.language == "tr")
        #expect(result.outputs.count == 1)
        #expect(result.outputs[0].url.path == "/tmp/a.txt")
        #expect(result.segmentCount == 6)
        // rtf = elapsed / duration; the user is shown its inverse.
        #expect(result.speedMultiplier.map { ($0 * 10).rounded() / 10 } == 2.8)
    }

    @Test("error and the suggestion")
    func failure() throws {
        let event = EngineEvent.decode(
            line: #"{"v":1,"type":"error","code":"AUDIO_DECODE_FAILED","message":"The audio file could not be decoded.","detail":"ffmpeg exited 1","recoverable":false}"#
        )
        guard case .failure(let failure) = event else { Issue.record("expected error"); return }

        #expect(failure.code == .audioDecodeFailed)
        #expect(failure.message == "The audio file could not be decoded.")
        #expect(failure.code.suggestion != nil)
    }

    @Test("An unrecognised error code does not break the app")
    func unknownErrorCode() throws {
        let event = EngineEvent.decode(
            line: #"{"v":1,"type":"error","code":"FUTURE_CODE","message":"A new error."}"#
        )
        guard case .failure(let failure) = event else { Issue.record("expected error"); return }

        #expect(failure.code == .unknown)
        #expect(failure.message == "A new error.")
    }

    @Test("the log level is read")
    func log() throws {
        let event = EngineEvent.decode(
            line: #"{"v":1,"type":"log","level":"warning","message":"FP16 is not supported on CPU"}"#
        )
        guard case .log(let level, let message) = event else { Issue.record("expected log"); return }

        #expect(level == .warning)
        #expect(message.contains("FP16"))
    }

    @Test("A log without a level counts as info")
    func logWithoutLevel() throws {
        let event = EngineEvent.decode(line: #"{"type":"log","message":"something"}"#)
        guard case .log(let level, _) = event else { Issue.record("expected log"); return }
        #expect(level == .info)
    }
}

@Suite("Forward compatibility")
struct ForwardCompatibilityTests {

    @Test("An unrecognised event type becomes unknown")
    func unknownType() {
        // A new protocol version mustn't break an older app.
        let event = EngineEvent.decode(line: #"{"v":2,"type":"future_event","x":1}"#)
        guard case .unknown(let raw) = event else { Issue.record("expected unknown"); return }
        #expect(raw.contains("future_event"))
    }

    @Test("Malformed JSON becomes unknown, it does not throw")
    func malformedJSON() {
        let event = EngineEvent.decode(line: "{malformed json")
        guard case .unknown = event else { Issue.record("expected unknown"); return }
    }

    @Test("An empty line becomes unknown")
    func emptyLine() {
        guard case .unknown = EngineEvent.decode(line: "   ") else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test("An event with a missing field becomes unknown")
    func missingRequiredField() {
        // Without id/start/end a segment can't be decoded, but the app mustn't crash.
        guard case .unknown = EngineEvent.decode(line: #"{"type":"segment","text":"a"}"#) else {
            Issue.record("expected unknown")
            return
        }
    }

    @Test("Unknown extra fields are ignored")
    func extraFieldsIgnored() {
        let event = EngineEvent.decode(
            line: #"{"v":1,"type":"segment","id":0,"start":0,"end":1,"text":"a","yeni_alan":42}"#
        )
        guard case .segment(let segment) = event else { Issue.record("expected segment"); return }
        #expect(segment.id == 0)
    }
}

@Suite("Log line display")
struct LogLineTests {

    @Test("Events that are not shown return nil")
    func silentEvents() {
        let progress = EngineEvent.decode(line: #"{"type":"progress","pct":10}"#)
        let segment = EngineEvent.decode(line: #"{"type":"segment","id":0,"start":0,"end":1,"text":"a"}"#)

        #expect(progress.logLine == nil)
        #expect(segment.logLine == nil)
    }

    @Test("The warning level is labelled")
    func warningLabelled() {
        let event = EngineEvent.decode(line: #"{"type":"log","level":"warning","message":"watch out"}"#)
        #expect(event.logLine == "[warning] watch out")
    }

    @Test("The info level is unlabelled")
    func infoPlain() {
        let event = EngineEvent.decode(line: #"{"type":"log","level":"info","message":"hello"}"#)
        #expect(event.logLine == "hello")
    }

    @Test("An error event shows up in the log too")
    func failureVisible() {
        let event = EngineEvent.decode(
            line: #"{"type":"error","code":"OUT_OF_MEMORY","message":"Not enough memory."}"#
        )
        #expect(event.logLine?.contains("OUT_OF_MEMORY") == true)
    }
}

@Suite("Supported files")
struct SupportedMediaTests {

    @Test("Audio and video extensions are accepted")
    func acceptsMedia() {
        #expect(SupportedMedia.isSupported(URL(filePath: "/a/b.m4a")))
        #expect(SupportedMedia.isSupported(URL(filePath: "/a/b.MP3")))
        #expect(SupportedMedia.isSupported(URL(filePath: "/a/b.mp4")))
        #expect(SupportedMedia.isSupported(URL(filePath: "/a/b.wav")))
    }

    @Test("Other extensions are rejected")
    func rejectsOthers() {
        #expect(!SupportedMedia.isSupported(URL(filePath: "/a/b.txt")))
        #expect(!SupportedMedia.isSupported(URL(filePath: "/a/b.pdf")))
        #expect(!SupportedMedia.isSupported(URL(filePath: "/a/b")))
    }

    @Test("Files one level deep are collected from a folder")
    func collectsFromDirectory() throws {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "wt-\(UUID().uuidString)")
        let nested = root.appending(path: "alt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: root.appending(path: "one.m4a"))
        try Data().write(to: root.appending(path: "two.mp3"))
        try Data().write(to: root.appending(path: "note.txt"))
        try Data().write(to: nested.appending(path: "deep.m4a"))

        let (accepted, _) = SupportedMedia.collect(from: [root])

        #expect(accepted.map(\.lastPathComponent) == ["one.m4a", "two.mp3"])
        // Walking the whole tree would be a surprise.
        #expect(!accepted.contains { $0.lastPathComponent == "deep.m4a" })
    }

    @Test("Unsupported files are reported separately")
    func reportsRejected() throws {
        let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audio = directory.appending(path: "audio.m4a")
        let document = directory.appending(path: "document.pdf")
        try Data().write(to: audio)
        try Data().write(to: document)

        let (accepted, rejected) = SupportedMedia.collect(from: [audio, document])

        #expect(accepted == [audio])
        #expect(rejected == [document])
    }
}
