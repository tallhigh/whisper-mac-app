import Foundation

/// App preferences that have nothing to do with transcription.
///
/// Kept separate from `WhisperSettings`: that type is a **job's** settings and is copied
/// onto every job in the queue; these are the app's behaviour and don't change when a
/// preset is applied.
struct AppPreferences: Codable, Equatable, Sendable {

    /// Start the queue by itself when a file is added.
    var autoStartOnAdd: Bool = false
    /// Notify when the queue finishes (if the app isn't in front).
    var notifyOnFinish: Bool = true
    /// Reveal the produced files in Finder when the queue finishes.
    var revealOnFinish: Bool = false
    /// Keep the Mac awake while transcribing.
    var keepSystemAwake: Bool = true
    /// Ask for confirmation if the user tries to quit while transcribing.
    var confirmOnQuit: Bool = true
    /// The folder audio recordings are written to. `nil` = the default
    /// (`~/Documents/Whisper Transcriber`).
    var recordingDirectory: URL?
    /// The last recording source used.
    var recordingSource: AudioSource = .microphone
    /// The live preview's model. **Separate** from the batch job's: speed is what matters
    /// on the live side, accuracy on the batch side.
    var liveModel: String = "small"
    /// Is live transcription on?
    var liveTranscription: Bool = true
    /// When the recording ends, queue the file and produce the accurate text.
    ///
    /// With it off, the live text is the final output. An hour-long recording means ~18
    /// minutes of CPU with `small`; if the user finds the live text good enough, they
    /// shouldn't have to wait.
    var runSecondPass: Bool = true

    enum CodingKeys: String, CodingKey {
        case autoStartOnAdd, notifyOnFinish, revealOnFinish, keepSystemAwake, confirmOnQuit
        case recordingDirectory, recordingSource, liveModel, liveTranscription, runSecondPass
    }

    /// The default place for recordings. Under Documents, so the Desktop stays clean.
    static var defaultRecordingDirectory: URL {
        URL(filePath: NSHomeDirectory())
            .appending(path: "Documents")
            .appending(path: "Whisper Transcriber")
    }

    /// The same rationale as `WhisperSettings`: a missing key mustn't drop every preference.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppPreferences()
        self.init()
        autoStartOnAdd = container.bool(.autoStartOnAdd, fallback.autoStartOnAdd)
        notifyOnFinish = container.bool(.notifyOnFinish, fallback.notifyOnFinish)
        revealOnFinish = container.bool(.revealOnFinish, fallback.revealOnFinish)
        keepSystemAwake = container.bool(.keepSystemAwake, fallback.keepSystemAwake)
        confirmOnQuit = container.bool(.confirmOnQuit, fallback.confirmOnQuit)
        recordingDirectory = (try? container.decodeIfPresent(URL.self, forKey: .recordingDirectory)) ?? nil
        recordingSource =
            ((try? container.decodeIfPresent(AudioSource.self, forKey: .recordingSource)) ?? nil)
            ?? fallback.recordingSource
        liveModel =
            ((try? container.decodeIfPresent(String.self, forKey: .liveModel)) ?? nil)
            ?? fallback.liveModel
        liveTranscription = container.bool(.liveTranscription, fallback.liveTranscription)
        runSecondPass = container.bool(.runSecondPass, fallback.runSecondPass)
    }

    init() {}
}

extension KeyedDecodingContainer where Key == AppPreferences.CodingKeys {
    fileprivate func bool(_ key: Key, _ fallback: Bool) -> Bool {
        ((try? decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? fallback
    }
}
