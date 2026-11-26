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

    /// Throws when `path` is a folder and `newPath` is that folder or inside it, judged on resolved paths so a
    /// symlink on the way can't hide it (pasting "src" into "link/sub", where "link" leads to "src"). A symlink to a
    /// folder is copied or moved as the link itself, so it is never refused.
    public static func refuseFolderIntoItself(_ path: String, _ newPath: String) throws {
        guard (try? FolderTransfer.localEntry(atPath: path))?.kind == .folder,
              let source = realPath(path),
              let parent = realPath((newPath as NSString).deletingLastPathComponent) else { return }
        let target = (parent as NSString).appendingPathComponent((newPath as NSString).lastPathComponent)
        if TransferPath.isInside(target, root: source) { throw Refusal.intoItself }
    }

    /// `path` with every symlink resolved, or nil when it doesn't exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
