import Foundation

// CONTRACT (stream reachly-files-core implements this; the types and signatures are fixed).

/// Which side of the Files window a path lives on.
public enum FileSide: Hashable, Sendable {
    case local
    case remote(hostID: UUID)
}

/// What Copy or Cut put on the Files window's clipboard.
public struct FileClipboard: Equatable, Sendable {
    public enum Operation: Equatable, Sendable { case copy, cut }

    public struct Item: Equatable, Hashable, Sendable {
        public var path: String
        public var name: String
        public var isDirectory: Bool

        public init(path: String, name: String, isDirectory: Bool) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
        }
    }

    public var operation: Operation
    public var side: FileSide
    public var items: [Item]

    public init(operation: Operation, side: FileSide, items: [Item]) {
        self.operation = operation
        self.side = side
        self.items = items
    }
}

/// One thing to do for a paste. Paths are absolute POSIX paths on their side.
public enum PasteStep: Equatable, Sendable {
    /// Same side: copy `from` to `to` (a local copy, or `SFTPClient.copyItem` on the same host).
    case copy(from: String, to: String)
    /// Same side: move `from` to `to` (a rename).
    case move(from: String, to: String)
    /// Other side: hand `item` to the transfer queue, landing in `directory` as `name`. For Cut,
    /// `deleteSourceWhenDone` is true: the source is deleted only after everything for it transferred.
    case transfer(item: FileClipboard.Item, directory: String, name: String, deleteSourceWhenDone: Bool)
    /// Nothing to do for `path`, with the reason to show (a folder into itself, Cut and Paste into the same folder…).
    case skip(path: String, reason: String)
}

public enum PastePlan {
    /// The steps that paste `clipboard` into `directory` on `side`. `existingNames` are the names already in
    /// `directory`. Never plans an overwrite: a clash gets `FileNaming.copyName`. Pure: no I/O.
    public static func steps(for clipboard: FileClipboard, to side: FileSide, directory: String, existingNames: Set<String>) -> [PasteStep] {
        let destination = normalized(directory)
        let sameSide = clipboard.side == side
        // The names in the folder plus the ones this paste has chosen, so two items called "a.txt" from different
        // folders don't land on the same name.
        var taken = existingNames
        var steps: [PasteStep] = []
        for item in clipboard.items {
            let source = normalized(item.path)
            let name = item.name.isEmpty ? lastComponent(source) : item.name
            guard sameSide else {
                let landing = FileNaming.uniqueName(name, isDirectory: item.isDirectory, existing: taken)
                taken.insert(landing)
                steps.append(.transfer(item: item, directory: destination, name: landing, deleteSourceWhenDone: clipboard.operation == .cut))
                continue
            }
            if item.isDirectory, isSameOrInside(destination, folder: source) {
                steps.append(.skip(path: source, reason: insideItselfReason))
                continue
            }
            let inOwnFolder = parent(of: source) == destination
            switch clipboard.operation {
            case .copy:
                var landing = name
                if inOwnFolder || FileNaming.clashes(name, with: taken) {
                    // The item itself counts as taken even when the listing the caller passed is stale.
                    landing = FileNaming.copyName(for: name, isDirectory: item.isDirectory, existing: taken.union([name]))
                }
                taken.insert(landing)
                steps.append(.copy(from: source, to: join(destination, landing)))
            case .cut:
                if inOwnFolder {
                    steps.append(.skip(path: source, reason: alreadyHereReason))
                    continue
                }
                var landing = name
                if FileNaming.clashes(name, with: taken) {
                    landing = FileNaming.copyName(for: name, isDirectory: item.isDirectory, existing: taken)
                }
                taken.insert(landing)
                steps.append(.move(from: source, to: join(destination, landing)))
            }
        }
        return steps
    }

    static let insideItselfReason = "Can't put a folder inside itself"
    static let alreadyHereReason = "Already in this folder"

    // MARK: POSIX paths

    /// An absolute path without repeated or trailing slashes, "." or ".."; "/" stays "/".
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The folder holding a normalized path: "/" for "/a" and for "/".
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    /// Joins a normalized folder and one name with a single slash.
    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// True when `path` is `folder` or anywhere below it. "/a/src2" is not inside "/a/src"; everything is inside "/".
    static func isSameOrInside(_ path: String, folder: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }
}
