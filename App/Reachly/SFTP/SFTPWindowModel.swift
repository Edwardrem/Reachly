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

    /// A Cut pasted on the other side: `source` is deleted once every transfer queued for it completed.
    private struct PendingCut {
        let source: FileItem
        let side: FileSide
        let destinationName: String
        let transfers: [TransferItem]
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
        for pane in [left, right] {
            let paneID = pane.id
            pane.onFoldersChanged = { [weak self] source, folders in
                self?.refreshPanes(on: source, showing: folders, except: paneID)
            }
        }
    }

    func pane(_ side: Side) -> PaneModel { side == .left ? left : right }
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
                    _ = try await enqueue(item, from: source.source.fileSide, to: destination.source.fileSide, into: targetDirectory, as: item.name, mayReplace: true)
                } catch {
                    status = error.localizedDescription
                }
            }
        }
    }

    /// Hands `item` to the queue, landing in `directory` on the other side as `name`. Returns every transfer queued
    /// for it: none for an empty folder, whose folders are made right away.
    ///
    /// With `mayReplace: false` (Paste) nothing at the destination is replaced: each file is created exclusively and
    /// a clash fails its transfer, and each folder is made new rather than filled when one appeared there since.
    private func enqueue(_ item: FileItem, from source: FileSide, to destination: FileSide, into directory: String, as name: String, mayReplace: Bool) async throws -> [TransferItem] {
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

    private func enqueueUpload(_ item: FileItem, hostID: UUID, into directory: String, as name: String, mayReplace: Bool) async throws -> [TransferItem] {
        let hostName = connections.hostName(hostID)
        let remoteRoot = SFTP.join(directory, name)
        guard item.isDirectory else {
            return [queue.enqueueUpload(hostID: hostID, hostName: hostName, localURL: URL(fileURLWithPath: item.path), to: remoteRoot, mayReplace: mayReplace)]
        }
        guard let (directories, files) = Self.localTree(at: item.path, remoteRoot: remoteRoot) else {
            throw QueueError("Could not read \(item.path).")
        }
        do {
            let client = try await connections.client(for: hostID)
            try await Self.makeRemoteFolders(directories, with: client, mayExist: mayReplace)
        } catch {
            throw QueueError("Could not create folders on \(hostName): \(PaneModel.describe(error))")
        }
        return files.map { url, remotePath in
            queue.enqueueUpload(hostID: hostID, hostName: hostName, localURL: url, to: remotePath, mayReplace: mayReplace)
        }
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

    /// Every folder and file under `path`, with the remote path each maps to; nil when part of it can't be read, so
    /// nothing is left out silently (a Cut deletes the folder afterwards).
    /// Synchronous because directory enumerators cannot be iterated from async code.
    private nonisolated static func localTree(at path: String, remoteRoot: String) -> (directories: [String], files: [(URL, String)])? {
        var unreadable = false
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey], options: [],
            errorHandler: { _, _ in
                unreadable = true
                return false
            }) else { return nil }
        var directories = [remoteRoot]
        var files: [(URL, String)] = []
        for case let url as URL in enumerator {
            let relative = url.path.dropFirst(path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                directories.append(SFTP.join(remoteRoot, relative))
            } else {
                files.append((url, SFTP.join(remoteRoot, relative)))
            }
        }
        return unreadable ? nil : (directories, files)
    }

    private func enqueueDownload(_ item: FileItem, hostID: UUID, into directory: URL, as name: String, mayReplace: Bool) async throws -> [TransferItem] {
        let hostName = connections.hostName(hostID)
        let root = directory.appending(path: name)
        guard item.isDirectory else {
            return [queue.enqueueDownload(hostID: hostID, hostName: hostName, remotePath: item.path, to: root, size: item.size, mayReplace: mayReplace)]
        }
        let backend = RemoteBackend(hostID: hostID, connections: connections)
        let tree: (directories: [String], files: [(relative: String, item: FileItem)])
        do {
            tree = try await backend.walk(item.path)
        } catch {
            throw QueueError("Could not read \(item.path) on \(hostName): \(error.localizedDescription)")
        }
        do {
            for folder in [root] + tree.directories.map({ root.appending(path: $0) }) {
                // Without intermediate folders this fails when the folder exists, so a paste never fills one that
                // appeared since its listing.
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: mayReplace)
            }
        } catch {
            throw QueueError("Could not create folders on this Mac: \(PaneModel.describe(error))")
        }
        return tree.files.map { relative, file in
            queue.enqueueDownload(hostID: hostID, hostName: hostName, remotePath: file.path, to: root.appending(path: relative), size: file.size, mayReplace: mayReplace)
        }
    }

    private func enqueueCopy(_ item: FileItem, from fromHost: UUID, to toHost: UUID, into directory: String, as name: String, mayReplace: Bool) async throws -> [TransferItem] {
        let fromName = connections.hostName(fromHost)
        let toName = connections.hostName(toHost)
        let root = SFTP.join(directory, name)
        guard item.isDirectory else {
            return [queue.enqueueCopy(fromHostID: fromHost, fromHostName: fromName, remotePath: item.path, toHostID: toHost, toHostName: toName, targetPath: root, size: item.size, mayReplace: mayReplace)]
        }
        let backend = RemoteBackend(hostID: fromHost, connections: connections)
        do {
            let (folders, files) = try await backend.walk(item.path)
            let target = try await connections.client(for: toHost)
            try await Self.makeRemoteFolders([root] + folders.map({ SFTP.join(root, $0) }), with: target, mayExist: mayReplace)
            return files.map { relative, file in
                queue.enqueueCopy(fromHostID: fromHost, fromHostName: fromName, remotePath: file.path, toHostID: toHost, toHostName: toName, targetPath: SFTP.join(root, relative), size: file.size, mayReplace: mayReplace)
            }
        } catch {
            throw QueueError("Could not copy \(item.name): \(PaneModel.describe(error))")
        }
    }

    /// Finder files dropped on a remote pane.
    func upload(urls: [URL], to pane: PaneModel, intoFolder folder: String? = nil) async {
        guard case .remote(let hostID) = pane.source else { return }
        let directory = folder ?? pane.path
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let item = FileItem(name: url.lastPathComponent, path: url.path, isDirectory: isDirectory, isSymlink: false, size: nil, modified: nil, mode: nil, modeString: "", owner: nil)
            do {
                _ = try await enqueueUpload(item, hostID: hostID, into: directory, as: item.name, mayReplace: true)
            } catch {
                status = error.localizedDescription
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

    private func removeSource(of cut: PendingCut) async {
        let backend: any FileSystemBackend = switch cut.side {
        case .local: LocalBackend()
        case .remote(let hostID): RemoteBackend(hostID: hostID, connections: connections)
        }
        do {
            try await backend.delete(cut.source)
            status = "Moved “\(cut.source.name)” to \(cut.destinationName)."
        } catch {
            status = "Copied “\(cut.source.name)” to \(cut.destinationName), but could not remove the original: \(PaneModel.describe(error))"
        }
        refreshPanes(on: PaneSource(cut.side), showing: [backend.parent(cut.source.path)])
    }

    // CONTRACT (stream reachly-files-model implements these; stream reachly-files-ui calls them).

    /// What Copy or Cut last put on the Files clipboard; nil when it is empty.
    private(set) var clipboard: FileClipboard?

    var canPaste: Bool { clipboard != nil && !isPasting }

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
        let what = Self.describe(items.map(\.name))
        status = operation == .copy ? "Copied \(what)." : "Cut \(what). Paste to move \(items.count == 1 ? "it" : "them")."
    }

    /// Pastes the clipboard into `folder` on `side` (nil: that pane's current folder), following `PastePlan`.
    func paste(into side: Side, folder: String? = nil) async {
        guard let clipboard, !isPasting else { return }
        isPasting = true
        defer { isPasting = false }
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
                let file = clipboardFiles[item.path] ?? FileItem(item)
                do {
                    // Paste never replaces: a file that appeared since the listing fails its transfer instead.
                    let transfers = try await enqueue(file, from: clipboard.side, to: backend.source.fileSide, into: into, as: name, mayReplace: false)
                    queued.append(name)
                    changedFolders.insert(into)
                    if deleteSourceWhenDone {
                        pendingCuts[UUID()] = PendingCut(source: file, side: clipboard.side, destinationName: destinationName, transfers: transfers)
                    }
                } catch {
                    failed.append((item.name, PaneModel.describe(error)))
                }
            case .skip(let path, let reason):
                skipped.append((SFTP.baseName(path), reason))
            }
        }
        settlePendingCuts()

        let didSomething = !pasted.isEmpty || !queued.isEmpty
        if clipboard.operation == .cut, didSomething, self.clipboard == clipboard {
            self.clipboard = nil
            clipboardFiles = [:]
        }
        status = Self.pasteSummary(
            operation: clipboard.operation, pasted: pasted.map(SFTP.baseName), queued: queued,
            skipped: skipped, failed: failed, destinationName: destinationName)
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
