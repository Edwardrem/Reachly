import Foundation
import Testing
@testable import ReachlyCore

/// `FolderTransfer.plan` and `TransferPath`, which every folder transfer goes through: Paste and drag and drop
/// between the Mac and a host, and copies between hosts. The listings are fakes, as a real file system can't hold the
/// names a hostile server can send.
@Suite struct FolderTransferTests {
    /// Names no path can stand for, each as a host could list it.
    static let unusableNames = ["../x", "../../.zshenv", "a/b", "..", ".", "/etc/passwd", "a\u{0}b", "", String(repeating: "x", count: 256)]

    /// A listing that answers from `tree`, by folder path.
    private static func listing(_ tree: [String: [ListedEntry]]) -> @Sendable (String) async throws -> [ListedEntry] {
        { path in
            guard let entries = tree[path] else { throw POSIXError(.ENOENT) }
            return entries
        }
    }

    private static func file(_ name: String, size: Int64 = 3) -> ListedEntry {
        ListedEntry(name: name, kind: .file, size: size, modified: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static func folder(_ name: String) -> ListedEntry {
        ListedEntry(name: name, kind: .folder)
    }

    /// /srv/data with a file, an empty folder and a nested folder, with `extra` listed in /srv/data/sub.
    private static func tree(withExtra extra: ListedEntry? = nil) -> [String: [ListedEntry]] {
        [
            "/srv/data": [file("a.txt"), folder("empty"), folder("sub")],
            "/srv/data/empty": [],
            "/srv/data/sub": [file("b.txt"), folder("deeper")] + (extra.map { [$0] } ?? []),
            "/srv/data/sub/deeper": [file("c.txt")],
        ]
    }

    // MARK: The walk

    @Test func mapsEveryItemBelowTheTarget() async throws {
        let plan = try await FolderTransfer.plan(from: "/srv/data", to: "/Users/me/Downloads/data", list: Self.listing(Self.tree()))
        #expect(plan.folders.map(\.target) == [
            "/Users/me/Downloads/data", "/Users/me/Downloads/data/empty", "/Users/me/Downloads/data/sub", "/Users/me/Downloads/data/sub/deeper",
        ])
        #expect(plan.folders.map(\.source) == ["/srv/data", "/srv/data/empty", "/srv/data/sub", "/srv/data/sub/deeper"])
        #expect(Set(plan.files.map { "\($0.source) -> \($0.target)" }) == [
            "/srv/data/a.txt -> /Users/me/Downloads/data/a.txt",
            "/srv/data/sub/b.txt -> /Users/me/Downloads/data/sub/b.txt",
            "/srv/data/sub/deeper/c.txt -> /Users/me/Downloads/data/sub/deeper/c.txt",
        ])
        #expect(plan.files.allSatisfy { $0.entry.size == 3 && $0.entry.modified != nil })
    }

    @Test func foldersComeBeforeWhatIsInThem() async throws {
        let plan = try await FolderTransfer.plan(from: "/srv/data", to: "/dest/data", list: Self.listing(Self.tree()))
        for (index, folder) in plan.folders.enumerated() where index > 0 {
            let parent = (folder.target as NSString).deletingLastPathComponent
            let parentIndex = try #require(plan.folders.firstIndex { $0.target == parent })
            #expect(parentIndex < index, "\(folder.target)")
        }
    }

    @Test func linksToFoldersAndSpecialFilesAreLeftOutAndListed() async throws {
        let tree: [String: [ListedEntry]] = [
            "/srv/data": [
                Self.file("a.txt"),
                ListedEntry(name: "up", kind: .symlink, leadsToFolder: true),
                ListedEntry(name: "note", kind: .symlink, leadsToFolder: false),
                ListedEntry(name: "socket", kind: .other),
            ],
        ]
        // "up" is never listed: a link to a folder is not followed (it could lead back up the tree).
        let plan = try await FolderTransfer.plan(from: "/srv/data", to: "/dest/data", list: Self.listing(tree))
        #expect(plan.skipped == ["/srv/data/socket", "/srv/data/up"])
        #expect(plan.files.map(\.source) == ["/srv/data/a.txt", "/srv/data/note"])
        #expect(plan.folders.map(\.target) == ["/dest/data"])
    }

    @Test func everyUnusableListedNameStopsTheWalkAndIsNamed() async throws {
        for name in Self.unusableNames {
            for entry in [Self.file(name), Self.folder(name)] {
                do {
                    _ = try await FolderTransfer.plan(from: "/srv/data", to: "/dest/data", list: Self.listing(Self.tree(withExtra: entry)))
                    Issue.record("planned a transfer with “\(name.debugDescription)”")
                } catch let error as TransferPathError {
                    guard case .unusableName(name, folder: "/srv/data/sub", let reason) = error else {
                        Issue.record("\(error) for \(name.debugDescription)")
                        continue
                    }
                    #expect(reason == FileNaming.pathComponentError(for: name))
                    let message = error.localizedDescription
                    #expect(message.contains("/srv/data/sub") && message.contains("can't be used"), "\(message)")
                    #expect(!message.unicodeScalars.contains("\0"))
                }
            }
        }
    }

    // MARK: Nothing lands outside the target

    /// Runs what the Files window does for a folder transfer to this Mac: plan, then make the folders.
    private static func transferToThisMac(_ tree: [String: [ListedEntry]], into folder: URL, mayReplace: Bool) async throws {
        let plan = try await FolderTransfer.plan(from: "/srv/data", to: try TransferPath.child("data", of: folder.path), list: listing(tree))
        try plan.makeLocalFolders(mayExist: mayReplace)
    }

    private static func everything(under folder: URL) throws -> [String] {
        let names = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
        return names.sorted()
    }

    @Test func pasteAndDragToThisMacCreateNothingForAnUnusableName() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "reachly-folder-transfer-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = base.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Paste never replaces (mayReplace false); drag and drop and "Download to" may (true).
        for mayReplace in [false, true] {
            for name in Self.unusableNames {
                for entry in [Self.file(name), Self.folder(name)] {
                    await #expect(throws: TransferPathError.self, "\(name.debugDescription)") {
                        try await Self.transferToThisMac(Self.tree(withExtra: entry), into: destination, mayReplace: mayReplace)
                    }
                    #expect(try Self.everything(under: base) == ["Downloads"], "\(name.debugDescription)")
                }
            }
        }
        // The same tree without the bad name lands inside the folder only.
        try await Self.transferToThisMac(Self.tree(), into: destination, mayReplace: false)
        #expect(try Self.everything(under: base) == ["Downloads", "Downloads/data", "Downloads/data/empty", "Downloads/data/sub", "Downloads/data/sub/deeper"])
    }

    @Test func hostToHostRefusesBeforeMakingAFolder() async throws {
        for name in Self.unusableNames {
            var made: [String] = []
            do {
                // What the Files window does for a copy between hosts: plan, then make each folder on the target.
                let plan = try await FolderTransfer.plan(from: "/srv/data", to: try TransferPath.child("data", of: "/home/b"), list: Self.listing(Self.tree(withExtra: Self.folder(name))))
                made = plan.folders.map(\.target)
                Issue.record("planned a copy with “\(name.debugDescription)”")
            } catch {
                #expect(error is TransferPathError, "\(error)")
            }
            #expect(made.isEmpty)
        }
    }

    // MARK: TransferPath

    @Test func childRefusesAnUnusableTopLevelName() throws {
        // The name of the item being sent: drag and drop lands it under its own name.
        for name in Self.unusableNames {
            #expect(throws: TransferPathError.unusableName(name, folder: nil, reason: FileNaming.pathComponentError(for: name)!)) {
                try TransferPath.child(name, of: "/Users/me/Downloads")
            }
        }
        #expect(try TransferPath.child("report.txt", of: "/Users/me/Downloads/") == "/Users/me/Downloads/report.txt")
        #expect(try TransferPath.child("report.txt", of: "/") == "/report.txt")
        #expect(try TransferPath.child("  ", of: "/a") == "/a/  ")
    }

    @Test func checkedRefusesAPathOutsideItsRoot() throws {
        #expect(try TransferPath.checked("/a/b/c/./d", root: "/a/b") == "/a/b/c/d")
        #expect(try TransferPath.checked("/a/b", root: "/a/b/") == "/a/b")
        #expect(throws: TransferPathError.self) { try TransferPath.checked("/a/b/../c", root: "/a/b") }
        #expect(throws: TransferPathError.self) { try TransferPath.checked("/a/b/../../../etc/passwd", root: "/a/b") }
        #expect(throws: TransferPathError.self) { try TransferPath.checked("/a/b2/x", root: "/a/b") }
        #expect(throws: TransferPathError.self) { try TransferPath.checked("/a/b/x\u{0}", root: "/a/b") }
        #expect(try TransferPath.checked("/anything", root: "/") == "/anything")
        #expect(TransferPath.isInside("/a/src/x", root: "/a/src"))
        #expect(!TransferPath.isInside("/a/src2", root: "/a/src"))
    }

    // MARK: Listing this Mac

    @Test func listsLocalEntriesAsTheyAre() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "reachly-list-local-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base.appending(path: "folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("hello".utf8).write(to: base.appending(path: "file.txt"))
        try FileManager.default.createSymbolicLink(atPath: base.appending(path: "to-folder").path, withDestinationPath: base.appending(path: "folder").path)
        try FileManager.default.createSymbolicLink(atPath: base.appending(path: "to-file").path, withDestinationPath: "file.txt")

        let entries = Dictionary(uniqueKeysWithValues: try FolderTransfer.listLocal(base.path).map { ($0.name, $0) })
        #expect(entries.keys.sorted() == ["file.txt", "folder", "to-file", "to-folder"])
        #expect(entries["file.txt"]?.kind == .file && entries["file.txt"]?.size == 5)
        #expect(entries["folder"]?.kind == .folder)
        #expect(entries["to-folder"]?.kind == .symlink && entries["to-folder"]?.leadsToFolder == true)
        #expect(entries["to-file"]?.kind == .symlink && entries["to-file"]?.leadsToFolder == false)
        #expect(try FolderTransfer.localEntry(atPath: base.appending(path: "missing").path) == nil)
    }
}
