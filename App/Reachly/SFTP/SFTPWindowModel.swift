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

    let connections: RemoteConnections
    let queue = TransferQueue()
    let openWith: OpenWithManager
    let left: PaneModel
    let right: PaneModel
    var focusedSide: Side = .right
    var status: String?

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

    // MARK: Transfers

    /// Copies `items` from one pane into the other pane's folder (or a subfolder dropped on).
    func transfer(_ items: [FileItem], from source: PaneModel, to destination: PaneModel, intoFolder folder: String? = nil) async {
        let targetDirectory = folder ?? destination.path
        switch (source.source, destination.source) {
        case (.local, .remote(let hostID)):
            for item in items { await enqueueUpload(item, hostID: hostID, into: targetDirectory) }
        case (.remote(let hostID), .local):
            for item in items { await enqueueDownload(item, hostID: hostID, into: URL(fileURLWithPath: targetDirectory)) }
        case (.remote(let fromHost), .remote(let toHost)):
            for item in items { await enqueueCopy(item, from: fromHost, to: toHost, into: targetDirectory) }
        case (.local, .local):
            for item in items {
                do {
                    try FileManager.default.copyItem(atPath: item.path, toPath: (targetDirectory as NSString).appendingPathComponent(item.name))
                } catch {
                    status = error.localizedDescription
                }
            }
            await destination.refresh()
        }
    }

    private func enqueueUpload(_ item: FileItem, hostID: UUID, into directory: String) async {
        let hostName = connections.hostName(hostID)
        if item.isDirectory {
            let remoteRoot = SFTP.join(directory, item.name)
            guard let (directories, files) = Self.localTree(at: item.path, remoteRoot: remoteRoot) else { return }
            do {
                let client = try await connections.client(for: hostID)
                for path in directories {
                    if (try? await client.stat(path)) == nil { try await client.makeDirectory(path) }
                }
            } catch {
                status = "Could not create folders on \(hostName): \(error.localizedDescription)"
                return
            }
            for (url, remotePath) in files {
                queue.enqueueUpload(hostID: hostID, hostName: hostName, localURL: url, to: remotePath)
            }
        } else {
            queue.enqueueUpload(hostID: hostID, hostName: hostName, localURL: URL(fileURLWithPath: item.path), to: SFTP.join(directory, item.name))
        }
    }

    /// Every folder and file under `path`, with the remote path each maps to.
    /// Synchronous because directory enumerators cannot be iterated from async code.
    private nonisolated static func localTree(at path: String, remoteRoot: String) -> (directories: [String], files: [(URL, String)])? {
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
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
        return (directories, files)
    }

    private func enqueueDownload(_ item: FileItem, hostID: UUID, into directory: URL) async {
        let hostName = connections.hostName(hostID)
        if item.isDirectory {
            let backend = RemoteBackend(hostID: hostID, connections: connections)
            do {
                let files = try await backend.walk(item.path)
                let root = directory.appending(path: item.name)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                for (relative, file) in files {
                    let local = root.appending(path: relative)
                    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                    queue.enqueueDownload(hostID: hostID, hostName: hostName, remotePath: file.path, to: local, size: file.size)
                }
            } catch {
                status = "Could not read \(item.path) on \(hostName): \(error.localizedDescription)"
            }
        } else {
            queue.enqueueDownload(hostID: hostID, hostName: hostName, remotePath: item.path, to: directory.appending(path: item.name), size: item.size)
        }
    }

    private func enqueueCopy(_ item: FileItem, from fromHost: UUID, to toHost: UUID, into directory: String) async {
        let fromName = connections.hostName(fromHost)
        let toName = connections.hostName(toHost)
        if item.isDirectory {
            let backend = RemoteBackend(hostID: fromHost, connections: connections)
            do {
                let files = try await backend.walk(item.path)
                let target = try await connections.client(for: toHost)
                let root = SFTP.join(directory, item.name)
                var created: Set<String> = []
                for (relative, _) in files {
                    var folder = SFTP.parent(SFTP.join(root, relative))
                    var chain: [String] = []
                    while folder != "/" && folder.hasPrefix(root) && !created.contains(folder) {
                        chain.insert(folder, at: 0)
                        folder = SFTP.parent(folder)
                    }
                    for path in chain where !created.contains(path) {
                        if (try? await target.stat(path)) == nil { try await target.makeDirectory(path) }
                        created.insert(path)
                    }
                }
                for (relative, file) in files {
                    queue.enqueueCopy(fromHostID: fromHost, fromHostName: fromName, remotePath: file.path, toHostID: toHost, toHostName: toName, targetPath: SFTP.join(root, relative), size: file.size)
                }
            } catch {
                status = "Could not copy \(item.name): \(error.localizedDescription)"
            }
        } else {
            queue.enqueueCopy(fromHostID: fromHost, fromHostName: fromName, remotePath: item.path, toHostID: toHost, toHostName: toName, targetPath: SFTP.join(directory, item.name), size: item.size)
        }
    }

    /// Finder files dropped on a remote pane.
    func upload(urls: [URL], to pane: PaneModel, intoFolder folder: String? = nil) async {
        guard case .remote(let hostID) = pane.source else { return }
        let directory = folder ?? pane.path
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let item = FileItem(name: url.lastPathComponent, path: url.path, isDirectory: isDirectory, isSymlink: false, size: nil, modified: nil, mode: nil, modeString: "", owner: nil)
            await enqueueUpload(item, hostID: hostID, into: directory)
        }
    }

    // CONTRACT (stream reachly-files-model implements these; stream reachly-files-ui calls them).

    /// What Copy or Cut last put on the Files clipboard; nil when it is empty.
    private(set) var clipboard: FileClipboard?

    var canPaste: Bool { clipboard != nil }

    /// Puts the items on the clipboard to be copied by the next Paste.
    func copyToClipboard(_ items: [FileItem], from side: Side) {
        status = "Copy is not available yet."
    }

    /// Puts the items on the clipboard to be moved by the next Paste.
    func cutToClipboard(_ items: [FileItem], from side: Side) {
        status = "Cut is not available yet."
    }

    /// Pastes the clipboard into `folder` on `side` (nil: that pane's current folder), following `PastePlan`.
    func paste(into side: Side, folder: String? = nil) async {
        status = "Paste is not available yet."
    }

    func stop() {
        queue.pauseAll()
        openWith.stopAll()
        connections.closeAll()
    }
}
