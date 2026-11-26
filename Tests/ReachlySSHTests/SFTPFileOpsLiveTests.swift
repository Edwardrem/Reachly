import Foundation
import Synchronization
import Testing
@testable import ReachlySSH

/// `SFTPClient.createFile` and `copyItem` against the throwaway sshd (see `LiveServer`). Each test works in a fresh
/// folder under /tmp on the server and removes it afterwards.
@Suite(.enabled(if: LiveServer.isConfigured))
struct SFTPFileOpsLiveTests {
    // MARK: Session

    /// Connects, makes a scratch folder, runs `body` with the client and that folder, then cleans up.
    private func withScratch(_ body: (SFTPClient, String) async throws -> Void) async throws {
        let server = try #require(LiveServer.current)
        let key = try SSHPrivateKey.load(fromPath: server.keyPath)
        let connection = try await SSHConnection.connect(
            host: server.host, port: server.port,
            credentials: SSHCredentials(username: server.user, secret: .privateKey(key)),
            hostKeyVerifier: InsecureAcceptAllHostKeys())
        let sftp: SFTPClient
        do {
            // A server without an sftp subsystem refuses it; the timeout keeps a regression from hanging the run.
            sftp = try await Self.withTimeout(.seconds(15)) { try await SFTPClient.open(on: connection) }
        } catch {
            connection.close()
            throw error
        }
        let root = "/tmp/reachly-sftp-ops-\(UUID().uuidString)"
        try await sftp.makeDirectory(root)
        do {
            try await body(sftp, root)
        } catch {
            await Self.removeAll(root, sftp)
            sftp.close()
            connection.close()
            throw error
        }
        await Self.removeAll(root, sftp)
        sftp.close()
        connection.close()
    }

    private struct SFTPDidNotStart: Swift.Error, CustomStringConvertible {
        var description: String { "No SFTP handshake: does the test sshd's config have a Subsystem sftp line?" }
    }

    private static func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw SFTPDidNotStart() }
            return value
        }
    }

    /// Removes a test folder even where a test made parts of it read-only.
    private static func removeAll(_ path: String, _ sftp: SFTPClient) async {
        guard let attributes = try? await sftp.lstat(path) else { return }
        if attributes.isDirectory {
            try? await sftp.setPermissions(0o700, path: path)
            for entry in (try? await sftp.listDirectory(path)) ?? [] {
                await removeAll(SFTP.join(path, entry.name), sftp)
            }
            try? await sftp.removeDirectory(path)
        } else {
            try? await sftp.remove(path)
        }
    }

    private static func bytes(_ count: Int, seed: UInt64 = 42) -> Data {
        var state = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<count {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                buffer[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return data
    }

    private static func exists(_ path: String, _ sftp: SFTPClient) async -> Bool {
        (try? await sftp.lstat(path)) != nil
    }

    private static func names(_ path: String, _ sftp: SFTPClient) async throws -> [String] {
        try await sftp.listDirectory(path).map(\.name).sorted()
    }

    /// Collects progress reports from any thread.
    private final class ProgressLog: Sendable {
        private let reports = Mutex<[(Int64, Int64?)]>([])
        func record(_ transferred: Int64, _ total: Int64?) { reports.withLock { $0.append((transferred, total)) } }
        var all: [(Int64, Int64?)] { reports.withLock { $0 } }
    }

    /// The error a failed call threw, or nil when it succeeded.
    private static func error(of body: () async throws -> Void) async -> Swift.Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    // MARK: A server without SFTP

    @Test(.enabled(if: LiveServer.current?.noSFTPPort != nil))
    func openingSFTPWhereTheServerRefusesItFailsPromptlyAndClearly() async throws {
        let server = try #require(LiveServer.current)
        let port = try #require(server.noSFTPPort)
        let key = try SSHPrivateKey.load(fromPath: server.keyPath)
        let connection = try await SSHConnection.connect(
            host: server.host, port: port,
            credentials: SSHCredentials(username: server.user, secret: .privateKey(key)),
            hostKeyVerifier: InsecureAcceptAllHostKeys())
        defer { connection.close() }

        let clock = ContinuousClock()
        let started = clock.now
        // The backstop here only keeps a regression from hanging the run; the refusal itself takes one round trip.
        let error = await Self.error { _ = try await Self.withTimeout(.seconds(10)) { try await SFTPClient.open(on: connection) } }
        let elapsed = clock.now - started
        #expect(error as? SFTP.Error == .unavailable, "\(String(describing: error))")
        #expect(error?.localizedDescription == "This server doesn't offer SFTP.")
        #expect(elapsed < .seconds(3), "took \(elapsed)")

        // Only the refused channel was closed: the connection still runs commands.
        let result = try await connection.run("echo still-here")
        #expect(result.stdoutText == "still-here\n")
    }

    @Test func aRefusedSubsystemIsReportedByName() async throws {
        // `openSubsystem` waits for the answer to its want-reply request: an unknown name is refused the way a missing
        // Subsystem line refuses sftp, and the error names it.
        let server = try #require(LiveServer.current)
        let key = try SSHPrivateKey.load(fromPath: server.keyPath)
        let connection = try await SSHConnection.connect(
            host: server.host, port: server.port,
            credentials: SSHCredentials(username: server.user, secret: .privateKey(key)),
            hostKeyVerifier: InsecureAcceptAllHostKeys())
        defer { connection.close() }
        let error = await Self.error {
            _ = try await Self.withTimeout(.seconds(10)) {
                try await connection.openSubsystem("reachly-no-such-subsystem") { _ in }
            }
        }
        #expect(error as? SSHClientError == .subsystemUnavailable("reachly-no-such-subsystem"), "\(String(describing: error))")
    }

    // MARK: createFile

    @Test func createFileMakesAnEmptyFile() async throws {
        try await withScratch { sftp, root in
            let path = root + "/new.txt"
            try await sftp.createFile(path)
            let attributes = try await sftp.lstat(path)
            #expect(attributes.kind == .regular)
            #expect(attributes.size == 0)

            try await sftp.createFile(root + "/private.txt", mode: 0o600)
            #expect(try await sftp.stat(root + "/private.txt").mode == 0o600)
        }
    }

    @Test func createFileRefusesAnExistingFileAndLeavesItUntouched() async throws {
        try await withScratch { sftp, root in
            let path = root + "/keep.txt"
            try await sftp.writeFile(Data("keep me".utf8), to: path, mode: 0o644)
            let error = await Self.error { try await sftp.createFile(path) }
            #expect(error != nil)
            #expect(error?.localizedDescription.contains("already exists") == true)
            #expect(try await sftp.readFile(path) == Data("keep me".utf8))
            #expect(try await sftp.stat(path).mode == 0o644)
        }
    }

    @Test func createFileRefusesAFolderAndASymlink() async throws {
        try await withScratch { sftp, root in
            try await sftp.makeDirectory(root + "/folder")
            try await sftp.writeFile(Data("inside".utf8), to: root + "/folder/a.txt")
            await #expect(throws: SFTP.Error.self) { try await sftp.createFile(root + "/folder") }
            #expect(try await sftp.lstat(root + "/folder").isDirectory)
            #expect(try await Self.names(root + "/folder", sftp) == ["a.txt"])

            // A dangling link: an open that followed it would create its target.
            try await sftp.symlink(target: root + "/nowhere.txt", at: root + "/dangling")
            await #expect(throws: SFTP.Error.self) { try await sftp.createFile(root + "/dangling") }
            #expect(try await sftp.lstat(root + "/dangling").isSymlink)
            #expect(await !Self.exists(root + "/nowhere.txt", sftp))
        }
    }

    // MARK: copyItem, files

    @Test func copiesAFileWithItsPermissionsAndDate() async throws {
        try await withScratch { sftp, root in
            let content = Self.bytes(100_003)
            try await sftp.writeFile(content, to: root + "/a.bin")
            try await sftp.setPermissions(0o640, path: root + "/a.bin")
            let date = Date(timeIntervalSince1970: 1_600_000_000)
            try await sftp.setAttributes(SFTP.Attributes(accessTime: date, modificationTime: date), path: root + "/a.bin")

            let log = ProgressLog()
            try await sftp.copyItem(root + "/a.bin", to: root + "/b.bin") { log.record($0, $1) }
            #expect(try await sftp.readFile(root + "/b.bin") == content)
            let copy = try await sftp.lstat(root + "/b.bin")
            #expect(copy.kind == .regular)
            #expect(copy.mode == 0o640)
            #expect(copy.modificationTime == date)
            #expect(log.all.first.map { $0.0 } == 0)
            #expect(log.all.last.map { $0.0 } == 100_003)
            #expect(log.all.allSatisfy { $0.1 == 100_003 })
            // The source is untouched.
            #expect(try await sftp.readFile(root + "/a.bin") == content)
        }
    }

    @Test func copiesAnEmptyFile() async throws {
        try await withScratch { sftp, root in
            try await sftp.createFile(root + "/empty")
            try await sftp.copyItem(root + "/empty", to: root + "/empty copy")
            #expect(try await sftp.lstat(root + "/empty copy").size == 0)
        }
    }

    @Test func streamsALargeFileInChunks() async throws {
        try await withScratch { sftp, root in
            // Several pipelined batches, and an end that is not on a chunk boundary.
            let size = 5 * 1024 * 1024 + 7
            let content = Self.bytes(size, seed: 7)
            try await sftp.writeFile(content, to: root + "/big.bin")
            let log = ProgressLog()
            try await sftp.copyItem(root + "/big.bin", to: root + "/big copy.bin") { log.record($0, $1) }
            #expect(try await sftp.readFile(root + "/big copy.bin") == content)
            let steps = log.all.map(\.0)
            #expect(steps.last == Int64(size))
            #expect(steps == steps.sorted())
            // Each step is at most one batch: the file is never held whole.
            let batch = Int64(SFTPClient.chunkSize * SFTPClient.pipelineDepth)
            #expect(zip(steps, steps.dropFirst()).allSatisfy { $1 - $0 <= batch })
            #expect(steps.count > size / Int(batch))
        }
    }

    @Test func keepsAReadOnlyFileReadOnly() async throws {
        try await withScratch { sftp, root in
            try await sftp.writeFile(Data("locked".utf8), to: root + "/ro.txt")
            try await sftp.setPermissions(0o444, path: root + "/ro.txt")
            try await sftp.copyItem(root + "/ro.txt", to: root + "/ro copy.txt")
            #expect(try await sftp.readFile(root + "/ro copy.txt") == Data("locked".utf8))
            #expect(try await sftp.stat(root + "/ro copy.txt").mode == 0o444)
        }
    }

    @Test func copiesASymlinkAsASymlink() async throws {
        try await withScratch { sftp, root in
            try await sftp.writeFile(Data("target".utf8), to: root + "/target.txt")
            try await sftp.symlink(target: "target.txt", at: root + "/link")
            try await sftp.copyItem(root + "/link", to: root + "/link copy")
            #expect(try await sftp.lstat(root + "/link copy").isSymlink)
            #expect(try await sftp.readLink(root + "/link copy") == "target.txt")

            // A dangling link copies too.
            try await sftp.symlink(target: "/nonexistent/reachly", at: root + "/dangling")
            try await sftp.copyItem(root + "/dangling", to: root + "/dangling copy")
            #expect(try await sftp.readLink(root + "/dangling copy") == "/nonexistent/reachly")
        }
    }

    // MARK: copyItem, folders

    @Test func copiesAnEmptyFolderWithItsPermissions() async throws {
        try await withScratch { sftp, root in
            try await sftp.makeDirectory(root + "/empty")
            try await sftp.setPermissions(0o750, path: root + "/empty")
            try await sftp.copyItem(root + "/empty", to: root + "/empty copy")
            let copy = try await sftp.lstat(root + "/empty copy")
            #expect(copy.isDirectory)
            #expect(copy.mode == 0o750)
            #expect(try await sftp.listDirectory(root + "/empty copy").isEmpty)
        }
    }

    @Test func copiesANestedFolderWithSymlinksAndPermissions() async throws {
        try await withScratch { sftp, root in
            let src = root + "/src"
            try await sftp.makeDirectory(src)
            try await sftp.writeFile(Data("alpha".utf8), to: src + "/a.txt")
            try await sftp.setPermissions(0o600, path: src + "/a.txt")
            try await sftp.makeDirectory(src + "/bin")
            try await sftp.writeFile(Data("#!/bin/sh\necho hi\n".utf8), to: src + "/bin/run.sh")
            try await sftp.setPermissions(0o755, path: src + "/bin/run.sh")
            try await sftp.makeDirectory(src + "/deep")
            try await sftp.makeDirectory(src + "/deep/er")
            let blob = Self.bytes(300_000, seed: 3)
            try await sftp.writeFile(blob, to: src + "/deep/er/blob.bin")
            try await sftp.symlink(target: "a.txt", at: src + "/link-to-a")
            try await sftp.symlink(target: "../bin", at: src + "/deep/link-to-bin")
            // A link to a folder outside: recreated, its contents not copied.
            try await sftp.makeDirectory(root + "/outside")
            try await sftp.writeFile(Data("not copied".utf8), to: root + "/outside/secret.txt")
            try await sftp.symlink(target: root + "/outside", at: src + "/outside-link")
            // A read-only folder with a file inside.
            try await sftp.makeDirectory(src + "/ro")
            try await sftp.writeFile(Data("in ro".utf8), to: src + "/ro/f.txt")
            try await sftp.setPermissions(0o555, path: src + "/ro")
            try await sftp.setPermissions(0o710, path: src + "/deep")

            let log = ProgressLog()
            try await sftp.copyItem(src, to: root + "/dst") { log.record($0, $1) }

            let dst = root + "/dst"
            #expect(try await Self.names(dst, sftp) == ["a.txt", "bin", "deep", "link-to-a", "outside-link", "ro"])
            #expect(try await sftp.readFile(dst + "/a.txt") == Data("alpha".utf8))
            #expect(try await sftp.stat(dst + "/a.txt").mode == 0o600)
            #expect(try await sftp.stat(dst + "/bin/run.sh").mode == 0o755)
            #expect(try await sftp.readFile(dst + "/deep/er/blob.bin") == blob)
            #expect(try await sftp.lstat(dst + "/deep").mode == 0o710)
            #expect(try await sftp.lstat(dst + "/ro").mode == 0o555)
            #expect(try await sftp.readFile(dst + "/ro/f.txt") == Data("in ro".utf8))

            #expect(try await sftp.lstat(dst + "/link-to-a").isSymlink)
            #expect(try await sftp.readLink(dst + "/link-to-a") == "a.txt")
            #expect(try await sftp.readLink(dst + "/deep/link-to-bin") == "../bin")
            #expect(try await sftp.lstat(dst + "/outside-link").isSymlink)
            #expect(try await sftp.readLink(dst + "/outside-link") == root + "/outside")
            #expect(try await Self.names(root + "/outside", sftp) == ["secret.txt"])

            let total = Int64(5 + 18 + 300_000 + 5)
            #expect(log.all.last.map { $0.0 } == total)
            #expect(log.all.allSatisfy { $0.1 == total })
        }
    }

    // MARK: copyItem, refusals

    @Test func refusesAnExistingFileTargetWithoutWriting() async throws {
        try await withScratch { sftp, root in
            try await sftp.writeFile(Data("new".utf8), to: root + "/a.txt")
            try await sftp.writeFile(Data("old".utf8), to: root + "/b.txt")
            try await sftp.setPermissions(0o600, path: root + "/b.txt")
            let error = await Self.error { try await sftp.copyItem(root + "/a.txt", to: root + "/b.txt") }
            #expect(error?.localizedDescription.contains("already exists") == true)
            #expect(try await sftp.readFile(root + "/b.txt") == Data("old".utf8))
            #expect(try await sftp.stat(root + "/b.txt").mode == 0o600)

            // Onto itself.
            await #expect(throws: SFTP.Error.self) { try await sftp.copyItem(root + "/a.txt", to: root + "/a.txt") }
            #expect(try await sftp.readFile(root + "/a.txt") == Data("new".utf8))
        }
    }

    @Test func refusesAnExistingFolderTargetWithoutWritingIntoIt() async throws {
        try await withScratch { sftp, root in
            try await sftp.makeDirectory(root + "/src")
            try await sftp.writeFile(Data("x".utf8), to: root + "/src/x.txt")
            try await sftp.makeDirectory(root + "/dst")
            try await sftp.writeFile(Data("y".utf8), to: root + "/dst/y.txt")
            await #expect(throws: SFTP.Error.self) { try await sftp.copyItem(root + "/src", to: root + "/dst") }
            #expect(try await Self.names(root + "/dst", sftp) == ["y.txt"])

            // A file onto a folder, and a folder onto a file.
            await #expect(throws: SFTP.Error.self) { try await sftp.copyItem(root + "/src/x.txt", to: root + "/dst") }
            await #expect(throws: SFTP.Error.self) { try await sftp.copyItem(root + "/src", to: root + "/dst/y.txt") }
            #expect(try await sftp.readFile(root + "/dst/y.txt") == Data("y".utf8))
        }
    }

    @Test func refusesADanglingSymlinkTarget() async throws {
        try await withScratch { sftp, root in
            try await sftp.writeFile(Data("data".utf8), to: root + "/a.txt")
            try await sftp.symlink(target: root + "/created-through-link.txt", at: root + "/dangling")
            await #expect(throws: SFTP.Error.self) { try await sftp.copyItem(root + "/a.txt", to: root + "/dangling") }
            #expect(try await sftp.lstat(root + "/dangling").isSymlink)
            #expect(await !Self.exists(root + "/created-through-link.txt", sftp))
        }
    }

    @Test func refusesAFolderIntoItself() async throws {
        try await withScratch { sftp, root in
            let src = root + "/src"
            try await sftp.makeDirectory(src)
            try await sftp.makeDirectory(src + "/sub")
            try await sftp.writeFile(Data("x".utf8), to: src + "/x.txt")

            for target in [src + "/copy", src + "/sub/copy", src + "/sub/../copy"] {
                let error = await Self.error { try await sftp.copyItem(src, to: target) }
                #expect(error?.localizedDescription.contains("into itself") == true, "\(target)")
            }
            // Through a symlink that points into the folder.
            try await sftp.symlink(target: src + "/sub", at: root + "/alias")
            await #expect(throws: SFTP.Error.self) { try await sftp.copyItem(src, to: root + "/alias/copy") }

            #expect(try await Self.names(src, sftp) == ["sub", "x.txt"])
            #expect(try await sftp.listDirectory(src + "/sub").isEmpty)

            // A sibling whose name starts the same way is fine.
            try await sftp.copyItem(src, to: root + "/src2")
            #expect(try await Self.names(root + "/src2", sftp) == ["sub", "x.txt"])
        }
    }

    @Test func aMissingSourceOrParentFailsWithoutLeavingAnything() async throws {
        try await withScratch { sftp, root in
            await #expect(throws: SFTP.Error.self) { try await sftp.copyItem(root + "/missing", to: root + "/copy") }
            try await sftp.makeDirectory(root + "/src")
            await #expect(throws: SFTP.Error.self) { try await sftp.copyItem(root + "/src", to: root + "/no/such/parent") }
            #expect(try await Self.names(root, sftp) == ["src"])
        }
    }

    // MARK: copyItem, clean-up

    @Test func removesThePartialCopyWhenAFileCantBeRead() async throws {
        try await withScratch { sftp, root in
            let src = root + "/src"
            try await sftp.makeDirectory(src)
            for index in 0..<5 { try await sftp.writeFile(Self.bytes(10_000, seed: UInt64(index)), to: src + "/f\(index).bin") }
            try await sftp.makeDirectory(src + "/sub")
            try await sftp.writeFile(Data("fine".utf8), to: src + "/sub/ok.txt")
            try await sftp.setPermissions(0o555, path: src + "/sub")
            try await sftp.writeFile(Data("secret".utf8), to: src + "/zz-unreadable.txt")
            try await sftp.setPermissions(0o000, path: src + "/zz-unreadable.txt")
            if let handle = try? await sftp.openFile(src + "/zz-unreadable.txt", flags: [.read]) {
                // The server runs as root, which reads anything: this failure can't be staged here.
                try? await sftp.closeHandle(handle)
                return
            }

            await #expect(throws: SFTP.Error.self) { try await sftp.copyItem(src, to: root + "/dst") }
            #expect(await !Self.exists(root + "/dst", sftp))
            #expect(try await Self.names(src, sftp) == ["f0.bin", "f1.bin", "f2.bin", "f3.bin", "f4.bin", "sub", "zz-unreadable.txt"])

            // A single unreadable file leaves nothing behind either.
            await #expect(throws: SFTP.Error.self) { try await sftp.copyItem(src + "/zz-unreadable.txt", to: root + "/single") }
            #expect(await !Self.exists(root + "/single", sftp))
        }
    }

    @Test func removesThePartialCopyWhenAFileIsCancelled() async throws {
        try await withScratch { sftp, root in
            let size = 8 * 1024 * 1024
            try await sftp.writeFile(Self.bytes(size, seed: 9), to: root + "/big.bin")
            let reported = ProgressLog()
            let copy = Task {
                try await sftp.copyItem(root + "/big.bin", to: root + "/big copy.bin") { transferred, total in
                    reported.record(transferred, total)
                    // Cancel from inside, once some bytes are in: the copy is under way.
                    if transferred > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            let error = await copy.result.error
            #expect(error is CancellationError, "\(String(describing: error))")
            #expect(reported.all.contains { $0.0 > 0 && $0.0 < Int64(size) })
            #expect(await !Self.exists(root + "/big copy.bin", sftp))
            // The session still works.
            #expect(try await Self.names(root, sftp) == ["big.bin"])
        }
    }

    @Test func removesThePartialCopyWhenAFolderIsCancelled() async throws {
        try await withScratch { sftp, root in
            let src = root + "/src"
            try await sftp.makeDirectory(src)
            for folder in ["a", "b", "c"] {
                try await sftp.makeDirectory(src + "/" + folder)
                for index in 0..<4 { try await sftp.writeFile(Self.bytes(64 * 1024, seed: UInt64(index)), to: src + "/\(folder)/\(index).bin") }
            }
            let copy = Task {
                try await sftp.copyItem(src, to: root + "/dst") { transferred, _ in
                    // Cancel halfway, with folders and files already made.
                    if transferred >= 6 * 64 * 1024 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            let error = await copy.result.error
            #expect(error is CancellationError, "\(String(describing: error))")
            #expect(await !Self.exists(root + "/dst", sftp))
            #expect(try await Self.names(src, sftp) == ["a", "b", "c"])
        }
    }

    // MARK: Transfers that never overwrite (Paste)

    /// A file on this Mac for an upload, in a temporary folder `body` may use; removed afterwards.
    private static func withLocalFolder(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "reachly-transfer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder)
    }

    @Test func anExclusiveUploadRefusesAnExistingFileAndLeavesItIntact() async throws {
        try await withScratch { sftp, root in
            try await Self.withLocalFolder { folder in
                let local = folder.appending(path: "new.txt")
                try Data("replacement".utf8).write(to: local)
                try await sftp.writeFile(Data("keep me".utf8), to: root + "/keep.txt", mode: 0o640)

                let claim = SFTPClient.TargetClaim()
                for resume in [false, true] {
                    let error = await Self.error { try await sftp.upload(local, to: root + "/keep.txt", resume: resume, overwrite: .never(claim)) }
                    #expect(error?.localizedDescription.contains("already exists") == true, "\(String(describing: error))")
                }
                #expect(try await sftp.readFile(root + "/keep.txt") == Data("keep me".utf8))
                #expect(try await sftp.stat(root + "/keep.txt").mode == 0o640)
                #expect(!claim.hasMadeFile)

                // A folder and a dangling link are refused too; the link's target is not created.
                try await sftp.makeDirectory(root + "/folder")
                await #expect(throws: SFTP.Error.self) { try await sftp.upload(local, to: root + "/folder", overwrite: .never(claim)) }
                try await sftp.symlink(target: root + "/nowhere.txt", at: root + "/dangling")
                await #expect(throws: SFTP.Error.self) { try await sftp.upload(local, to: root + "/dangling", overwrite: .never(claim)) }
                #expect(await !Self.exists(root + "/nowhere.txt", sftp))

                // The same upload to a free name works, and the old behaviour still replaces.
                try await sftp.upload(local, to: root + "/fresh.txt", overwrite: .never(SFTPClient.TargetClaim()))
                #expect(try await sftp.readFile(root + "/fresh.txt") == Data("replacement".utf8))
                try await sftp.upload(local, to: root + "/keep.txt")
                #expect(try await sftp.readFile(root + "/keep.txt") == Data("replacement".utf8))
            }
        }
    }

    @Test func aRetryAfterAPartialExclusiveUploadSucceeds() async throws {
        try await withScratch { sftp, root in
            try await Self.withLocalFolder { folder in
                let size = 3 * 1024 * 1024 + 11
                let content = Self.bytes(size, seed: 5)
                let local = folder.appending(path: "big.bin")
                try content.write(to: local)
                let target = root + "/big.bin"

                // The first attempt stops after its first batch, as a pause or a dropped connection would.
                let claim = SFTPClient.TargetClaim()
                let first = Task {
                    try await sftp.upload(local, to: target, overwrite: .never(claim)) { transferred, _ in
                        if transferred > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                }
                #expect(await first.result.error is CancellationError)
                #expect(claim.hasMadeFile)
                let partial = try #require(try await sftp.stat(target).size)
                #expect(partial > 0 && partial < UInt64(size))

                // Another transfer may not touch it.
                let other = await Self.error { try await sftp.upload(local, to: target, resume: true, overwrite: .never(SFTPClient.TargetClaim())) }
                #expect(other?.localizedDescription.contains("already exists") == true)
                #expect(try await sftp.stat(target).size == partial)

                // The retry continues its own partial file.
                let log = ProgressLog()
                try await sftp.upload(local, to: target, resume: true, overwrite: .never(claim)) { log.record($0, $1) }
                #expect(log.all.first.map { UInt64($0.0) } == partial)
                #expect(try await sftp.readFile(target) == content)

                // A retry from the start (a copy between hosts uploads again in full) rewrites its own file.
                try await sftp.upload(local, to: target, resume: false, overwrite: .never(claim))
                #expect(try await sftp.readFile(target) == content)

                // If its file was removed meanwhile, the retry makes a new one.
                try await sftp.remove(target)
                try await sftp.upload(local, to: target, resume: true, overwrite: .never(claim))
                #expect(try await sftp.readFile(target) == content)
            }
        }
    }

    @Test func anExclusiveDownloadRefusesAnExistingLocalFileAndRetriesItsOwn() async throws {
        try await withScratch { sftp, root in
            try await Self.withLocalFolder { folder in
                let content = Self.bytes(2 * 1024 * 1024 + 3, seed: 8)
                try await sftp.writeFile(content, to: root + "/remote.bin")

                let existing = folder.appending(path: "existing.bin")
                try Data("keep me".utf8).write(to: existing)
                let error = await Self.error { try await sftp.download(root + "/remote.bin", to: existing, overwrite: .never(SFTPClient.TargetClaim())) }
                #expect(error?.localizedDescription.contains("already exists") == true, "\(String(describing: error))")
                #expect(try Data(contentsOf: existing) == Data("keep me".utf8))

                let local = folder.appending(path: "fresh.bin")
                let claim = SFTPClient.TargetClaim()
                let first = Task {
                    try await sftp.download(root + "/remote.bin", to: local, overwrite: .never(claim)) { transferred, _ in
                        if transferred > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                }
                #expect(await first.result.error is CancellationError)
                #expect(claim.hasMadeFile)
                try await sftp.download(root + "/remote.bin", to: local, resume: true, overwrite: .never(claim))
                #expect(try Data(contentsOf: local) == content)
            }
        }
    }

    @Test func cancellingBeforeTheStartWritesNothing() async throws {
        try await withScratch { sftp, root in
            try await sftp.writeFile(Data("x".utf8), to: root + "/a.txt")
            try await sftp.makeDirectory(root + "/folder")
            for (source, target) in [("a.txt", "b.txt"), ("folder", "folder copy")] {
                let copy = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try await sftp.copyItem(root + "/" + source, to: root + "/" + target)
                }
                #expect(await copy.result.error is CancellationError)
            }
            #expect(try await Self.names(root, sftp) == ["a.txt", "folder"])
        }
    }
}

private extension Result {
    var error: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
