import Foundation

/// What a Cut to the other side moves, as it was when it was pasted. Once every transfer for it arrived, the source
/// is removed only where it is still exactly that: a file added, changed or replaced since stays, and so does the
/// folder holding it.
public struct CutSource: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public var path: String
        /// The file as the walk listed it, or as lstat saw it for a single file.
        public var entry: ListedEntry

        public init(path: String, entry: ListedEntry) {
            self.path = path
            self.entry = entry
        }
    }

    /// The files (and symlinks) that were transferred.
    public var files: [File]
    /// The folders walked, the cut folder first and every folder before what is in it; empty for a single file.
    public var folders: [String]

    public init(files: [File], folders: [String]) {
        self.files = files
        self.folders = folders
    }

    /// The cut folder as `FolderTransfer.plan` walked it. What the walk left out is not part of it, so it stays.
    public init(_ transfer: FolderTransfer) {
        files = transfer.files.map { File(path: $0.source, entry: $0.entry) }
        folders = transfer.folders.map(\.source)
    }

    /// True when `now` is the same file the paste saw: still a file (or still a symlink), with the same size and
    /// modification time. Unknown values never match.
    public static func isUnchanged(_ then: ListedEntry, now: ListedEntry?) -> Bool {
        guard let now, then.kind == .file || then.kind == .symlink, now.kind == then.kind else { return false }
        guard let size = then.size, let modified = then.modified else { return false }
        return now.size == size && now.modified == modified
    }

    /// True when a fresh walk of the cut folder finds exactly what the paste saw: the same folders, the same files
    /// unchanged, and nothing new or left out. Then the folder may go as one item (to the Trash on this Mac).
    public func isExactly(_ again: FolderTransfer) -> Bool {
        guard again.skipped.isEmpty, Set(again.folders.map(\.source)) == Set(folders), again.files.count == files.count else { return false }
        let now = Dictionary(again.files.map { ($0.source, $0.entry) }, uniquingKeysWith: { first, _ in first })
        return files.allSatisfy { Self.isUnchanged($0.entry, now: now[$0.path]) }
    }

    /// Removes what is unchanged since the paste: each file only when `current` shows it is still the one the paste
    /// saw, then each walked folder, deepest first, with `removeEmptyFolder`, which must fail for a folder that is not
    /// empty. Nothing is ever removed recursively, so a folder with anything new or changed in it stays.
    public func remove(
        current: (String) async throws -> ListedEntry?,
        removeFile: (String) async throws -> Void,
        removeEmptyFolder: (String) async throws -> Void
    ) async -> CutRemoval {
        var result = CutRemoval()
        for file in files {
            do {
                let now = try await current(file.path)
                if now == nil { continue } // already gone
                guard Self.isUnchanged(file.entry, now: now) else {
                    result.changed.append(file.path)
                    continue
                }
                try await removeFile(file.path)
                result.removed += 1
            } catch {
                result.failures.append(CutRemoval.Failure(path: file.path, reason: error.localizedDescription))
            }
        }
        for folder in folders.reversed() {
            do {
                try await removeEmptyFolder(folder)
                result.removed += 1
            } catch {
                // Not empty (something new or changed is in it), or gone already.
                if (try? await current(folder)) != nil { result.keptFolders.append(folder) }
            }
        }
        return result
    }
}

/// What removing a Cut's source did.
public struct CutRemoval: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var path: String
        public var reason: String
    }

    /// Files and folders removed.
    public var removed = 0
    /// Files kept because they changed, were replaced or are no longer a file since the paste.
    public var changed: [String] = []
    /// Folders kept because something is still in them.
    public var keptFolders: [String] = []
    /// Files that could not be checked or removed.
    public var failures: [Failure] = []

    public init(removed: Int = 0) {
        self.removed = removed
    }

    /// True when the whole source is gone.
    public var isComplete: Bool { changed.isEmpty && keptFolders.isEmpty && failures.isEmpty }
}
