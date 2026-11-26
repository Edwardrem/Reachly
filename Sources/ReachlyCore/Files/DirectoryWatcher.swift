import CoreServices
import Foundation
import Synchronization

// CONTRACT (stream reachly-dir-watcher implements this; the signatures are fixed).

/// Watches one folder on the Mac and calls `onChange` on the main thread, debounced, when entries in it are
/// added, removed, renamed or changed. Watching a new folder stops watching the old one.
///
/// Built on FSEvents at folder level rather than a kqueue (`O_EVTONLY`) source on the folder: a kqueue source only
/// sees entries being added, removed or renamed, while FSEvents also reports a file in the folder being written in
/// place or getting new permissions, which change the size, date and mode the pane shows. Changes below a
/// subfolder are ignored. If the watched folder itself is deleted, renamed or unmounted, the watcher stops and calls
/// `onChange` once so the pane can reload and show what happened; call `watch` again after a successful reload.
///
/// `@unchecked Sendable` is safe: the only stored property is the `Core`, which is thread-safe (see there).
public final class DirectoryWatcher: @unchecked Sendable {
    private let core: Core

    public init(debounce: Duration = .milliseconds(300), onChange: @escaping @MainActor @Sendable () -> Void) {
        core = Core(debounce: debounce, onChange: onChange)
    }

    deinit {
        core.onQueue { core.stop() }
    }

    /// Starts watching `path`; nil stops. A path that can't be watched (missing, unreadable) just isn't watched.
    public func watch(_ path: String?) {
        core.onQueue { core.watch(path) }
    }

    public func stop() {
        core.onQueue { core.stop() }
    }
}

/// The watcher's state and its FSEvents stream.
///
/// `@unchecked Sendable` is safe: every mutable stored property is read and written only on `queue` (callers go
/// through `onQueue`, and FSEvents delivers its callbacks there), and `generation`, the one value the main thread
/// reads, is atomic.
private final class Core: @unchecked Sendable {
    private let debounce: Duration
    private let onChange: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "io.github.edwardrem.reachly.directory-watcher")
    private let queueKey = DispatchSpecificKey<Void>()
    /// Bumped by every `watch` and `stop`; a callback scheduled under an older value is dropped.
    private let generation = Atomic<UInt64>(0)

    // Only touched on `queue`.
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private var pendingCallback: DispatchWorkItem?
    /// Stopped streams waiting to be released on the next turn of the queue, never inside their own callback.
    private var retired: [FSEventStreamRef] = []

    /// How long FSEvents gathers events before delivering them; the debounce does the real coalescing.
    private static let latency: CFTimeInterval = 0.05

    init(debounce: Duration, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())
    }

    func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    // MARK: On the queue

    func watch(_ path: String?) {
        guard let path, let resolved = Self.watchableFolder(path) else {
            stop()
            return
        }
        if resolved == watchedPath, stream != nil { return }
        detach()
        let current = generation.add(1, ordering: .sequentiallyConsistent).newValue
        start(resolved, generation: current)
    }

    func stop() {
        detach()
        generation.add(1, ordering: .sequentiallyConsistent)
    }

    private func start(_ path: String, generation: UInt64) {
        let token = Token(core: self, generation: generation)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(token).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Token>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Token>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let token = Unmanaged<Token>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let events = (0..<min(count, list.count)).map { (path: list[$0], flags: flags[$0]) }
                token.core.handle(events, generation: token.generation)
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags)
        guard let created else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        stream = created
        watchedPath = path
        if !FSEventStreamStart(created) { detach() }
    }

    /// Stops the stream and drops any pending callback. The stream is released on the next turn of the queue, as
    /// this can run inside the stream's own callback.
    private func detach() {
        pendingCallback?.cancel()
        pendingCallback = nil
        watchedPath = nil
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        retired.append(stream)
        queue.async { [self] in
            for stream in retired { FSEventStreamRelease(stream) }
            retired.removeAll()
        }
    }

    private func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)], generation expected: UInt64) {
        guard let root = watchedPath, generation.load(ordering: .sequentiallyConsistent) == expected else { return }
        let rootGone = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount)
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        var changed = false
        for event in events {
            if event.flags & rootGone != 0 {
                // The folder was deleted, renamed or unmounted: stop, and tell the pane once, now.
                detach()
                deliver(generation: expected)
                return
            }
            if event.flags & dropped != 0 || Self.samePath(event.path, root) { changed = true }
        }
        if changed { scheduleCallback(generation: expected) }
    }

    /// At most one callback per debounce window: the first change opens the window, the callback runs when it
    /// closes, and changes in between ride along.
    private func scheduleCallback(generation expected: UInt64) {
        guard pendingCallback == nil else { return }
        let item = DispatchWorkItem { [self] in
            pendingCallback = nil
            deliver(generation: expected)
        }
        pendingCallback = item
        queue.asyncAfter(deadline: .now() + Self.dispatchInterval(debounce), execute: item)
    }

    private func deliver(generation expected: UInt64) {
        DispatchQueue.main.async { [self] in
            guard generation.load(ordering: .sequentiallyConsistent) == expected else { return }
            MainActor.assumeIsolated { onChange() }
        }
    }

    // MARK: Helpers

    /// The folder's real path (FSEvents reports "/private/var/…" for "/var/…"), or nil when it is not a folder this
    /// process can open and list.
    private static func watchableFolder(_ path: String) -> String? {
        let descriptor = open(path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        close(descriptor)
        guard access(path, R_OK | X_OK) == 0, let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// FSEvents ends folder paths with a slash; letter case is ignored because the Mac's disks usually do.
    private static func samePath(_ eventPath: String, _ root: String) -> Bool {
        var trimmed = Substring(eventPath)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return trimmed.caseInsensitiveCompare(root) == .orderedSame
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        let nanoseconds = min(max(seconds, 0), 86_400) * 1_000_000_000 + max(attoseconds, 0) / 1_000_000_000
        return .nanoseconds(Int(nanoseconds))
    }
}

/// What the FSEvents callback gets back: the core, and which `watch` call the stream belongs to. Retained by the
/// stream, so the core outlives every callback; only used on the core's queue.
private final class Token {
    let core: Core
    let generation: UInt64

    init(core: Core, generation: UInt64) {
        self.core = core
        self.generation = generation
    }
}
