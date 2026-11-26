import Foundation
import Testing
@testable import ReachlyCore

/// `LocalFileOps`, behind rename, Move to…, Paste and Duplicate on this Mac. Each test works in its own folder.
@Suite struct LocalFileOpsTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "reachly-local-ops-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "src/sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appending(path: "src/a.txt"))
    }

    private func path(_ relative: String) -> String { folder.appending(path: relative).path }

    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    /// The temporary folder's volume treats "a" and "A" as one name, as macOS volumes do by default.
    private var ignoresCase: Bool {
        (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == false
    }

    @Test func moveRefusesAnythingAtTheTarget() throws {
        defer { cleanUp() }
        try Data("keep".utf8).write(to: folder.appending(path: "taken.txt"))
        #expect(throws: POSIXError(.EEXIST)) { try LocalFileOps.move(path("src/a.txt"), to: path("taken.txt")) }
        #expect(try Data(contentsOf: folder.appending(path: "taken.txt")) == Data("keep".utf8))
        #expect(throws: POSIXError(.EEXIST)) { try LocalFileOps.move(path("src/a.txt"), to: path("src/sub")) }
        // A free name works.
        try LocalFileOps.move(path("src/a.txt"), to: path("moved.txt"))
        #expect(FileManager.default.fileExists(atPath: path("moved.txt")) && !FileManager.default.fileExists(atPath: path("src/a.txt")))
    }

    @Test func aRenameThatOnlyChangesCaseWorks() throws {
        defer { cleanUp() }
        try LocalFileOps.move(path("src/a.txt"), to: path("src/A.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: path("src")).sorted() == ["A.txt", "sub"])
        try LocalFileOps.move(path("src"), to: path("Src"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["Src"])
        guard ignoresCase else { return }
        // Another file is still refused under another case of a name that is there.
        try Data("b".utf8).write(to: folder.appending(path: "Src/b.txt"))
        #expect(throws: POSIXError(.EEXIST)) { try LocalFileOps.move(path("Src/b.txt"), to: path("Src/a.txt")) }
        #expect(try Data(contentsOf: folder.appending(path: "Src/A.txt")) == Data("a".utf8))
    }

    @Test func aFolderNeverGoesInsideItselfUnderAnotherCase() throws {
        defer { cleanUp() }
        // On a volume that tells "src" from "SRC", these are other folders, and there is nothing to refuse.
        guard ignoresCase else { return }
        for target in ["SRC/sub", "SRC/SUB/x"] {
            #expect(throws: LocalFileOps.Refusal.self, "\(target)") { try LocalFileOps.refuseFolderIntoItself(path("src"), path(target)) }
        }
        #expect(throws: LocalFileOps.Refusal.self) { try LocalFileOps.move(path("src"), to: path("SRC/sub/src")) }
        #expect(FileManager.default.fileExists(atPath: path("src/a.txt")))
    }

    @Test func aFolderNeverGoesInsideItselfEvenThroughASymlink() throws {
        defer { cleanUp() }
        try FileManager.default.createSymbolicLink(atPath: path("link"), withDestinationPath: path("src"))
        for target in ["src/sub/src", "link/sub/src", "link/src", "src"] {
            #expect(throws: LocalFileOps.Refusal.self, "\(target)") { try LocalFileOps.refuseFolderIntoItself(path("src"), path(target)) }
        }
        #expect(throws: LocalFileOps.Refusal.self) { try LocalFileOps.move(path("src"), to: path("link/sub/src")) }
        // Next to itself, or elsewhere, is fine; and a symlink to the folder is moved as the link.
        try LocalFileOps.refuseFolderIntoItself(path("src"), path("src copy"))
        try LocalFileOps.refuseFolderIntoItself(path("src"), path("src2"))
        try LocalFileOps.refuseFolderIntoItself(path("link"), path("src/link"))
    }
}
