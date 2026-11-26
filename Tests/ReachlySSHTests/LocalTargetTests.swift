import Foundation
import Testing
@testable import ReachlySSH

/// The file on this Mac a download writes into (`LocalTarget`), in both overwrite modes. Each test works in its own
/// temporary folder.
@Suite struct LocalTargetTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "reachly-local-target-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func contents(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// Opens `url`, writes `text` at the offset it gives, closes it, and returns that offset.
    @discardableResult
    private func download(_ text: String, to url: URL, resume: Bool = false, overwrite: SFTPClient.Overwrite) throws -> UInt64 {
        let (handle, offset) = try LocalTarget.open(url, resume: resume, overwrite: overwrite)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        return offset
    }

    /// Expects `body` to fail because something is already at the destination.
    private func expectRefused(_ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            try body()
            Issue.record("the open was not refused", sourceLocation: sourceLocation)
        } catch {
            #expect(error.localizedDescription.contains("already exists"), "\(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Never overwrite

    @Test func createsANewFileAndClaimsIt() throws {
        defer { cleanUp() }
        let claim = SFTPClient.TargetClaim()
        let url = folder.appending(path: "new.txt")
        #expect(try download("hello", to: url, overwrite: .never(claim)) == 0)
        #expect(try contents(url) == "hello")
        #expect(claim.hasMadeFile)
    }

    @Test func makesMissingParentFolders() throws {
        defer { cleanUp() }
        let url = folder.appending(path: "a/b/new.txt")
        try download("deep", to: url, overwrite: .never(SFTPClient.TargetClaim()))
        #expect(try contents(url) == "deep")
    }

    @Test func refusesAnExistingFileAndLeavesItIntact() throws {
        defer { cleanUp() }
        let url = try write("keep me", to: "keep.txt")
        let claim = SFTPClient.TargetClaim()
        // With and without resume: neither may touch a file the transfer didn't make.
        for resume in [false, true] {
            expectRefused { try download("replaced", to: url, resume: resume, overwrite: .never(claim)) }
        }
        #expect(try contents(url) == "keep me")
        #expect(!claim.hasMadeFile)
    }

    @Test func refusesAFolderAndASymlink() throws {
        defer { cleanUp() }
        let subfolder = folder.appending(path: "sub")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
        expectRefused { try download("x", to: subfolder, overwrite: .never(SFTPClient.TargetClaim())) }

        // A dangling link: an open that followed it would create its target.
        let link = folder.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: folder.appending(path: "nowhere.txt").path)
        expectRefused { try download("x", to: link, overwrite: .never(SFTPClient.TargetClaim())) }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "nowhere.txt").path))
    }

    @Test func aResumeContinuesTheFileItMade() throws {
        defer { cleanUp() }
        let claim = SFTPClient.TargetClaim()
        let url = folder.appending(path: "partial.bin")
        try download("first half,", to: url, overwrite: .never(claim))
        // The retry resumes at the end of its own partial file.
        #expect(try download(" second half", to: url, resume: true, overwrite: .never(claim)) == 11)
        #expect(try contents(url) == "first half, second half")
    }

    @Test func aRetryWithoutResumeStartsItsOwnFileOver() throws {
        defer { cleanUp() }
        let claim = SFTPClient.TargetClaim()
        let url = folder.appending(path: "again.txt")
        try download("a longer first attempt", to: url, overwrite: .never(claim))
        #expect(try download("short", to: url, resume: false, overwrite: .never(claim)) == 0)
        #expect(try contents(url) == "short")
    }

    @Test func aRetryMakesTheFileAgainWhenItIsGone() throws {
        defer { cleanUp() }
        let claim = SFTPClient.TargetClaim()
        let url = folder.appending(path: "gone.txt")
        try download("first", to: url, overwrite: .never(claim))
        try FileManager.default.removeItem(at: url)
        #expect(try download("second", to: url, resume: true, overwrite: .never(claim)) == 0)
        #expect(try contents(url) == "second")
    }

    @Test func aFilePutInItsPlaceIsNotTakenForIt() throws {
        defer { cleanUp() }
        let claim = SFTPClient.TargetClaim()
        let url = folder.appending(path: "swapped.txt")
        try download("partial", to: url, overwrite: .never(claim))
        // Someone replaces the partial file with their own under the same name.
        try FileManager.default.removeItem(at: url)
        _ = try write("theirs", to: "swapped.txt")
        for resume in [true, false] {
            expectRefused { try download("mine", to: url, resume: resume, overwrite: .never(claim)) }
        }
        #expect(try contents(url) == "theirs")

        // Or with a symlink to another file.
        try FileManager.default.removeItem(at: url)
        let other = try write("other", to: "other.txt")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        expectRefused { try download("mine", to: url, resume: true, overwrite: .never(claim)) }
        #expect(try contents(other) == "other")
    }

    @Test func aClaimCoversOnlyThePathItMade() throws {
        defer { cleanUp() }
        let claim = SFTPClient.TargetClaim()
        try download("mine", to: folder.appending(path: "a.txt"), overwrite: .never(claim))
        let other = try write("someone else's", to: "b.txt")
        expectRefused { try download("mine", to: other, resume: true, overwrite: .never(claim)) }
        #expect(try contents(other) == "someone else's")
    }

    @Test func anotherTransfersFileIsNotItsOwn() throws {
        defer { cleanUp() }
        let url = folder.appending(path: "shared.txt")
        try download("first transfer", to: url, overwrite: .never(SFTPClient.TargetClaim()))
        expectRefused { try download("second", to: url, resume: true, overwrite: .never(SFTPClient.TargetClaim())) }
        #expect(try contents(url) == "first transfer")
    }

    // MARK: Overwrite allowed (drag and drop, Download…, Open With)

    @Test func allowedReplacesOrResumesAsBefore() throws {
        defer { cleanUp() }
        let url = try write("old content", to: "file.txt")
        #expect(try download("new", to: url, overwrite: .allowed) == 0)
        #expect(try contents(url) == "new")
        #expect(try download(" more", to: url, resume: true, overwrite: .allowed) == 3)
        #expect(try contents(url) == "new more")
        let fresh = folder.appending(path: "x/fresh.txt")
        #expect(try download("fresh", to: fresh, resume: true, overwrite: .allowed) == 0)
        #expect(try contents(fresh) == "fresh")
    }
}
