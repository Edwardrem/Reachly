import AppKit
import Foundation
import Observation
import SwiftData
import ReachlyCore
import ReachlySSH
import ReachlyTerminal
import UniformTypeIdentifiers

/// One row in a file pane, whichever side it is on.
struct FileItem: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64?
    let modified: Date?
    /// Permission bits (`0o644`), when known.
    let mode: UInt32?
    let modeString: String
    let owner: String?

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }

    var sizeDescription: String {
        guard !isDirectory, let size else { return isDirectory ? "—" : "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var icon: String {
        if isSymlink { return "link" }
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
            if type.conforms(to: .archive) { return "doc.zipper" }
            if type.conforms(to: .text) { return "doc.text" }
        }
        return "doc"
    }
}

/// What a pane browses: a folder on the Mac, or a host over SFTP.
enum PaneSource: Equatable, Hashable {
    case local
    case remote(hostID: UUID)

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    var hostID: UUID? {
        if case .remote(let id) = self { return id }
        return nil
    }
}

/// The operations a pane needs from either side.
@MainActor
protocol FileSystemBackend: AnyObject {
    var source: PaneSource { get }
    var displayName: String { get }
    func homePath() async throws -> String
    func list(_ path: String) async throws -> [FileItem]
    func makeDirectory(_ path: String) async throws
    func delete(_ item: FileItem) async throws
    func rename(_ path: String, to newPath: String) async throws
    func setMode(_ mode: UInt32, path: String) async throws
    func join(_ base: String, _ component: String) -> String
    func parent(_ path: String) -> String
}

@MainActor
final class LocalBackend: FileSystemBackend {
    let source = PaneSource.local
    let displayName = "This Mac"

    func homePath() async throws -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    func list(_ path: String) async throws -> [FileItem] {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [])
        return urls.map { entry in
            let values = try? entry.resourceValues(forKeys: keys)
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path)
            let permissions = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value
            let isDirectory = values?.isDirectory ?? false
            var attrs = SFTP.Attributes(permissions: permissions.map { $0 | (isDirectory ? 0o040000 : 0o100000) })
            if values?.isSymbolicLink == true { attrs.permissions = (permissions ?? 0) | 0o120000 }
            return FileItem(
                name: entry.lastPathComponent,
                path: entry.path,
                isDirectory: isDirectory,
                isSymlink: values?.isSymbolicLink ?? false,
                size: (values?.fileSize).map(Int64.init),
                modified: values?.contentModificationDate,
                mode: permissions.map { $0 & 0o7777 },
                modeString: attrs.modeString,
                owner: attributes?[.ownerAccountName] as? String)
        }
    }

    func makeDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    func delete(_ item: FileItem) async throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
    }

    func rename(_ path: String, to newPath: String) async throws {
        try FileManager.default.moveItem(atPath: path, toPath: newPath)
    }

    func setMode(_ mode: UInt32, path: String) async throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)
    }

    func join(_ base: String, _ component: String) -> String {
        component.hasPrefix("/") ? component : (base as NSString).appendingPathComponent(component)
    }

    func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent
    }
}

/// Keeps one SFTP client per host, opened on the host's session connection
/// (a tab is opened when the host has none) and reopened after reconnects.
@MainActor
@Observable
final class RemoteConnections {
    private let workspace: Workspace
    private let context: ModelContext
    private var clients: [UUID: SFTPClient] = [:]
    private var opening: [UUID: Task<SFTPClient, Error>] = [:]

    init(workspace: Workspace, context: ModelContext) {
        self.workspace = workspace
        self.context = context
    }

    func host(_ id: UUID) -> SSHHost? {
        let descriptor = FetchDescriptor<SSHHost>(predicate: #Predicate { $0.uuid == id })
        return try? context.fetch(descriptor).first
    }

    func hostName(_ id: UUID) -> String {
        host(id)?.name ?? "host"
    }

    func client(for hostID: UUID) async throws -> SFTPClient {
        if let client = clients[hostID], client.isOpen, client.connection.isActive { return client }
        if let task = opening[hostID] { return try await task.value }
        let task = Task<SFTPClient, Error> { [self] in
            guard let host = host(hostID) else { throw SFTP.Error.protocolError("the host no longer exists") }
            let session = workspace.reuseOrOpen(host: HostDescriptor(host))
            guard let connection = await session.waitForConnection() else {
                throw SSHClientError.connectionFailed(sessionFailure(session))
            }
            let client = try await SFTPClient.open(on: connection)
            clients[hostID] = client
            return client
        }
        opening[hostID] = task
        defer { opening[hostID] = nil }
        return try await task.value
    }

    private func sessionFailure(_ session: TerminalSession) -> String {
        if case .failed(let message) = session.state { return message }
        return "the host is not connected"
    }

    func closeAll() {
        for client in clients.values { client.close() }
        clients.removeAll()
    }
}

@MainActor
final class RemoteBackend: FileSystemBackend {
    let hostID: UUID
    let displayName: String
    private let connections: RemoteConnections

    var source: PaneSource { .remote(hostID: hostID) }

    init(hostID: UUID, connections: RemoteConnections) {
        self.hostID = hostID
        self.connections = connections
        displayName = connections.hostName(hostID)
    }

    private func client() async throws -> SFTPClient {
        try await connections.client(for: hostID)
    }

    func homePath() async throws -> String {
        try await client().realPath(".")
    }

    func list(_ path: String) async throws -> [FileItem] {
        let client = try await client()
        let entries = try await client.listDirectory(path)
        var items: [FileItem] = []
        for entry in entries {
            var attributes = entry.attributes
            var isDirectory = attributes.isDirectory
            if attributes.isSymlink, let target = try? await client.stat(SFTP.join(path, entry.name)) {
                isDirectory = target.isDirectory
                if attributes.size == nil { attributes.size = target.size }
            }
            items.append(FileItem(
                name: entry.name,
                path: SFTP.join(path, entry.name),
                isDirectory: isDirectory,
                isSymlink: attributes.isSymlink,
                size: attributes.size.map(Int64.init),
                modified: attributes.modificationTime,
                mode: attributes.mode,
                modeString: attributes.modeString,
                owner: entry.ownerAndGroup.map { "\($0.0):\($0.1)" }))
        }
        return items
    }

    func makeDirectory(_ path: String) async throws {
        try await client().makeDirectory(path)
    }

    func delete(_ item: FileItem) async throws {
        let client = try await client()
        if item.isDirectory, !item.isSymlink {
            try await client.removeRecursively(item.path)
        } else {
            try await client.remove(item.path)
        }
    }

    func rename(_ path: String, to newPath: String) async throws {
        try await client().rename(path, to: newPath)
    }

    func setMode(_ mode: UInt32, path: String) async throws {
        try await client().setPermissions(mode, path: path)
    }

    func join(_ base: String, _ component: String) -> String { SFTP.join(base, component) }
    func parent(_ path: String) -> String { SFTP.parent(path) }

    /// Every file under `path`, with paths relative to it, for folder downloads.
    func walk(_ path: String) async throws -> [(relative: String, item: FileItem)] {
        var out: [(String, FileItem)] = []
        func visit(_ directory: String, prefix: String) async throws {
            for item in try await list(directory) {
                try Task.checkCancellation()
                let relative = prefix.isEmpty ? item.name : prefix + "/" + item.name
                if item.isDirectory {
                    try await visit(item.path, prefix: relative)
                } else {
                    out.append((relative, item))
                }
            }
        }
        try await visit(path, prefix: "")
        return out
    }
}

/// The state of one pane: where it is, what it shows, what is selected.
@MainActor
@Observable
final class PaneModel: Identifiable {
    enum SortKey: String, CaseIterable { case name, size, modified }

    /// A folder load, and what it does to Back history when it lands.
    private struct Navigation: Equatable {
        enum History { case push, back, none }
        var path: String
        /// `.push`: the folder being left goes onto Back history. `.back`: `goBack` already took `path` off it.
        var history: History
    }

    let id = UUID()
    private(set) var backend: any FileSystemBackend
    private(set) var path = "/"
    private(set) var items: [FileItem] = []
    var selection: Set<String> = []
    private(set) var isLoading = false
    private(set) var error: String?
    var showHidden = false
    var sortKey: SortKey = .name
    var sortAscending = true
    /// Called after an operation changed folders on this pane's side, so the window can refresh the other pane.
    @ObservationIgnored var onFoldersChanged: ((PaneSource, Set<String>) -> Void)?
    private var history: [String] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The load in flight. Each load takes a new generation; only the newest one may write its result.
    @ObservationIgnored private var pending: Navigation?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var watchedPath: String?
    @ObservationIgnored private var isStopped = false

    init(backend: any FileSystemBackend) {
        self.backend = backend
        watcher = DirectoryWatcher { [weak self] in self?.folderDidChange() }
    }

    var source: PaneSource { backend.source }
    var title: String { backend.displayName }

    var visibleItems: [FileItem] {
        let filtered = showHidden ? items : items.filter { !$0.isHidden }
        return filtered.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let result: Bool
            switch sortKey {
            case .name: result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: result = (a.size ?? -1) < (b.size ?? -1)
            case .modified: result = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            }
            return sortAscending ? result : !result
        }
    }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.path) }
    }

    func switchBackend(_ backend: any FileSystemBackend) {
        cancelLoad()
        self.backend = backend
        items = []
        selection = []
        history = []
        error = nil
        watch(nil)
        Task { await loadHome(history: .none) }
    }

    /// Stops loading and watching for good: the window is closing.
    func stop() {
        isStopped = true
        cancelLoad()
        watch(nil)
    }

    // MARK: Navigation

    func goHome() async {
        await loadHome(history: .push)
    }

    private func loadHome(history: Navigation.History) async {
        let backend = backend
        do {
            let home = try await backend.homePath()
            guard backend === self.backend else { return }
            await start(Navigation(path: home, history: history))
        } catch {
            guard backend === self.backend else { return }
            self.error = error.localizedDescription
        }
    }

    func load(_ newPath: String) async {
        await start(Navigation(path: newPath, history: .push))
    }

    /// Reloads the folder being opened if a navigation is still loading, otherwise the current one. Keeps the
    /// selection of items that still exist and leaves Back history alone.
    func refresh() async {
        await start(pending ?? Navigation(path: path, history: .none))
    }

    func goUp() async {
        await load(backend.parent(path))
    }

    func goBack() async {
        guard let previous = history.popLast() else { return }
        await start(Navigation(path: previous, history: .back))
    }

    func open(_ item: FileItem) async {
        guard item.isDirectory else { return }
        await load(item.path)
    }

    /// Lists `navigation.path` and shows it, unless a newer load or a backend switch takes over first. Returns when
    /// this load finished or was superseded.
    private func start(_ navigation: Navigation, showsProgress: Bool = true) async {
        guard !isStopped else { return }
        if let superseded = pending, superseded.history == .back, navigation.history == .push {
            history.append(superseded.path) // that Back never happened
        }
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let backend = backend
        pending = navigation
        if showsProgress { isLoading = true }
        let task = Task { [weak self] in
            let result: Result<[FileItem], any Error>
            do {
                result = .success(try await backend.list(navigation.path))
            } catch {
                result = .failure(error)
            }
            self?.finish(navigation, generation: generation, result: result)
        }
        loadTask = task
        await task.value
    }

    private func finish(_ navigation: Navigation, generation: Int, result: Result<[FileItem], any Error>) {
        guard generation == loadGeneration else { return } // superseded: the newer load owns the state now
        pending = nil
        loadTask = nil
        isLoading = false
        switch result {
        case .success(let listed):
            if navigation.history == .push, navigation.path != path { history.append(path) }
            path = navigation.path
            items = listed
            let paths = Set(listed.map(\.path))
            selection = selection.filter { paths.contains($0) }
            error = nil
            watch(source == .local ? path : nil)
        case .failure(let failure):
            if navigation.history == .back { history.append(navigation.path) }
            error = failure.localizedDescription
        }
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        pending = nil
        isLoading = false
    }

    // MARK: Watching local folders

    private func watch(_ folder: String?) {
        guard folder != watchedPath else { return }
        watchedPath = folder
        watcher?.watch(folder)
    }

    /// Something in the watched folder changed: reload it quietly, unless the pane is already on its way elsewhere.
    private func folderDidChange() {
        guard source == .local, pending == nil, watchedPath == path else { return }
        Task { await start(Navigation(path: path, history: .none), showsProgress: false) }
    }

    // MARK: Operations

    /// Selects `paths`. While a load is in flight the selection is kept as is and that load trims it.
    func select(_ paths: [String]) {
        let wanted = Set(paths)
        selection = pending == nil ? wanted.filter { id in items.contains { $0.path == id } } : wanted
    }

    func makeDirectory(named name: String) async {
        let backend = backend
        let target = backend.join(path, name)
        do {
            try await backend.makeDirectory(target)
            operationMessage = nil
        } catch {
            operationMessage = "Could not create the folder “\(name)”: \(Self.describe(error))"
            return
        }
        await finishOperation(changing: [backend.parent(target)], on: backend, select: [target])
    }

    func rename(_ item: FileItem, to name: String) async {
        guard name != item.name else {
            operationMessage = nil
            return
        }
        let backend = backend
        let folder = backend.parent(item.path)
        let target = backend.join(folder, name)
        do {
            try await backend.rename(item.path, to: target)
            operationMessage = nil
        } catch {
            operationMessage = "Could not rename “\(item.name)”: \(Self.describe(error))"
            return
        }
        await finishOperation(changing: [folder], on: backend, select: [target])
    }

    func delete(_ items: [FileItem]) async {
        let backend = backend
        var failures: [Failure] = []
        for item in items {
            do {
                try await backend.delete(item)
            } catch {
                failures.append(Failure(name: item.name, error: error))
            }
        }
        report(failures, verb: "delete", of: items.count)
        await finishOperation(changing: Set(items.map { backend.parent($0.path) }), on: backend)
    }

    func setMode(_ mode: UInt32, for items: [FileItem]) async {
        let backend = backend
        var failures: [Failure] = []
        for item in items {
            do {
                try await backend.setMode(mode, path: item.path)
            } catch {
                failures.append(Failure(name: item.name, error: error))
            }
        }
        report(failures, verb: "change permissions for", of: items.count)
        await finishOperation(changing: Set(items.map { backend.parent($0.path) }), on: backend)
    }

    /// Refreshes after an operation, selects what it made, and tells the window which folders changed.
    private func finishOperation(changing folders: Set<String>, on backend: any FileSystemBackend, select paths: [String] = []) async {
        await refresh()
        if !paths.isEmpty, backend === self.backend { select(paths) }
        onFoldersChanged?(backend.source, folders)
    }

    private struct Failure {
        var name: String
        var reason: String

        init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }

        init(name: String, error: any Error) {
            self.init(name: name, reason: PaneModel.describe(error))
        }
    }

    /// Puts an operation's failures into `operationMessage` (nil when there were none).
    private func report(_ failures: [Failure], verb: String, of total: Int) {
        guard let first = failures.first else {
            operationMessage = nil
            return
        }
        operationMessage = failures.count == 1
            ? "Could not \(verb) “\(first.name)”: \(first.reason)"
            : "Could not \(verb) \(failures.count) of \(total) items. “\(first.name)”: \(first.reason)"
    }

    /// A short reason for an error, as a sentence.
    nonisolated static func describe(_ error: any Error) -> String {
        if let posix = error as? POSIXError, posix.code == .EEXIST {
            return "An item with that name already exists."
        }
        let text = error.localizedDescription
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }

    // CONTRACT (stream reachly-files-model implements these; stream reachly-files-ui calls them).

    /// The last file operation's failure (create, rename, delete, move, duplicate, permissions, paste), shown under
    /// the panes. Never cleared by a load or refresh; the next operation replaces it (nil when it succeeds).
    /// `error` stays for listing failures only (the overlay with Try Again).
    private(set) var operationMessage: String?

    /// Creates an empty file called `name` in the current folder, then selects it.
    func createFile(named name: String) async {
        operationMessage = "New File is not available yet."
    }

    /// Copies each item next to itself, named with `FileNaming.copyName`.
    func duplicate(_ items: [FileItem]) async {
        operationMessage = "Duplicate is not available yet."
    }

    /// Moves the items into `directory` on the same side: an absolute path, or one relative to the current folder.
    func move(_ items: [FileItem], toDirectory directory: String) async {
        operationMessage = "Move is not available yet."
    }
}

/// What a drag between panes carries: the source pane and the dragged paths.
struct DragPayload: Codable {
    static let prefix = "reachly-files:"
    var paneID: UUID
    var paths: [String]

    var encoded: String {
        Self.prefix + (String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "")
    }

    static func decode(_ text: String) -> DragPayload? {
        guard text.hasPrefix(prefix) else { return nil }
        return try? JSONDecoder().decode(DragPayload.self, from: Data(text.dropFirst(prefix.count).utf8))
    }
}
