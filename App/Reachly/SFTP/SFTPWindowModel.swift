import AppKit
import Foundation
import Observation
import SwiftData
import ReachlyCore
import ReachlySSH
import ReachlyTerminal

/// Everything the window owns: both panes, the connections, the queue, open-with.
@MainActor
@Observable
final class SFTPWindowModel {
    enum Side { case left, right }

    /// A Cut pasted on the other side. Once every transfer queued for it completed, what `snapshot` lists is removed
    /// where it is still unchanged; anything added, changed or left out stays, with the folders holding it.
    private struct PendingCut {
        let source: FileItem
        let side: FileSide
        let destinationName: String
        let transfers: [TransferItem]
        let snapshot: CutSource
    }

    /// The rows a Cut put on the clipboard, in the pane they were cut from.
    struct CutRows: Equatable {
        let side: Side
        let source: PaneSource
        let paths: Set<String>
    }

    /// What was queued for one item: its transfers, and for a folder the walk they came from.
    private struct Queued {
        var transfers: [TransferItem]
        var plan: FolderTransfer?

        /// The source paths of what the folder walk left out.
        var skipped: [String] { plan?.skipped ?? [] }
    }

    /// A transfer that could not be queued, with the message to show.
    private struct QueueError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }

    let connections: RemoteConnections
    let queue = TransferQueue()
    let openWith: OpenWithManager
    let left: PaneModel
    let right: PaneModel
    var focusedSide: Side = .right
    /// The pane whose file list has keyboard focus, if one does (not its path field).
    private(set) var focusedFileList: Side?
    var status: String?
    /// True while a paste runs; another paste waits until it is done.
    private(set) var isPasting = false
    /// The files behind `clipboard.items`, by path: transfers and deletes need more than a name.
    @ObservationIgnored private var clipboardFiles: [String: FileItem] = [:]
    @ObservationIgnored private var pendingCuts: [UUID: PendingCut] = [:]
    /// Bumped each time the pending cuts are observed again, so only the newest observation acts.
    @ObservationIgnored private var cutObservation = 0

    init(workspace: Workspace, context: ModelContext) {
        connections = RemoteConnections(workspace: workspace, context: context)
        openWith = OpenWithManager(connections: connections)
        left = PaneModel(backend: LocalBackend())
        right = PaneModel(backend: LocalBackend())
        queue.clientProvider = { [connections] hostID in try await connections.client(for: hostID) }
        queue.onCompleted = { [weak self] item in
            guard let self else { return }
            for pane in [left, right] {
                switch (item.kind, pane.source) {
                case (.download, .local), (.upload, .remote), (.copyBetweenHosts, .remote):
                    Task { await pane.refresh() }
                default: break
                }
            }
            settlePendingCuts()
        }
        openWith.onUploaded = { [weak self] hostID, remotePath in
            self?.refreshPanes(on: .remote(hostID: hostID), showing: [SFTP.parent(remotePath)])
        }
        for (pane, side) in [(left, Side.left), (right, Side.right)] {
            let paneID = pane.id
            pane.onFoldersChanged = { [weak self] source, folders in
                self?.refreshPanes(on: source, showing: folders, except: paneID)
            }
            pane.onLocationChanged = { [weak self] in
                // The cut rows are no longer in view: stop dimming them. The clipboard keeps the Cut.
                if self?.cutRows?.side == side { self?.cutRows = nil }
            }
        }
    }

    func pane(_ side: Side) -> PaneModel { side == .left ? left : right }

    /// A pane reports when its file list gains or loses keyboard focus.
    func fileList(on side: Side, hasFocus: Bool) {
        if hasFocus {
            focusedFileList = side
        } else if focusedFileList == side {
            focusedFileList = nil
        }
    }
    var focusedPane: PaneModel { pane(focusedSide) }
    var otherPane: PaneModel { pane(focusedSide == .left ? .right : .left) }

    func start(hostID: UUID?) async {
        await left.goHome()
        if let hostID { await showHost(hostID, in: .right) } else { await right.goHome() }
    }

    func showHost(_ hostID: UUID, in side: Side) async {
        pane(side).switchBackend(RemoteBackend(hostID: hostID, connections: connections))
    }

    func showLocal(in side: Side) {
        pane(side).switchBackend(LocalBackend())
    }

    /// Refreshes the panes on `source` that show one of `folders`.
    private func refreshPanes(on source: PaneSource, showing folders: Set<String>, except excluded: UUID? = nil) {
        for pane in [left, right] where pane.id != excluded && pane.source == source && folders.contains(pane.path) {
            Task { await pane.refresh() }
        }
    }

    // MARK: Transfers

    /// Copies `items` from one pane into the other pane's folder (or a subfolder dropped on).
    func transfer(_ items: [FileItem], from source: PaneModel, to destination: PaneModel, intoFolder folder: String? = nil) async {
        let targetDirectory = folder ?? destination.path
        switch (source.source, destination.source) {
        case (.local, .local):
            for item in items {
                do {
                    try FileManager.default.copyItem(atPath: item.path, toPath: (targetDirectory as NSString).appendingPathComponent(item.name))
                } catch {
                    status = error.localizedDescription
                }
            }
            await destination.refresh()
        default:
            for item in items {
                do {
                    let queued = try await enqueue(item, from: source.source.fileSide, to: destination.source.fileSide, into: targetDirectory, as: item.name, mayReplace: true)
                    if !queued.skipped.isEmpty { status = Self.leftOutSentence(queued.skipped, of: item.name) }
                } catch {
                    status = "Could not copy “\(FileNaming.displayed(item.name))”: \(PaneModel.describe(error))"
                }
            }
        }
    }

    /// Hands `item` to the queue, landing in `directory` on the other side as `name`. Returns every transfer queued
    /// for it (none for an empty folder, whose folders are made right away) and what its folder walk left out.
    ///
    /// With `mayReplace: false` (Paste) nothing at the destination is replaced: each file is created exclusively and
    /// a clash fails its transfer, and each folder is made new rather than filled when one appeared there since.
    private func enqueue(_ item: FileItem, from source: FileSide, to destination: FileSide, into directory: String, as name: String, mayReplace: Bool) async throws -> Queued {
        switch (source, destination) {
        case (.local, .remote(let hostID)):
            return try await enqueueUpload(item, hostID: hostID, into: directory, as: name, mayReplace: mayReplace)
        case (.remote(let hostID), .local):
            return try await enqueueDownload(item, hostID: hostID, into: URL(fileURLWithPath: directory), as: name, mayReplace: mayReplace)
        case (.remote(let fromHost), .remote(let toHost)):
            return try await enqueueCopy(item, from: fromHost, to: toHost, into: directory, as: name, mayReplace: mayReplace)
        case (.local, .local):
            throw QueueError("“\(item.name)” is already on this Mac.")
        }
    }

    private func enqueueUpload(_ item: FileItem, hostID: UUID, into directory: String, as name: String, mayReplace: Bool) async throws -> Queued {
        let hostName = connections.hostName(hostID)
        let remoteRoot = try TransferPath.child(name, of: directory)
        guard item.isDirectory else {
            return Queued(transfers: [queue.enqueueUpload(hostID: hostID, hostName: hostName, localURL: URL(fileURLWithPath: item.path), to: remoteRoot, mayReplace: mayReplace)])
        }
        let plan: FolderTransfer
        do {
            plan = try await FolderTransfer.plan(from: item.path, to: remoteRoot, list: { try FolderTransfer.listLocal($0) })
        } catch let error as TransferPathError {
            throw error
        } catch {
            // Nothing is left out silently: a Cut removes the original afterwards.
            throw QueueError("Could not read \(item.path): \(PaneModel.describe(error))")
        }
        do {
            let client = try await connections.client(for: hostID)
            try await Self.makeRemoteFolders(plan.folders.map(\.target), with: client, mayExist: mayReplace)
        } catch {
            throw QueueError("Could not create folders on \(hostName): \(PaneModel.describe(error))")
        }
        let transfers = plan.files.map { file in
            queue.enqueueUpload(hostID: hostID, hostName: hostName, localURL: URL(fileURLWithPath: file.source), to: file.target, mayReplace: mayReplace)
        }
        return Queued(transfers: transfers, plan: plan)
    }

    /// Makes the folders a transfer lands in on a host, parents first. With `mayExist`, a folder already there is
    /// used as it is; without, each one must be new, so a paste never fills a folder that appeared since its listing.
    private static func makeRemoteFolders(_ paths: [String], with client: SFTPClient, mayExist: Bool) async throws {
        for path in paths {
            if mayExist {
                if (try? await client.stat(path)) == nil { try await client.makeDirectory(path) }
                continue
            }
            do {
                try await client.makeDirectory(path)
            } catch {
                // OpenSSH answers a plain "Failure" when the name is taken.
                if (try? await client.lstat(path)) != nil { throw QueueError("There's already an item named “\(SFTP.baseName(path))” there.") }
                throw error
            }
        }
    }

    /// Walks a folder on a host for a transfer. A name in it that can't stand for one item stops the transfer before
    /// anything is made (see `FolderTransfer.plan`).
    private func planFromHost(_ item: FileItem, hostID: UUID, to root: String) async throws -> FolderTransfer {
        let backend = RemoteBackend(hostID: hostID, connections: connections)
        do {
            return try await FolderTransfer.plan(from: item.path, to: root, list: { try await backend.listEntries($0) })
        } catch let error as TransferPathError {
            throw error
        } catch {
            throw QueueError("Could not read \(item.path) on \(connections.hostName(hostID)): \(PaneModel.describe(error))")
        }
    }

    private func enqueueDownload(_ item: FileItem, hostID: UUID, into directory: URL, as name: String, mayReplace: Bool) async throws -> Queued {
        let hostName = connections.hostName(hostID)
        let root = try TransferPath.child(name, of: directory.path)
        guard item.isDirectory else {
            return Queued(transfers: [queue.enqueueDownload(hostID: hostID, hostName: hostName, remotePath: item.path, to: URL(fileURLWithPath: root), size: item.size, mayReplace: mayReplace)])
        }
        let plan = try await planFromHost(item, hostID: hostID, to: root)
        do {
            // Without `mayReplace` each folder must be new, so a paste never fills one that appeared since its listing.
            try plan.makeLocalFolders(mayExist: mayReplace)
        } catch {
            throw QueueError("Could not create folders on this Mac: \(PaneModel.describe(error))")
        }
        let transfers = plan.files.map { file in
            queue.enqueueDownload(hostID: hostID, hostName: hostName, remotePath: file.source, to: URL(fileURLWithPath: file.target), size: file.entry.kind == .file ? file.entry.size : nil, mayReplace: mayReplace)
        }
        return Queued(transfers: transfers, plan: plan)
    }

    private func enqueueCopy(_ item: FileItem, from fromHost: UUID, to toHost: UUID, into directory: String, as name: String, mayReplace: Bool) async throws -> Queued {
        let fromName = connections.hostName(fromHost)
        let toName = connections.hostName(toHost)
        let root = try TransferPath.child(name, of: directory)
        guard item.isDirectory else {
            return Queued(transfers: [queue.enqueueCopy(fromHostID: fromHost, fromHostName: fromName, remotePath: item.path, toHostID: toHost, toHostName: toName, targetPath: root, size: item.size, mayReplace: mayReplace)])
        }
        let plan = try await planFromHost(item, hostID: fromHost, to: root)
        do {
            let target = try await connections.client(for: toHost)
            try await Self.makeRemoteFolders(plan.folders.map(\.target), with: target, mayExist: mayReplace)
        } catch {
            throw QueueError("Could not create folders on \(toName): \(PaneModel.describe(error))")
        }
        let transfers = plan.files.map { file in
            queue.enqueueCopy(fromHostID: fromHost, fromHostName: fromName, remotePath: file.source, toHostID: toHost, toHostName: toName, targetPath: file.target, size: file.entry.kind == .file ? file.entry.size : nil, mayReplace: mayReplace)
        }
        return Queued(transfers: transfers, plan: plan)
    }

    /// Opens a file on a host in an app (Open, Open With…), unless no path can stand for its name.
    func openRemoteFile(_ item: FileItem, hostID: UUID, chooseApplication: Bool) async {
        if let problem = item.nameProblem {
            status = "Could not open “\(FileNaming.displayed(item.name))”: Its name can't be used. \(problem)"
            return
        }
        await openWith.open(hostID: hostID, remotePath: item.path, chooseApplication: chooseApplication)
    }

    /// Finder files dropped on a remote pane.
    func upload(urls: [URL], to pane: PaneModel, intoFolder folder: String? = nil) async {
        guard case .remote(let hostID) = pane.source else { return }
        let directory = folder ?? pane.path
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let item = FileItem(name: url.lastPathComponent, path: url.path, isDirectory: isDirectory, isSymlink: false, size: nil, modified: nil, mode: nil, modeString: "", owner: nil)
            do {
                let queued = try await enqueueUpload(item, hostID: hostID, into: directory, as: item.name, mayReplace: true)
                if !queued.skipped.isEmpty { status = Self.leftOutSentence(queued.skipped, of: item.name) }
            } catch {
                status = "Could not upload “\(FileNaming.displayed(item.name))”: \(PaneModel.describe(error))"
            }
        }
    }

    // MARK: Cut and Paste across sides

    /// Deletes the source of each pending Cut whose transfers all completed, and gives up on one (keeping its
    /// source) as soon as any of its transfers failed or was cancelled. Runs from `queue.onCompleted`, after each
    /// paste, and whenever a tracked transfer changes state.
    private func settlePendingCuts() {
        for (id, cut) in pendingCuts {
            let states = cut.transfers.map(\.state)
            if states.allSatisfy({ $0 == .completed }) {
                pendingCuts[id] = nil
                Task { await removeSource(of: cut) }
            } else if states.contains(where: Self.stopsCut) {
                pendingCuts[id] = nil
                status = "Not every file of “\(cut.source.name)” arrived, so the original was kept."
            }
        }
        observePendingCuts()
    }

    private static func stopsCut(_ state: TransferItem.State) -> Bool {
        switch state {
        case .failed, .cancelled: true
        default: false
        }
    }

    /// Calls `settlePendingCuts` once any tracked transfer changes state (a failure doesn't reach `onCompleted`).
    private func observePendingCuts() {
        cutObservation += 1
        guard !pendingCuts.isEmpty else { return }
        let token = cutObservation
        withObservationTracking {
            for cut in pendingCuts.values {
                for transfer in cut.transfers { _ = transfer.state }
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.cutObservation == token else { return }
                self.settlePendingCuts()
            }
        }
    }

    /// Removes what a settled Cut moved, where it is still unchanged (see `CutSource.remove`).
    private func removeSource(of cut: PendingCut) async {
        let removal: CutRemoval
        switch cut.side {
        case .local:
            removal = await Self.removeLocalSource(cut.snapshot)
        case .remote(let hostID):
            do {
                let client = try await connections.client(for: hostID)
                removal = await client.removeCutSource(cut.snapshot)
            } catch {
                status = "Copied “\(FileNaming.displayed(cut.source.name))” to \(cut.destinationName), but could not remove the original: \(PaneModel.describe(error))"
                return
            }
        }
        status = Self.cutSummary(removal, of: cut.source, to: cut.destinationName)
        refreshPanes(on: PaneSource(cut.side), showing: Set([SFTP.parent(cut.source.path)] + cut.snapshot.folders))
    }

    /// Removes a Cut's source on this Mac to the Trash. When a fresh walk finds the cut folder exactly as the paste
    /// saw it, the folder goes as one item; otherwise each unchanged file goes on its own and each emptied folder is
    /// removed, so anything new or changed stays where it is.
    private nonisolated static func removeLocalSource(_ source: CutSource) async -> CutRemoval {
        let manager = FileManager.default
        if let root = source.folders.first,
           let again = try? await FolderTransfer.plan(from: root, to: root, list: { try FolderTransfer.listLocal($0) }),
           source.isExactly(again),
           (try? manager.trashItem(at: URL(fileURLWithPath: root), resultingItemURL: nil)) != nil {
            return CutRemoval(removed: source.files.count + source.folders.count)
        }
        return await source.remove(
            current: { try FolderTransfer.localEntry(atPath: $0) },
            removeFile: { try manager.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil) },
            removeEmptyFolder: { path in
                // rmdir only ever removes an empty folder.
                guard rmdir(path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            })
    }

    /// The item a Cut moves, as lstat sees it now on its side, for a single file or a symlink (a folder's snapshot
    /// is its walk).
    private func snapshot(of item: FileItem, on side: FileSide) async throws -> CutSource {
        let entry: ListedEntry? = switch side {
        case .local: try FolderTransfer.localEntry(atPath: item.path)
        case .remote(let hostID): try await RemoteBackend(hostID: hostID, connections: connections).entry(at: item.path)
        }
        guard let entry else { throw QueueError("“\(FileNaming.displayed(item.name))” is no longer there.") }
        return CutSource(files: [CutSource.File(path: item.path, entry: entry)], folders: [])
    }

    /// What a settled Cut did to its source.
    private static func cutSummary(_ removal: CutRemoval, of source: FileItem, to destination: String) -> String {
        let name = "“\(FileNaming.displayed(source.name))”"
        if removal.isComplete { return "Moved \(name) to \(destination)." }
        var parts = ["Copied \(name) to \(destination)."]
        let changed = removal.changed.count
        let folders = removal.keptFolders.count
        if source.isDirectory, !source.isSymlink {
            if changed > 0 {
                let holding = folders > 0 ? ", with the folders holding them" : ""
                parts.append("\(changed == 1 ? "1 item" : "\(changed) items") changed since the paste and \(changed == 1 ? "was" : "were") kept\(holding).")
            } else if folders > 0 {
                parts.append("\(folders == 1 ? "1 folder" : "\(folders) folders") still \(folders == 1 ? "holds" : "hold") items that weren't moved, so \(folders == 1 ? "it was" : "they were") kept.")
            }
        } else if changed > 0 {
            parts.append("It changed since the paste, so the original was kept.")
        }
        if let first = removal.failures.first {
            let shown = "“\(FileNaming.displayed(SFTP.baseName(first.path)))”"
            parts.append(removal.failures.count == 1
                ? "Could not remove \(shown): \(sentence(first.reason))"
                : "Could not remove \(removal.failures.count) items. \(shown): \(sentence(first.reason))")
        }
        return parts.joined(separator: " ")
    }

    // CONTRACT (stream reachly-files-model implements these; stream reachly-files-ui calls them).

    /// What Copy or Cut last put on the Files clipboard; nil when it is empty.
    private(set) var clipboard: FileClipboard?

    var canPaste: Bool { clipboard != nil && !isPasting }

    /// The rows of the last Cut, shown dimmed in the pane they came from until a paste, a new Copy or Cut, or that
    /// pane moving to another folder or host.
    private(set) var cutRows: CutRows?

    /// True when `item` is one of the cut rows the pane on `side` shows dimmed.
    func isCut(_ item: FileItem, in side: Side) -> Bool {
        guard let cutRows, cutRows.side == side, pane(side).source == cutRows.source else { return false }
        return cutRows.paths.contains(item.path)
    }

    /// Puts the items on the clipboard to be copied by the next Paste.
    func copyToClipboard(_ items: [FileItem], from side: Side) {
        putOnClipboard(items, operation: .copy, from: side)
    }

    /// Puts the items on the clipboard to be moved by the next Paste.
    func cutToClipboard(_ items: [FileItem], from side: Side) {
        putOnClipboard(items, operation: .cut, from: side)
    }

    private func putOnClipboard(_ items: [FileItem], operation: FileClipboard.Operation, from side: Side) {
        guard !items.isEmpty else { return }
        clipboard = FileClipboard(
            operation: operation,
            side: pane(side).source.fileSide,
            items: items.map { FileClipboard.Item(path: $0.path, name: $0.name, isDirectory: $0.isDirectory) })
        clipboardFiles = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        cutRows = operation == .cut ? CutRows(side: side, source: pane(side).source, paths: Set(items.map(\.path))) : nil
        let what = Self.describe(items.map(\.name))
        status = operation == .copy ? "Copied \(what)." : "\(what) cut. Paste to move \(items.count == 1 ? "it" : "them")."
    }

    /// Pastes the clipboard into `folder` on `side` (nil: that pane's current folder), following `PastePlan`.
    func paste(into side: Side, folder: String? = nil) async {
        guard let clipboard, !isPasting else { return }
        // The files behind it as they are now: a Copy or Cut made while this paste waits must not change what it moves.
        let files = clipboardFiles
        isPasting = true
        defer { isPasting = false }
        let cutRowsBefore = cutRows
        let pane = pane(side)
        let backend = pane.backend
        let destinationName = pane.title
        let directory = folder ?? pane.path
        let existingNames: Set<String>
        do {
            existingNames = Set(try await backend.list(directory).map(\.name))
        } catch {
            status = "Could not open \(directory): \(PaneModel.describe(error))"
            return
        }

        var pasted: [String] = []
        var queued: [String] = []
        var skipped: [(name: String, reason: String)] = []
        var failed: [(name: String, reason: String)] = []
        var leftOut: [String] = []
        var changedFolders: Set<String> = [directory]
        let steps = PastePlan.steps(for: clipboard, to: backend.source.fileSide, directory: directory, existingNames: existingNames)
        let copies = steps.filter { if case .copy = $0 { true } else { false } }
        if !copies.isEmpty {
            status = copies.count == 1 ? "Copying…" : "Copying \(copies.count) items…" // a large copy takes a while
        }
        for step in steps {
            switch step {
            case .copy(let from, let to):
                do {
                    try await backend.copy(from, to: to)
                    pasted.append(to)
                } catch {
                    failed.append((SFTP.baseName(from), PaneModel.describe(error)))
                }
            case .move(let from, let to):
                do {
                    try await backend.rename(from, to: to)
                    pasted.append(to)
                    changedFolders.insert(backend.parent(from))
                } catch {
                    failed.append((SFTP.baseName(from), PaneModel.describe(error)))
                }
            case .transfer(let item, let into, let name, let deleteSourceWhenDone):
                let file = files[item.path] ?? FileItem(item)
                do {
                    // A Cut removes only what it moved, as it is now: a file, or a symlink itself (never what it
                    // leads to), is looked at before its transfer starts; a folder's walk is taken as it is queued.
                    let isFolder = file.isDirectory && !file.isSymlink
                    let single = deleteSourceWhenDone && !isFolder ? try await snapshot(of: file, on: clipboard.side) : nil
                    // Paste never replaces: a file that appeared since the listing fails its transfer instead.
                    let result = try await enqueue(file, from: clipboard.side, to: backend.source.fileSide, into: into, as: name, mayReplace: false)
                    queued.append(name)
                    changedFolders.insert(into)
                    if !result.skipped.isEmpty { leftOut.append(Self.leftOutSentence(result.skipped, of: file.name)) }
                    if deleteSourceWhenDone, let snapshot = single ?? result.plan.map(CutSource.init) {
                        pendingCuts[UUID()] = PendingCut(source: file, side: clipboard.side, destinationName: destinationName, transfers: result.transfers, snapshot: snapshot)
                    }
                } catch {
                    failed.append((item.name, PaneModel.describe(error)))
                }
            case .skip(let path, let reason):
                skipped.append((SFTP.baseName(path), reason))
            }
        }
        settlePendingCuts()
        // The paste ends the dimming, unless a Cut made while it ran brought rows of its own.
        if cutRows == cutRowsBefore { cutRows = nil }

        let didSomething = !pasted.isEmpty || !queued.isEmpty
        if clipboard.operation == .cut, didSomething, self.clipboard == clipboard {
            self.clipboard = nil
            clipboardFiles = [:]
        }
        status = ([Self.pasteSummary(
            operation: clipboard.operation, pasted: pasted.map(SFTP.baseName), queued: queued,
            skipped: skipped, failed: failed, destinationName: destinationName)] + leftOut).joined(separator: " ")
        guard didSomething else { return }
        for shown in [left, right] where shown.source == backend.source && changedFolders.contains(shown.path) {
            await shown.refresh()
        }
        if pane.source == backend.source, pane.path == directory { pane.select(pasted) }
    }

    private static func pasteSummary(
        operation: FileClipboard.Operation, pasted: [String], queued: [String],
        skipped: [(name: String, reason: String)], failed: [(name: String, reason: String)], destinationName: String
    ) -> String {
        var parts: [String] = []
        if let first = failed.first {
            parts.append(failed.count == 1
                ? "Could not paste “\(first.name)”: \(first.reason)"
                : "Could not paste \(failed.count) items. “\(first.name)”: \(first.reason)")
        }
        if !pasted.isEmpty {
            parts.append("\(operation == .cut ? "Moved" : "Pasted") \(describe(pasted)).")
        }
        if !queued.isEmpty {
            parts.append(operation == .cut
                ? "Moving \(describe(queued)) to \(destinationName); \(queued.count == 1 ? "the original is" : "the originals are") removed once every file has arrived."
                : "Copying \(describe(queued)) to \(destinationName).")
        }
        if let first = skipped.first {
            parts.append(skipped.count == 1
                ? "Skipped “\(first.name)”: \(sentence(first.reason))"
                : "Skipped \(skipped.count) items: \(sentence(first.reason))")
        }
        return parts.isEmpty ? "Nothing to paste." : parts.joined(separator: " ")
    }

    /// Says what a folder transfer of `name` left out (see `FolderTransfer.skipped`).
    private static func leftOutSentence(_ skipped: [String], of name: String) -> String {
        let what = skipped.count == 1 ? "“\(FileNaming.displayed(SFTP.baseName(skipped[0])))”" : "\(skipped.count) items"
        return "Left out \(what) in “\(FileNaming.displayed(name))”: links to folders and special files aren't copied."
    }

    /// “name” for one item, “3 items” for more.
    private static func describe(_ names: [String]) -> String {
        names.count == 1 ? "“\(names[0])”" : "\(names.count) items"
    }

    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }

    func stop() {
        left.stop()
        right.stop()
        queue.pauseAll()
        openWith.stopAll()
        connections.closeAll()
    }
}

private extension FileItem {
    /// A clipboard item, when the listing it came from is gone.
    init(_ item: FileClipboard.Item) {
        self.init(name: item.name, path: item.path, isDirectory: item.isDirectory, isSymlink: false, size: nil, modified: nil, mode: nil, modeString: "", owner: nil)
    }
}
