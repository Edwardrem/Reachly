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
        []
    }
}
