import Foundation
import Synchronization
import Testing
@testable import ReachlyCore

/// `CutSource`: after a Cut to the other side arrived, only what is unchanged since the paste is removed. The file
/// system here is a fake; `SFTPFileOpsLiveTests` runs the same removal against a real server.
@Suite struct CutSourceTests {
    /// A fake file system: entries by path. Folders refuse to be removed while anything is below them.
    private final class FakeDisk: Sendable {
        private let entries: Mutex<[String: ListedEntry]>
        private let log = Mutex<[String]>([])

        init(_ entries: [String: ListedEntry]) {
            self.entries = Mutex(entries)
        }

        var paths: [String] { entries.withLock { $0.keys.sorted() } }
        var removals: [String] { log.withLock { $0 } }

        func set(_ path: String, _ entry: ListedEntry?) {
            entries.withLock { $0[path] = entry }
        }

        func current(_ path: String) -> ListedEntry? {
            entries.withLock { $0[path] }
        }

        func removeFile(_ path: String) throws {
            try entries.withLock { table in
                guard let entry = table[path], entry.kind != .folder else { throw POSIXError(.ENOENT) }
                table[path] = nil
            }
            log.withLock { $0.append(path) }
        }

        func removeEmptyFolder(_ path: String) throws {
            try entries.withLock { table in
                guard table[path]?.kind == .folder else { throw POSIXError(.ENOENT) }
                guard !table.keys.contains(where: { $0.hasPrefix(path + "/") }) else { throw POSIXError(.ENOTEMPTY) }
                table[path] = nil
            }
            log.withLock { $0.append(path) }
        }

        func remove(_ source: CutSource) async -> CutRemoval {
            await source.remove(current: { self.current($0) }, removeFile: { try self.removeFile($0) }, removeEmptyFolder: { try self.removeEmptyFolder($0) })
        }
    }

    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    private static func file(_ name: String, size: Int64 = 10, modified: Date = date) -> ListedEntry {
        ListedEntry(name: name, kind: .file, size: size, modified: modified)
    }

    private static func folder(_ name: String) -> ListedEntry {
        ListedEntry(name: name, kind: .folder)
    }

    /// /src with a.txt, b.txt, sub/c.txt and an empty folder, as on the fake disk and as the paste saw it.
    private static func cutFolder() -> (FakeDisk, CutSource) {
        let entries: [String: ListedEntry] = [
            "/src": folder("src"), "/src/a.txt": file("a.txt"), "/src/b.txt": file("b.txt"),
            "/src/sub": folder("sub"), "/src/sub/c.txt": file("c.txt"), "/src/empty": folder("empty"),
        ]
        let snapshot = CutSource(
            files: ["/src/a.txt", "/src/b.txt", "/src/sub/c.txt"].map { CutSource.File(path: $0, entry: entries[$0]!) },
            folders: ["/src", "/src/empty", "/src/sub"])
        return (FakeDisk(entries), snapshot)
    }

    @Test func removesEverythingUnchangedFilesFirstThenFoldersDeepestFirst() async {
        let (disk, snapshot) = Self.cutFolder()
        let removal = await disk.remove(snapshot)
        #expect(removal.isComplete && removal.removed == 6)
        #expect(disk.paths.isEmpty)
        #expect(disk.removals == ["/src/a.txt", "/src/b.txt", "/src/sub/c.txt", "/src/sub", "/src/empty", "/src"])
    }

    @Test func aFileAddedSinceThePasteStaysWithItsFolder() async {
        let (disk, snapshot) = Self.cutFolder()
        disk.set("/src/sub/new.txt", Self.file("new.txt"))
        let removal = await disk.remove(snapshot)
        #expect(disk.paths == ["/src", "/src/sub", "/src/sub/new.txt"])
        #expect(removal.changed.isEmpty)
        #expect(removal.keptFolders == ["/src/sub", "/src"])
        #expect(!removal.isComplete)
    }

    @Test func aFileThatChangedSinceThePasteStays() async {
        for changed in [Self.file("b.txt", size: 11), Self.file("b.txt", modified: Self.date + 1), Self.folder("b.txt"),
                        ListedEntry(name: "b.txt", kind: .symlink, size: 10, modified: Self.date)] {
            let (disk, snapshot) = Self.cutFolder()
            disk.set("/src/b.txt", changed)
            let removal = await disk.remove(snapshot)
            #expect(removal.changed == ["/src/b.txt"], "\(changed)")
            #expect(disk.paths == ["/src", "/src/b.txt"], "\(changed)")
            #expect(removal.keptFolders == ["/src"])
        }
    }

    @Test func somethingAlreadyGoneIsNotCountedAsKept() async {
        let (disk, snapshot) = Self.cutFolder()
        disk.set("/src/a.txt", nil)
        disk.set("/src/empty", nil)
        let removal = await disk.remove(snapshot)
        #expect(removal.isComplete && disk.paths.isEmpty)
    }

    @Test func unknownSizesOrDatesNeverMatch() {
        let known = Self.file("a")
        #expect(CutSource.isUnchanged(known, now: known))
        #expect(!CutSource.isUnchanged(ListedEntry(name: "a", kind: .file, size: nil, modified: Self.date), now: ListedEntry(name: "a", kind: .file, size: nil, modified: Self.date)))
        #expect(!CutSource.isUnchanged(ListedEntry(name: "a", kind: .file, size: 10), now: ListedEntry(name: "a", kind: .file, size: 10)))
        #expect(!CutSource.isUnchanged(Self.folder("a"), now: Self.folder("a")))
        #expect(!CutSource.isUnchanged(ListedEntry(name: "a", kind: .other, size: 0, modified: Self.date), now: ListedEntry(name: "a", kind: .other, size: 0, modified: Self.date)))
        #expect(!CutSource.isUnchanged(known, now: nil))
    }

    @Test func aFileThatCantBeRemovedIsReported() async {
        let (disk, snapshot) = Self.cutFolder()
        let removal = await snapshot.remove(
            current: { disk.current($0) },
            removeFile: { path in
                if path == "/src/a.txt" { throw POSIXError(.EACCES) }
                try disk.removeFile(path)
            },
            removeEmptyFolder: { try disk.removeEmptyFolder($0) })
        #expect(removal.failures.map(\.path) == ["/src/a.txt"])
        #expect(disk.paths == ["/src", "/src/a.txt"])
    }

    @Test func aSingleFileIsRemovedOnlyWhileUnchanged() async {
        let disk = FakeDisk(["/a.txt": Self.file("a.txt")])
        let snapshot = CutSource(files: [CutSource.File(path: "/a.txt", entry: Self.file("a.txt"))], folders: [])
        disk.set("/a.txt", Self.file("a.txt", size: 99))
        #expect(await disk.remove(snapshot).changed == ["/a.txt"])
        disk.set("/a.txt", Self.file("a.txt"))
        #expect(await disk.remove(snapshot).isComplete)
        #expect(disk.paths.isEmpty)
    }

    // MARK: A fresh walk

    @Test func aFreshWalkMatchesOnlyWhenNothingChanged() async throws {
        let tree: [String: [ListedEntry]] = [
            "/src": [Self.file("a.txt"), Self.folder("sub")],
            "/src/sub": [Self.file("c.txt")],
        ]
        func walk(_ tree: [String: [ListedEntry]]) async throws -> FolderTransfer {
            try await FolderTransfer.plan(from: "/src", to: "/src", list: { tree[$0] ?? [] })
        }
        func changing(_ change: (inout [String: [ListedEntry]]) -> Void) -> [String: [ListedEntry]] {
            var copy = tree
            change(&copy)
            return copy
        }
        let snapshot = CutSource(try await walk(tree))
        #expect(snapshot.folders == ["/src", "/src/sub"])
        #expect(snapshot.isExactly(try await walk(tree)))
        #expect(!snapshot.isExactly(try await walk(changing { $0["/src/sub"]!.append(Self.file("new.txt")) })))
        #expect(!snapshot.isExactly(try await walk(changing { $0["/src"]![0] = Self.file("a.txt", size: 11) })))
        #expect(!snapshot.isExactly(try await walk(changing { $0["/src/sub"]!.append(ListedEntry(name: "up", kind: .symlink, leadsToFolder: true)) })))
        #expect(!snapshot.isExactly(try await walk(changing { $0["/src/sub"] = [] })))
    }
}
