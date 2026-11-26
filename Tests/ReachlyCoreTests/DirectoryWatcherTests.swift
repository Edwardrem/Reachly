import Foundation
import Testing
@testable import ReachlyCore

/// Counts `onChange` calls, which always arrive on the main thread.
@MainActor
private final class CallbackLog {
    private(set) var times: [ContinuousClock.Instant] = []
    var count: Int { times.count }

    func record() {
        #expect(Thread.isMainThread)
        times.append(.now)
    }

    func reset() { times.removeAll() }

    /// Waits until at least `count` callbacks have arrived; false after `timeout`.
    func wait(for count: Int = 1, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while self.count < count {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Waits until no callback has arrived for `quiet`, then forgets them, so events from setting up the folder
    /// (FSEvents can report them a moment late) are not mistaken for the change under test.
    func settle(quiet: Duration = .milliseconds(300)) async {
        let deadline = ContinuousClock.now + .seconds(3)
        var seen = count
        var quietSince = ContinuousClock.now
        while ContinuousClock.now - quietSince < quiet, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            if count != seen {
                seen = count
                quietSince = .now
            }
        }
        reset()
    }

    /// Lets `duration` pass so a callback that should not come has had time to.
    func idle(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

/// The tests share FSEvents and the clock, so they run one at a time.
@Suite(.serialized) @MainActor struct DirectoryWatcherTests {
    private static let debounce: Duration = .milliseconds(100)
    /// Long enough for FSEvents and the debounce to deliver a callback that should not come.
    private static let silence: Duration = .milliseconds(700)

    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "reachly-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(_ url: URL, _ text: String = "hello") {
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeWatcher(_ log: CallbackLog, debounce: Duration = Self.debounce) -> DirectoryWatcher {
        DirectoryWatcher(debounce: debounce) { log.record() }
    }

    // MARK: Changes in the folder

    @Test func createdFile() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        makeFile(dir.appending(path: "new.txt"))
        #expect(await log.wait())
        watcher.stop()
    }

    @Test func deletedFile() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let file = dir.appending(path: "old.txt")
        makeFile(file)
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        try FileManager.default.removeItem(at: file)
        #expect(await log.wait())
        watcher.stop()
    }

    @Test func renamedFile() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        makeFile(dir.appending(path: "before.txt"))
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        #expect(rename(dir.appending(path: "before.txt").path, dir.appending(path: "after.txt").path) == 0)
        #expect(await log.wait())
        watcher.stop()
    }

    @Test func fileWrittenInPlace() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let file = dir.appending(path: "log.txt")
        makeFile(file)
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        // Appending keeps the same file: no entry is added, removed or renamed.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" more".utf8))
        try handle.close()
        #expect(await log.wait())
        watcher.stop()
    }

    @Test func filePermissionsChanged() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let file = dir.appending(path: "script.sh")
        makeFile(file)
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        #expect(chmod(file.path, 0o755) == 0)
        #expect(await log.wait())
        watcher.stop()
    }

    @Test func folderAddedAndRemoved() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        try FileManager.default.createDirectory(at: dir.appending(path: "sub"), withIntermediateDirectories: false)
        #expect(await log.wait())
        await log.settle()
        try FileManager.default.removeItem(at: dir.appending(path: "sub"))
        #expect(await log.wait())
        watcher.stop()
    }

    @Test func changesInsideASubfolderAreIgnored() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let sub = try folder("dir/sub")
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        makeFile(sub.appending(path: "deep.txt"))
        await log.idle(Self.silence)
        #expect(log.count == 0)

        // The watcher still works for the folder itself.
        makeFile(dir.appending(path: "top.txt"))
        #expect(await log.wait())
        watcher.stop()
    }

    @Test func aPathThroughASymlinkIsWatched() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(link.path)
        await log.settle()

        makeFile(dir.appending(path: "new.txt"))
        #expect(await log.wait())
        watcher.stop()
    }

    // MARK: Debounce

    @Test func quickChangesGiveOneCallbackPerWindow() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let log = CallbackLog()
        let watcher = makeWatcher(log, debounce: .milliseconds(500))
        watcher.watch(dir.path)
        await log.settle()

        for index in 0..<20 { makeFile(dir.appending(path: "file\(index).txt")) }
        #expect(await log.wait())
        await log.idle(.milliseconds(800))
        #expect(log.count == 1)

        // The next change after the window closed gets its own callback.
        log.reset()
        makeFile(dir.appending(path: "later.txt"))
        #expect(await log.wait())
        watcher.stop()
    }

    @Test func steadyChangesAreThrottledNotStarved() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let log = CallbackLog()
        let debounce = Duration.milliseconds(200)
        let watcher = makeWatcher(log, debounce: debounce)
        watcher.watch(dir.path)
        await log.settle()

        // A change every 20 ms for 1.2 s: callbacks keep coming while it lasts, at most one per window.
        let end = ContinuousClock.now + .milliseconds(1200)
        var index = 0
        while ContinuousClock.now < end {
            makeFile(dir.appending(path: "tick\(index).txt"))
            index += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        await log.idle(.milliseconds(500))
        #expect(log.count >= 2)
        #expect(log.count <= 8)
        for (earlier, later) in zip(log.times, log.times.dropFirst()) {
            // Callbacks are scheduled a full window apart; allow for the main thread picking them up late.
            #expect(later - earlier >= debounce / 2)
        }
        watcher.stop()
    }

    // MARK: Stopping

    @Test func noCallbackAfterStop() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        watcher.stop()
        makeFile(dir.appending(path: "new.txt"))
        await log.idle(Self.silence)
        #expect(log.count == 0)
    }

    @Test func stopDropsACallbackThatWasAboutToRun() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let log = CallbackLog()
        let watcher = makeWatcher(log, debounce: .milliseconds(400))
        watcher.watch(dir.path)
        await log.settle()

        makeFile(dir.appending(path: "new.txt"))
        try await Task.sleep(for: .milliseconds(150)) // the event is in, the callback waits for its window
        watcher.stop()
        await log.idle(Self.silence)
        #expect(log.count == 0)
    }

    @Test func noCallbackAfterWatchingNil() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        watcher.watch(nil)
        makeFile(dir.appending(path: "new.txt"))
        await log.idle(Self.silence)
        #expect(log.count == 0)
    }

    @Test func watchingANewFolderStopsTheOldOne() async throws {
        defer { cleanUp() }
        let first = try folder("first")
        let second = try folder("second")
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(first.path)
        watcher.watch(second.path)
        await log.settle()

        makeFile(first.appending(path: "old.txt"))
        await log.idle(Self.silence)
        #expect(log.count == 0)

        makeFile(second.appending(path: "new.txt"))
        #expect(await log.wait())
        watcher.stop()
    }

    @Test func watchingTheSameFolderAgainKeepsWatching() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        watcher.watch(dir.path + "/")
        makeFile(dir.appending(path: "new.txt"))
        #expect(await log.wait())
        watcher.stop()
    }

    @Test func releasingTheWatcherStopsIt() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let log = CallbackLog()
        var watcher: DirectoryWatcher? = makeWatcher(log)
        watcher?.watch(dir.path)
        await log.settle()

        watcher = nil
        makeFile(dir.appending(path: "new.txt"))
        await log.idle(Self.silence)
        #expect(log.count == 0)
        _ = watcher
    }

    // MARK: Paths that can't be watched

    @Test func aMissingPathIsIgnored() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(root.appending(path: "missing").path)
        watcher.watch("")
        watcher.watch("relative/nowhere")
        await log.idle(Self.silence)
        #expect(log.count == 0)

        // Watching a missing path also stops watching the folder before it.
        watcher.watch(dir.path)
        await log.settle()
        watcher.watch(root.appending(path: "missing").path)
        makeFile(dir.appending(path: "new.txt"))
        await log.idle(Self.silence)
        #expect(log.count == 0)
    }

    @Test func aFileIsNotWatched() async throws {
        defer { cleanUp() }
        let file = root.appending(path: "plain.txt")
        makeFile(file)
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(file.path)
        try Data("changed".utf8).write(to: file)
        await log.idle(Self.silence)
        #expect(log.count == 0)
    }

    @Test func anUnreadableFolderIsNotWatched() async throws {
        defer {
            chmod(root.appending(path: "locked").path, 0o755)
            cleanUp()
        }
        let locked = try folder("locked")
        #expect(chmod(locked.path, 0o000) == 0)
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(locked.path)
        #expect(chmod(locked.path, 0o755) == 0)
        makeFile(locked.appending(path: "new.txt"))
        await log.idle(Self.silence)
        #expect(log.count == 0)
    }

    // MARK: The watched folder goes away

    @Test func deletingTheWatchedFolderCallsOnceAndStops() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        makeFile(dir.appending(path: "a.txt"))
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        try FileManager.default.removeItem(at: dir)
        #expect(await log.wait())
        await log.idle(Self.silence)
        #expect(log.count == 1)

        // A new folder at the same path is not watched until `watch` is called again.
        log.reset()
        let again = try folder("dir")
        makeFile(again.appending(path: "b.txt"))
        await log.idle(Self.silence)
        #expect(log.count == 0)
    }

    @Test func renamingTheWatchedFolderCallsOnceAndStops() async throws {
        defer { cleanUp() }
        let dir = try folder("dir")
        let log = CallbackLog()
        let watcher = makeWatcher(log)
        watcher.watch(dir.path)
        await log.settle()

        let moved = root.appending(path: "moved")
        #expect(rename(dir.path, moved.path) == 0)
        #expect(await log.wait())
        await log.idle(Self.silence)
        #expect(log.count == 1)

        log.reset()
        makeFile(moved.appending(path: "c.txt"))
        await log.idle(Self.silence)
        #expect(log.count == 0)
    }

    // MARK: Descriptors

    @Test func descriptorsAreClosed() async throws {
        defer { cleanUp() }
        let first = try folder("first")
        let second = try folder("second")
        let missing = root.appending(path: "missing").path
        let log = CallbackLog()

        // Warm up once so lazily opened framework descriptors aren't counted as leaks.
        do {
            let warm = makeWatcher(log)
            warm.watch(first.path)
            warm.stop()
        }
        try await Task.sleep(for: .milliseconds(50))
        let before = Self.openDescriptorCount()

        let watcher = makeWatcher(log)
        for _ in 0..<100 {
            watcher.watch(first.path)
            watcher.watch(second.path) // re-watch closes the old one
            watcher.watch(missing)
            watcher.watch(first.path)
            watcher.stop()
        }
        for _ in 0..<50 {
            // Released while watching.
            let shortLived = DirectoryWatcher(debounce: Self.debounce) {}
            shortLived.watch(second.path)
        }
        // Streams are released on the watcher's queue a moment after they stop.
        try await Task.sleep(for: .milliseconds(200))
        let after = Self.openDescriptorCount()
        // Other suites open files in parallel, so allow a little noise; a leak would be 100 or more.
        #expect(after - before < 10, "open descriptors went from \(before) to \(after)")
    }

    private static func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }
}
