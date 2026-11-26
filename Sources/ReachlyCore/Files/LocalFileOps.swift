import Foundation

/// Moves and copies on this Mac that never replace anything and never put a folder inside itself.
public enum LocalFileOps {
    /// Why a move or copy was refused before anything was done.
    public struct Refusal: LocalizedError, Equatable {
        public let errorDescription: String?

        static let intoItself = Refusal(errorDescription: "A folder can't go inside itself.")
    }

    /// Renames or moves `path` to `newPath`, failing with EEXIST when anything is already there. RENAME_EXCL makes
    /// "is the name free?" and the rename one step, so nothing that appeared there since is replaced. Across volumes,
    /// or on a file system without RENAME_EXCL, it falls back to `moveItem`, which copies when it must and refuses a
    /// target that exists by then.
    public static func move(_ path: String, to newPath: String) throws {
        try refuseFolderIntoItself(path, newPath)
        guard renamex_np(path, newPath, UInt32(RENAME_EXCL)) != 0 else { return }
        let code = errno
        guard code == EXDEV || code == ENOTSUP else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        try FileManager.default.moveItem(atPath: path, toPath: newPath)
    }

    /// Throws when `path` is a folder and `newPath` is that folder or inside it. Each folder `newPath` would sit in
    /// is compared with the source by device and inode, so neither a symlink on the way ("link/sub", where "link"
    /// leads to "src") nor another case of a name ("SRC/sub" on a volume that ignores case) can hide it. Only the
    /// same name in the same place counts as the folder itself: "src" to "Src" is a rename. A symlink to a folder is
    /// copied or moved as the link itself, so it is never refused.
    public static func refuseFolderIntoItself(_ path: String, _ newPath: String) throws {
        guard (try? FolderTransfer.localEntry(atPath: path))?.kind == .folder,
              let source = FileID(path), let resolvedSource = realPath(path),
              let parent = realPath((newPath as NSString).deletingLastPathComponent) else { return }
        if (parent as NSString).appendingPathComponent((newPath as NSString).lastPathComponent) == resolvedSource {
            throw Refusal.intoItself
        }
        var folder = parent
        while true {
            if FileID(folder) == source { throw Refusal.intoItself }
            let up = (folder as NSString).deletingLastPathComponent
            if up == folder || up.isEmpty { return }
            folder = up
        }
    }

    /// Which file a path names, by device and inode; a final symlink is not followed.
    struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t

        init?(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// `path` with every symlink resolved, or nil when it doesn't exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
