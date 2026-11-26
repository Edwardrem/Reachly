import Foundation
import Synchronization

extension SFTPClient {
    /// Whether an upload or download may replace a file already at its destination.
    public enum Overwrite: Sendable {
        /// Create the file or truncate the one there; with `resume`, continue the one there. Drag and drop,
        /// Upload…, Download… and Open With work this way.
        case allowed
        /// Never replace anything. The file is created exclusively (CREAT|EXCL on the server, O_CREAT|O_EXCL on
        /// the Mac) and a clash fails the transfer. `claim` remembers the file once it is made, so a retry or a
        /// resume of the same transfer may write to it again; anything else at the destination is left alone.
        case never(TargetClaim)
    }

    /// The destination file a no-overwrite transfer created, kept across its attempts. Give each transfer its own.
    public final class TargetClaim: Sendable {
        enum Made: Sendable, Equatable {
            case remote(path: String)
            /// A file on this Mac, with its device and inode, so a file put in its place since is not taken for it.
            case local(path: String, identity: LocalFileIdentity)
        }

        private let made = Mutex<Made?>(nil)

        public init() {}

        /// True once the transfer created its destination file.
        public var hasMadeFile: Bool { made.withLock { $0 != nil } }

        var current: Made? { made.withLock { $0 } }

        func record(_ value: Made) {
            made.withLock { $0 = value }
        }
    }

    /// The error for a transfer that stopped because something is already at its destination.
    static func alreadyExists(_ path: String) -> SFTP.Error {
        .status(.failure, "An item with that name already exists", path: path)
    }
}

/// Which file on this Mac a path named when it was opened.
struct LocalFileIdentity: Sendable, Equatable {
    var device: UInt64
    var inode: UInt64

    init(_ info: stat) {
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
    }
}

/// Opens the file on this Mac that a download writes into.
enum LocalTarget {
    /// Opens `url` for writing as `overwrite` allows and returns the handle with the offset to write from: the end
    /// of the file with `resume`, else 0 (the file is then empty).
    static func open(_ url: URL, resume: Bool, overwrite: SFTPClient.Overwrite) throws -> (handle: FileHandle, offset: UInt64) {
        let manager = FileManager.default
        guard case .never(let claim) = overwrite else {
            var offset: UInt64 = 0
            if resume, let existing = try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber {
                offset = existing.uint64Value
            } else {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                manager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: offset)
            return (handle, offset)
        }

        let path = url.path
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if case .local(path, let identity)? = claim.current {
            if let reopened = try reopen(path, identity: identity, resume: resume) { return reopened }
            // The file it made is gone: start again with a new one.
        }
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else {
            let code = errno
            throw code == EEXIST ? SFTPClient.alreadyExists(path) : posixError(code)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw posixError(code)
        }
        claim.record(.local(path: path, identity: LocalFileIdentity(info)))
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), 0)
    }

    /// Opens the file the transfer made before, checking on the open descriptor that it is still that file; nil when
    /// nothing is at `path` any more.
    private static func reopen(_ path: String, identity: LocalFileIdentity, resume: Bool) throws -> (handle: FileHandle, offset: UInt64)? {
        // No O_CREAT, and no following a symlink put in its place.
        let descriptor = Darwin.open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw code == ELOOP ? SFTPClient.alreadyExists(path) : posixError(code)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, LocalFileIdentity(info) == identity else {
            Darwin.close(descriptor)
            throw SFTPClient.alreadyExists(path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard resume else {
            try handle.truncate(atOffset: 0)
            return (handle, 0)
        }
        let offset = UInt64(info.st_size)
        try handle.seek(toOffset: offset)
        return (handle, offset)
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
