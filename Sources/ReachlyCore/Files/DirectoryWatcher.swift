import Foundation

// CONTRACT (stream reachly-dir-watcher implements this; the signatures are fixed).

/// Watches one folder on the Mac and calls `onChange` on the main thread, debounced, when entries in it are
/// added, removed, renamed or changed. Watching a new folder stops watching the old one.
public final class DirectoryWatcher: @unchecked Sendable {
    public init(debounce: Duration = .milliseconds(300), onChange: @escaping @MainActor @Sendable () -> Void) {}

    /// Starts watching `path`; nil stops. A path that can't be watched (missing, unreadable) just isn't watched.
    public func watch(_ path: String?) {}

    public func stop() {}
}
