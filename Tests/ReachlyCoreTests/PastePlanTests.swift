import Foundation
import Testing
@testable import ReachlyCore

@Suite struct PastePlanTests {
    private let hostA = FileSide.remote(hostID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
    private let hostB = FileSide.remote(hostID: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)

    private func file(_ path: String) -> FileClipboard.Item {
        FileClipboard.Item(path: path, name: String(path.split(separator: "/").last ?? ""), isDirectory: false)
    }

    private func folder(_ path: String) -> FileClipboard.Item {
        FileClipboard.Item(path: path, name: String(path.split(separator: "/").last ?? ""), isDirectory: true)
    }

    private func plan(_ operation: FileClipboard.Operation, _ items: [FileClipboard.Item], from source: FileSide = .local, to side: FileSide = .local, into directory: String, existing: Set<String> = []) -> [PasteStep] {
        PastePlan.steps(for: FileClipboard(operation: operation, side: source, items: items), to: side, directory: directory, existingNames: existing)
    }

    // MARK: Same side, Copy

    @Test func copyIntoAnotherFolder() {
        #expect(plan(.copy, [file("/a/report.txt")], into: "/b") == [.copy(from: "/a/report.txt", to: "/b/report.txt")])
        #expect(plan(.copy, [folder("/a/src")], into: "/b") == [.copy(from: "/a/src", to: "/b/src")])
    }

    @Test func copyIntoItsOwnFolderGetsACopyName() {
        #expect(plan(.copy, [file("/a/report.txt")], into: "/a", existing: ["report.txt"]) == [.copy(from: "/a/report.txt", to: "/a/report copy.txt")])
        #expect(plan(.copy, [file("/a/report.txt")], into: "/a", existing: ["report.txt", "report copy.txt"]) == [.copy(from: "/a/report.txt", to: "/a/report copy 2.txt")])
        #expect(plan(.copy, [folder("/a/src")], into: "/a", existing: ["src"]) == [.copy(from: "/a/src", to: "/a/src copy")])
    }

    @Test func copyIntoItsOwnFolderWithAStaleListingStillGetsACopyName() {
        // The caller's listing doesn't have the item yet; the plan must still not target the source itself.
        #expect(plan(.copy, [file("/a/report.txt")], into: "/a", existing: []) == [.copy(from: "/a/report.txt", to: "/a/report copy.txt")])
        #expect(plan(.copy, [file("/a/report copy.txt")], into: "/a", existing: []) == [.copy(from: "/a/report copy.txt", to: "/a/report copy 2.txt")])
    }

    @Test func copyClashGetsACopyName() {
        #expect(plan(.copy, [file("/a/report.txt")], into: "/b", existing: ["report.txt"]) == [.copy(from: "/a/report.txt", to: "/b/report copy.txt")])
        #expect(plan(.copy, [folder("/a/src")], into: "/b", existing: ["src", "src copy"]) == [.copy(from: "/a/src", to: "/b/src copy 2")])
    }

    @Test func copyClashIgnoresLetterCase() {
        #expect(plan(.copy, [file("/a/README.md")], into: "/b", existing: ["readme.md"]) == [.copy(from: "/a/README.md", to: "/b/README copy.md")])
    }

    @Test func copyWithManyClashes() {
        var existing: Set<String> = ["report.txt", "report copy.txt"]
        for number in 2...30 { existing.insert("report copy \(number).txt") }
        #expect(plan(.copy, [file("/a/report.txt")], into: "/b", existing: existing) == [.copy(from: "/a/report.txt", to: "/b/report copy 31.txt")])
    }

    // MARK: Same side, Cut

    @Test func cutMovesIntoAnotherFolder() {
        #expect(plan(.cut, [file("/a/report.txt")], into: "/b") == [.move(from: "/a/report.txt", to: "/b/report.txt")])
        #expect(plan(.cut, [folder("/a/src")], into: "/b/deep/er") == [.move(from: "/a/src", to: "/b/deep/er/src")])
    }

    @Test func cutIntoTheSameFolderIsSkipped() {
        #expect(plan(.cut, [file("/a/report.txt")], into: "/a", existing: ["report.txt"]) == [.skip(path: "/a/report.txt", reason: "Already in this folder")])
        #expect(plan(.cut, [folder("/a/src")], into: "/a/", existing: ["src"]) == [.skip(path: "/a/src", reason: "Already in this folder")])
    }

    @Test func cutClashGetsACopyNameNeverAnOverwrite() {
        #expect(plan(.cut, [file("/a/report.txt")], into: "/b", existing: ["report.txt"]) == [.move(from: "/a/report.txt", to: "/b/report copy.txt")])
        #expect(plan(.cut, [folder("/a/src")], into: "/b", existing: ["src", "src copy"]) == [.move(from: "/a/src", to: "/b/src copy 2")])
    }

    // MARK: A folder into itself

    @Test func aFolderIntoItselfIsSkipped() {
        for operation in [FileClipboard.Operation.copy, .cut] {
            #expect(plan(operation, [folder("/a/src")], into: "/a/src") == [.skip(path: "/a/src", reason: "Can't put a folder inside itself")])
            #expect(plan(operation, [folder("/a/src")], into: "/a/src/lib") == [.skip(path: "/a/src", reason: "Can't put a folder inside itself")])
            #expect(plan(operation, [folder("/a/src")], into: "/a/src/lib/deeper/") == [.skip(path: "/a/src", reason: "Can't put a folder inside itself")])
        }
    }

    @Test func aSiblingThatStartsWithTheSameTextIsAllowed() {
        #expect(plan(.copy, [folder("/a/src")], into: "/a/src2") == [.copy(from: "/a/src", to: "/a/src2/src")])
        #expect(plan(.cut, [folder("/a/src")], into: "/a/src2") == [.move(from: "/a/src", to: "/a/src2/src")])
        #expect(plan(.cut, [folder("/a/src")], into: "/a/src copy") == [.move(from: "/a/src", to: "/a/src copy/src")])
    }

    @Test func aFileCanGoIntoAFolderNamedLikeIt() {
        #expect(plan(.copy, [file("/a/notes")], into: "/a/notes.d") == [.copy(from: "/a/notes", to: "/a/notes.d/notes")])
    }

    @Test func theRootFolderCanNotBePastedAnywhereOnItsSide() {
        #expect(plan(.copy, [FileClipboard.Item(path: "/", name: "/", isDirectory: true)], into: "/tmp") == [.skip(path: "/", reason: "Can't put a folder inside itself")])
    }

    @Test func aFolderIntoItselfAcrossSidesIsATransfer() {
        // The same path on another machine is a different folder.
        let item = folder("/a/src")
        #expect(plan(.copy, [item], from: .local, to: hostA, into: "/a/src") == [.transfer(item: item, directory: "/a/src", name: "src", deleteSourceWhenDone: false)])
    }

    // MARK: Paths

    @Test func theRootFolderJoinsWithOneSlash() {
        #expect(plan(.copy, [file("/etc/hosts")], into: "/") == [.copy(from: "/etc/hosts", to: "/hosts")])
        #expect(plan(.cut, [file("/etc/hosts")], into: "/") == [.move(from: "/etc/hosts", to: "/hosts")])
        #expect(plan(.copy, [file("/hosts")], into: "/", existing: ["hosts"]) == [.copy(from: "/hosts", to: "/hosts copy")])
        #expect(plan(.cut, [file("/hosts")], into: "/", existing: ["hosts"]) == [.skip(path: "/hosts", reason: "Already in this folder")])
        #expect(plan(.copy, [folder("/srv")], into: "/", existing: ["srv"]) == [.copy(from: "/srv", to: "/srv copy")])
    }

    @Test func trailingAndRepeatedSlashesAreIgnored() {
        #expect(plan(.copy, [folder("/a/src/")], into: "/b/") == [.copy(from: "/a/src", to: "/b/src")])
        #expect(plan(.copy, [file("/a//report.txt")], into: "//b//c//") == [.copy(from: "/a/report.txt", to: "/b/c/report.txt")])
        #expect(plan(.cut, [file("/a/report.txt")], into: "/a//") == [.skip(path: "/a/report.txt", reason: "Already in this folder")])
        #expect(plan(.copy, [folder("/a/src/")], into: "/a/src/") == [.skip(path: "/a/src", reason: "Can't put a folder inside itself")])
        #expect(plan(.copy, [file("/a/report.txt")], into: "///", existing: []) == [.copy(from: "/a/report.txt", to: "/report.txt")])
    }

    @Test func dotSegmentsAreResolved() {
        #expect(plan(.copy, [folder("/a/src")], into: "/a/b/../src/lib") == [.skip(path: "/a/src", reason: "Can't put a folder inside itself")])
        #expect(plan(.cut, [file("/a/report.txt")], into: "/a/./") == [.skip(path: "/a/report.txt", reason: "Already in this folder")])
    }

    @Test func anItemWithoutANameUsesItsPath() {
        let item = FileClipboard.Item(path: "/a/report.txt", name: "", isDirectory: false)
        #expect(plan(.copy, [item], into: "/b") == [.copy(from: "/a/report.txt", to: "/b/report.txt")])
    }

    // MARK: Several items

    @Test func twoItemsWithTheSameNameGetDifferentNames() {
        let items = [file("/x/a.txt"), file("/y/a.txt")]
        #expect(plan(.copy, items, into: "/z") == [
            .copy(from: "/x/a.txt", to: "/z/a.txt"),
            .copy(from: "/y/a.txt", to: "/z/a copy.txt"),
        ])
        #expect(plan(.cut, items, into: "/z", existing: ["a.txt"]) == [
            .move(from: "/x/a.txt", to: "/z/a copy.txt"),
            .move(from: "/y/a.txt", to: "/z/a copy 2.txt"),
        ])
        #expect(plan(.copy, items, from: .local, to: hostA, into: "/z") == [
            .transfer(item: items[0], directory: "/z", name: "a.txt", deleteSourceWhenDone: false),
            .transfer(item: items[1], directory: "/z", name: "a 2.txt", deleteSourceWhenDone: false),
        ])
    }

    @Test func aCopyIntoItsOwnFolderAndAnotherWithTheSameNameDontCollide() {
        // "/z/a.txt" duplicated and "/y/a.txt" pasted next to it in one go.
        let items = [file("/z/a.txt"), file("/y/a.txt")]
        #expect(plan(.copy, items, into: "/z", existing: ["a.txt"]) == [
            .copy(from: "/z/a.txt", to: "/z/a copy.txt"),
            .copy(from: "/y/a.txt", to: "/z/a copy 2.txt"),
        ])
    }

    @Test func skippedItemsDontTakeANameAndOrderIsKept() {
        let items = [folder("/a/src"), file("/b/src"), file("/a/src/x.txt"), file("/c/x.txt")]
        #expect(plan(.cut, items, into: "/a/src", existing: ["x.txt"]) == [
            .skip(path: "/a/src", reason: "Can't put a folder inside itself"),
            .move(from: "/b/src", to: "/a/src/src"),
            .skip(path: "/a/src/x.txt", reason: "Already in this folder"),
            .move(from: "/c/x.txt", to: "/a/src/x copy.txt"),
        ])
    }

    @Test func existingNamesAreNotChangedForTheCaller() {
        let existing: Set<String> = ["a.txt"]
        _ = plan(.copy, [file("/x/a.txt")], into: "/z", existing: existing)
        #expect(existing == ["a.txt"])
    }

    // MARK: Sides

    @Test func theSameHostIsTheSameSide() {
        #expect(plan(.copy, [file("/a/report.txt")], from: hostA, to: hostA, into: "/b") == [.copy(from: "/a/report.txt", to: "/b/report.txt")])
        #expect(plan(.cut, [file("/a/report.txt")], from: hostA, to: hostA, into: "/b") == [.move(from: "/a/report.txt", to: "/b/report.txt")])
        #expect(plan(.cut, [file("/a/report.txt")], from: hostA, to: hostA, into: "/a") == [.skip(path: "/a/report.txt", reason: "Already in this folder")])
    }

    @Test func copyAcrossSidesIsATransferThatKeepsTheSource() {
        let item = file("/Users/me/report.txt")
        #expect(plan(.copy, [item], from: .local, to: hostA, into: "/home/me") == [.transfer(item: item, directory: "/home/me", name: "report.txt", deleteSourceWhenDone: false)])
        #expect(plan(.copy, [item], from: hostA, to: .local, into: "/Users/me/Downloads") == [.transfer(item: item, directory: "/Users/me/Downloads", name: "report.txt", deleteSourceWhenDone: false)])
        #expect(plan(.copy, [item], from: hostA, to: hostB, into: "/srv") == [.transfer(item: item, directory: "/srv", name: "report.txt", deleteSourceWhenDone: false)])
    }

    @Test func cutAcrossSidesDeletesTheSourceOnlyWhenDone() {
        let item = folder("/Users/me/site")
        #expect(plan(.cut, [item], from: .local, to: hostA, into: "/var/www/") == [.transfer(item: item, directory: "/var/www", name: "site", deleteSourceWhenDone: true)])
        #expect(plan(.cut, [item], from: hostB, to: hostA, into: "/var/www") == [.transfer(item: item, directory: "/var/www", name: "site", deleteSourceWhenDone: true)])
    }

    @Test func aTransferClashGetsAUniqueName() {
        let report = file("/Users/me/report.txt")
        #expect(plan(.copy, [report], from: .local, to: hostA, into: "/home/me", existing: ["report.txt"]) == [.transfer(item: report, directory: "/home/me", name: "report 2.txt", deleteSourceWhenDone: false)])
        #expect(plan(.cut, [report], from: .local, to: hostA, into: "/home/me", existing: ["report.txt", "report 2.txt"]) == [.transfer(item: report, directory: "/home/me", name: "report 3.txt", deleteSourceWhenDone: true)])
        // Folders are not split at a dot.
        let photos = folder("/Users/me/photos.2024")
        #expect(plan(.copy, [photos], from: .local, to: hostA, into: "/home/me", existing: ["photos.2024"]) == [.transfer(item: photos, directory: "/home/me", name: "photos.2024 2", deleteSourceWhenDone: false)])
    }

    @Test func aTransferIntoTheRootFolder() {
        let item = file("/Users/me/report.txt")
        #expect(plan(.copy, [item], from: .local, to: hostA, into: "/") == [.transfer(item: item, directory: "/", name: "report.txt", deleteSourceWhenDone: false)])
    }

    @Test func anEmptyClipboardPlansNothing() {
        #expect(plan(.copy, [], into: "/a").isEmpty)
    }

    // MARK: Names no path can stand for

    @Test func anUnusableNameIsSkippedAndNamedOnEverySide() {
        // A host can list such a name; landing it would write outside the folder pasted into.
        for name in ["../x", "../../.zshenv", "a/b", "..", "a\u{0}b", String(repeating: "x", count: 256)] {
            let item = FileClipboard.Item(path: "/srv/data/" + name, name: name, isDirectory: false)
            let pairs: [(FileSide, FileSide)] = [(hostA, .local), (.local, hostA), (hostA, hostB), (hostA, hostA)]
            for (from, to) in pairs {
                for operation in [FileClipboard.Operation.copy, .cut] {
                    let steps = plan(operation, [item], from: from, to: to, into: "/Users/me/Downloads")
                    guard case .skip(_, let reason)? = steps.first, steps.count == 1 else {
                        Issue.record("\(steps) for \(name.debugDescription)")
                        continue
                    }
                    #expect(reason.contains("“\(FileNaming.displayed(name))”") && reason.contains("can't be used"), "\(reason)")
                }
            }
        }
    }

    @Test func anUnusableNameDoesNotStopTheRestOfThePaste() {
        let good = file("/srv/data/report.txt")
        let bad = FileClipboard.Item(path: "/srv/data/x", name: "../x", isDirectory: false)
        let steps = plan(.copy, [bad, good], from: hostA, to: .local, into: "/Users/me")
        #expect(steps.count == 2)
        #expect(steps.last == .transfer(item: good, directory: "/Users/me", name: "report.txt", deleteSourceWhenDone: false))
    }
}
