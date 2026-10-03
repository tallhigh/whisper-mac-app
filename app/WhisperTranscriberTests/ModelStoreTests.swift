import Foundation
import Testing

@testable import WhisperTranscriber

@Suite("Deleting a downloaded model")
struct ModelStoreTests {

    private let known = ["tiny", "small", "large-v3", "large-v3-turbo"]

    /// A model folder holding `small.pt`, `large-v3.pt` and a file that is not a model.
    private func makeFolder() throws -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "wt-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["small.pt", "large-v3.pt", "notes.txt"] {
            try Data("x".utf8).write(to: directory.appending(path: name))
        }
        return directory
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .sorted()
    }

    @Test("The named model is deleted and the other files stay")
    func deletesOnlyTheNamedModel() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }

        let removed = try ModelStore.delete("small", in: directory, known: known)

        #expect(removed.lastPathComponent == "small.pt")
        #expect(try contents(of: directory) == ["large-v3.pt", "notes.txt"])
    }

    @Test("The folder itself survives deleting the last model")
    func keepsTheFolder() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }

        try ModelStore.delete("small", in: directory, known: known)
        try ModelStore.delete("large-v3", in: directory, known: known)

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(try contents(of: directory) == ["notes.txt"])
    }

    @Test("A name the worker did not report is refused")
    func refusesUnknownModel() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: ModelStore.DeleteError.unknownModel("notes")) {
            try ModelStore.delete("notes", in: directory, known: known)
        }
        #expect(try contents(of: directory) == ["large-v3.pt", "notes.txt", "small.pt"])
    }

    /// The check against the reported list is what stops a crafted name, but the name guard
    /// is tested on its own too: both have to hold for the delete to be safe.
    @Test("A path instead of a name is refused")
    func refusesPaths() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["../small", "/etc/passwd", "sub/small", ".hidden", "", "with space"] {
            #expect(ModelStore.fileURL(for: name, in: directory) == nil, "\(name) must be refused")
            #expect(throws: (any Error).self) {
                try ModelStore.delete(name, in: directory, known: known + [name])
            }
        }
        #expect(try contents(of: directory) == ["large-v3.pt", "notes.txt", "small.pt"])
    }

    @Test("A model that is not downloaded reports so and changes nothing")
    func refusesMissingModel() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: ModelStore.DeleteError.notDownloaded("tiny")) {
            try ModelStore.delete("tiny", in: directory, known: known)
        }
        #expect(try contents(of: directory) == ["large-v3.pt", "notes.txt", "small.pt"])
    }

    /// If `small.pt` were a directory, `removeItem` would take the whole tree with it.
    @Test("A directory named like a model is refused, not deleted")
    func refusesDirectory() throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }

        let impostor = directory.appending(path: "tiny.pt")
        try FileManager.default.createDirectory(at: impostor, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: impostor.appending(path: "inside"))

        #expect(throws: ModelStore.DeleteError.notAFile("tiny")) {
            try ModelStore.delete("tiny", in: directory, known: known)
        }
        #expect(FileManager.default.fileExists(atPath: impostor.appending(path: "inside").path))
    }

    @Test("The file name is the model name plus .pt")
    func fileNaming() {
        let directory = URL(filePath: "/tmp/models")
        #expect(ModelStore.fileURL(for: "large-v3-turbo", in: directory)?.lastPathComponent
            == "large-v3-turbo.pt")
        #expect(ModelStore.isSafeName("small"))
        #expect(ModelStore.isSafeName("large-v3-turbo"))
        #expect(!ModelStore.isSafeName("small/../../x"))
    }
}
