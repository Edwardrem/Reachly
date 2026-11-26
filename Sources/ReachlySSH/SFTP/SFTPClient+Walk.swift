import Foundation
import ReachlyCore

extension ListedEntry {
    /// An entry as an SFTP listing or lstat describes it.
    init(name: String, attributes: SFTP.Attributes, leadsToFolder: Bool = false) {
        let kind: Kind = switch attributes.kind {
        case .regular: .file
        case .directory: .folder
        case .symlink: .symlink
        case .other: .other
        }
        self.init(name: name, kind: kind, leadsToFolder: leadsToFolder, size: attributes.size.map { Int64(clamping: $0) }, modified: attributes.modificationTime)
    }
}

extension SFTPClient {
    /// The entries of `path` as a folder transfer walks them (`FolderTransfer.plan`): what each entry is itself (the
    /// server lists lstat attributes), and for a symlink whether it leads to a folder.
    public func listEntries(_ path: String) async throws -> [ListedEntry] {
        var entries: [ListedEntry] = []
        for entry in try await listDirectory(path) {
            var attributes = entry.attributes
            var leadsToFolder = false
            // Never build a path from a name that can't stand for one item: the walk refuses it instead.
            if FileNaming.pathComponentError(for: entry.name) == nil {
                let full = SFTP.join(path, entry.name)
                // A server that leaves the type out of a listing is asked directly.
                if attributes.permissions == nil, let checked = try? await lstat(full) { attributes = checked }
                if attributes.isSymlink { leadsToFolder = (try? await stat(full))?.isDirectory ?? false }
            }
            entries.append(ListedEntry(name: entry.name, attributes: attributes, leadsToFolder: leadsToFolder))
        }
        return entries
    }

    /// The item at `path` as lstat sees it, or nil when nothing is there.
    public func entry(at path: String) async throws -> ListedEntry? {
        do {
            return ListedEntry(name: SFTP.baseName(path), attributes: try await lstat(path))
        } catch let error as SFTP.Error where error.isNoSuchFile {
            return nil
        }
    }

    /// Removes what is unchanged of a Cut's source on this server (see `CutSource.remove`): each file only while it
    /// is still the one the paste saw, then each emptied folder. Never removes anything recursively.
    public func removeCutSource(_ source: CutSource) async -> CutRemoval {
        await source.remove(
            current: { try await self.entry(at: $0) },
            removeFile: { try await self.remove($0) },
            removeEmptyFolder: { try await self.removeDirectory($0) })
    }
}
