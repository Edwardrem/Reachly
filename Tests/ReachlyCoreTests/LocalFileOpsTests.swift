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
