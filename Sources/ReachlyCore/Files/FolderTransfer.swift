import Foundation

/// Why a transfer was refused before anything was made for it.
public enum TransferPathError: LocalizedError, Equatable, Sendable {
    /// A name that can't stand for one item in a folder ("../x", "a/b", "..", one with a null character, one too
    /// long). `folder` is where a listing showed it; nil for the item being sent itself.
    case unusableName(String, folder: String?, reason: String)
    /// A target that would land outside the folder the transfer was sent to.
    case outside(String, root: String)

    public var errorDescription: String? {
        switch self {
        case .unusableName(let name, let folder, let reason):
            let shown = "“\(FileNaming.displayed(name))”"
            return "\(shown)\(folder.map { " in \($0)" } ?? "") has a name that can't be used. \(reason)"
        case .outside(let path, let root):
            return "“\(FileNaming.displayed(path))” would land outside \(root), so it was not transferred."
        }
    }
}

/// The paths a transfer writes to, built so that nothing lands outside the folder it was sent to. Paths are absolute
/// POSIX paths, on this Mac or on a host.
public enum TransferPath {
    /// The item called `name` in `folder`. Throws when `name` can't stand for one item there.
    public static func child(_ name: String, of folder: String) throws -> String {
        if let reason = FileNaming.pathComponentError(for: name) {
            throw TransferPathError.unusableName(name, folder: nil, reason: reason)
        }
        return try checked(PastePlan.join(PastePlan.normalized(folder), name), root: folder)
    }

    /// True when `path`, written out without "." and ".." parts, is `root` or inside it.
    public static func isInside(_ path: String, root: String) -> Bool {
        let path = PastePlan.normalized(path)
        let root = PastePlan.normalized(root)
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// `path` without "." and ".." parts; throws unless it is `root` or inside it. The last check before a target is
    /// used: the names in it were checked already, so this only fails if something upstream went wrong.
    public static func checked(_ path: String, root: String) throws -> String {
        let normalized = PastePlan.normalized(path)
        guard !normalized.unicodeScalars.contains("\0"), isInside(normalized, root: root) else {
            throw TransferPathError.outside(path, root: PastePlan.normalized(root))
        }
        return normalized
    }
}

/// One item of a folder listing, as a folder transfer needs it.
public struct ListedEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case file, folder, symlink, other }

    public var name: String
    /// What the entry itself is, as lstat reports it.
    public var kind: Kind
    /// For a symlink: true when it leads to a folder.
    public var leadsToFolder: Bool
    /// The size and modification time of the entry itself (lstat), when known.
    public var size: Int64?
    public var modified: Date?

    public init(name: String, kind: Kind, leadsToFolder: Bool = false, size: Int64? = nil, modified: Date? = nil) {
        self.name = name
        self.kind = kind
        self.leadsToFolder = leadsToFolder
        self.size = size
        self.modified = modified
    }
}

/// Everything below a folder being transferred and where each part lands, worked out before anything is made.
public struct FolderTransfer: Sendable, Equatable {
    public struct Folder: Sendable, Equatable {
        public var source: String
        public var target: String
    }

    public struct File: Sendable, Equatable {
        public var source: String
        public var target: String
        /// The file as the walk listed it.
        public var entry: ListedEntry
    }

    /// The folder being sent first, then every folder before what is in it.
    public var folders: [Folder]
    public var files: [File]
    /// Items left out, by source path: symlinks to folders, which are not followed (one can lead back up the tree,
    /// or anywhere), and sockets, devices and pipes, which can't be copied as files.
    public var skipped: [String]

    /// Walks the folder at `source` with `list` and maps every item below it to the same place below `target`. A
    /// symlink to a file is sent as the file it leads to; see `skipped` for what is left out.
    ///
    /// Throws before anything is made when a listing shows a name that can't stand for one item in its folder (a
    /// host can send "../x", "a/b", "..", a name with a null character or one too long): joined to a path, such a
    /// name would reach somewhere else. Every target is also checked to be inside `target`.
    public static func plan(from source: String, to target: String, list: @Sendable (String) async throws -> [ListedEntry]) async throws -> FolderTransfer {
        let root = PastePlan.normalized(target)
        var transfer = FolderTransfer(folders: [Folder(source: PastePlan.normalized(source), target: root)], files: [], skipped: [])
        var pending = [transfer.folders[0]]
        while let folder = pending.popLast() {
            var subfolders: [Folder] = []
            for entry in try await list(folder.source).sorted(by: { $0.name < $1.name }) {
                try Task.checkCancellation()
                if let reason = FileNaming.pathComponentError(for: entry.name) {
                    throw TransferPathError.unusableName(entry.name, folder: folder.source, reason: reason)
                }
                let from = PastePlan.join(folder.source, entry.name)
                let to = try TransferPath.checked(PastePlan.join(folder.target, entry.name), root: root)
                if entry.kind == .folder {
                    subfolders.append(Folder(source: from, target: to))
                } else if entry.kind == .other || (entry.kind == .symlink && entry.leadsToFolder) {
                    transfer.skipped.append(from)
                } else {
                    transfer.files.append(File(source: from, target: to, entry: entry))
                }
            }
            transfer.folders += subfolders
            pending += subfolders.reversed()
        }
        return transfer
    }

    /// Makes the folders on this Mac, the root first. With `mayExist`, a folder already there is used as it is;
    /// without, each one must be new, so a paste never fills a folder that appeared since its listing.
    public func makeLocalFolders(mayExist: Bool) throws {
        for folder in folders {
            try FileManager.default.createDirectory(atPath: folder.target, withIntermediateDirectories: mayExist)
        }
    }

    /// The entries of a folder on this Mac, for `plan`. An entry removed while the folder is read is left out.
    public static func listLocal(_ path: String) throws -> [ListedEntry] {
        let folder = PastePlan.normalized(path)
        var entries: [ListedEntry] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder) {
            if let entry = try localEntry(atPath: PastePlan.join(folder, name)) { entries.append(entry) }
        }
        return entries
    }

    /// The item at `path` on this Mac as lstat sees it, or nil when nothing is there.
    public static func localEntry(atPath path: String) throws -> ListedEntry? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let kind: ListedEntry.Kind = switch info.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .folder
        case S_IFLNK: .symlink
        default: .other
        }
        var leadsToFolder = false
        if kind == .symlink {
            var target = stat()
            leadsToFolder = stat(path, &target) == 0 && target.st_mode & S_IFMT == S_IFDIR
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return ListedEntry(name: (path as NSString).lastPathComponent, kind: kind, leadsToFolder: leadsToFolder, size: Int64(info.st_size), modified: modified)
    }
}
