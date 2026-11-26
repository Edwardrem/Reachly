import Foundation
import NIOCore
import Synchronization

/// An SFTP session on an `SSHConnection`: directory listings, file metadata,
/// and pipelined uploads and downloads with progress and resume.
///
/// Requests are matched to replies by id, so several can be in flight; the
/// transfer methods keep a window of reads or writes outstanding to fill the
/// pipe. Every method is safe to call from any task.
public final class SFTPClient: @unchecked Sendable {
    public typealias Progress = @Sendable (_ transferred: Int64, _ total: Int64?) -> Void

    /// Bytes per read or write request; OpenSSH accepts up to 256 KiB but 32 KiB is the safe interoperable size.
    public static let chunkSize = 32 * 1024
    /// Requests kept in flight during a transfer.
    public static let pipelineDepth = 16

    public let connection: SSHConnection
    private let channel: Channel
    private let handler: SFTPResponseHandler
    private let nextID = Mutex<UInt32>(0)

    private init(connection: SSHConnection, channel: Channel, handler: SFTPResponseHandler) {
        self.connection = connection
        self.channel = channel
        self.handler = handler
    }

    public var isOpen: Bool { channel.isActive }

    /// Starts the `sftp` subsystem and negotiates version 3. Throws `SFTP.Error.unavailable` when the server
    /// refuses the subsystem, and gives up when the server doesn't answer the request or the handshake within
    /// `timeout`.
    public static func open(on connection: SSHConnection, timeout: TimeAmount = .seconds(20)) async throws -> SFTPClient {
        let handler = SFTPResponseHandler()
        let channel: Channel
        do {
            channel = try await connection.openSubsystem("sftp", timeout: timeout) { child in
                try child.pipeline.syncOperations.addHandler(handler)
            }
        } catch SSHClientError.subsystemUnavailable {
            throw SFTP.Error.unavailable
        }
        let client = SFTPClient(connection: connection, channel: channel, handler: handler)
        // A backstop: a server that took the subsystem but never answers would leave the caller waiting.
        let deadline = channel.eventLoop.scheduleTask(in: timeout) {
            handler.fail(id: SFTPResponseHandler.versionKey, error: SFTP.Error.protocolError("no answer to the handshake within \(timeout.nanoseconds / 1_000_000_000) seconds"))
        }
        defer { deadline.cancel() }
        do {
            var writer = SFTPWriter()
            writer.writeUInt8(SFTP.PacketType.initialize.rawValue)
            writer.writeUInt32(SFTP.protocolVersion)
            let reply = try await client.send(writer, expectingVersion: true)
            var reader = SFTPReader(reply)
            guard try reader.readUInt8() == SFTP.PacketType.version.rawValue else { throw SFTP.Error.protocolError("expected SSH_FXP_VERSION") }
            let version = try reader.readUInt32()
            guard version >= 3 else { throw SFTP.Error.unsupportedVersion(version) }
        } catch {
            client.close()
            throw error
        }
        return client
    }

    public func close() {
        handler.failAll(SFTP.Error.closed)
        channel.close(promise: nil)
    }

    // MARK: Requests

    private func allocateID() -> UInt32 {
        nextID.withLock { id in
            id &+= 1
            return id
        }
    }

    /// Sends a packet and waits for its reply. For INIT the reply has no id.
    private func send(_ writer: SFTPWriter, expectingVersion: Bool = false, id: UInt32? = nil) async throws -> [UInt8] {
        guard channel.isActive else { throw SFTP.Error.closed }
        let framed = writer.framed()
        let key: UInt32 = expectingVersion ? SFTPResponseHandler.versionKey : (id ?? 0)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Swift.Error>) in
                handler.register(id: key, continuation: continuation)
                var buffer = channel.allocator.buffer(capacity: framed.count)
                buffer.writeBytes(framed)
                channel.writeAndFlush(buffer).whenFailure { [handler] error in
                    handler.fail(id: key, error: error)
                }
            }
        } onCancel: {
            handler.fail(id: key, error: CancellationError())
        }
    }

    private func request(_ type: SFTP.PacketType, _ body: (inout SFTPWriter) -> Void) async throws -> (SFTP.PacketType, SFTPReader) {
        let id = allocateID()
        var writer = SFTPWriter()
        writer.writeUInt8(type.rawValue)
        writer.writeUInt32(id)
        body(&writer)
        let reply = try await send(writer, id: id)
        var reader = SFTPReader(reply)
        guard let replyType = SFTP.PacketType(rawValue: try reader.readUInt8()) else { throw SFTP.Error.protocolError("unknown reply type") }
        _ = try reader.readUInt32() // id, already matched
        return (replyType, reader)
    }

    /// Reads a status reply; throws unless it is OK (or `allowEOF` and EOF).
    private func expectStatus(_ type: SFTP.PacketType, _ reader: inout SFTPReader, path: String?, allowEOF: Bool = false) throws -> SFTP.StatusCode {
        guard type == .status else { throw SFTP.Error.protocolError("expected SSH_FXP_STATUS, got \(type)") }
        let code = SFTP.StatusCode(rawValue: try reader.readUInt32()) ?? .failure
        let message = (try? reader.readString()) ?? ""
        if code == .ok || (allowEOF && code == .eof) { return code }
        throw SFTP.Error.status(code, message, path: path)
    }

    private func expectAttributes(_ type: SFTP.PacketType, _ reader: inout SFTPReader, path: String) throws -> SFTP.Attributes {
        switch type {
        case .attrs: return try SFTP.Attributes.decode(from: &reader)
        case .status: _ = try expectStatus(type, &reader, path: path); throw SFTP.Error.protocolError("status instead of attributes")
        default: throw SFTP.Error.protocolError("expected SSH_FXP_ATTRS, got \(type)")
        }
    }

    private func expectHandle(_ type: SFTP.PacketType, _ reader: inout SFTPReader, path: String) throws -> [UInt8] {
        switch type {
        case .handle: return try reader.readBytes()
        case .status: _ = try expectStatus(type, &reader, path: path); throw SFTP.Error.protocolError("status instead of handle")
        default: throw SFTP.Error.protocolError("expected SSH_FXP_HANDLE, got \(type)")
        }
    }

    // MARK: Metadata

    public func realPath(_ path: String) async throws -> String {
        let (type, reply) = try await request(.realpath) { $0.writeString(path) }
        var reader = reply
        switch type {
        case .name:
            _ = try reader.readUInt32()
            return try reader.readString()
        default:
            _ = try expectStatus(type, &reader, path: path)
            throw SFTP.Error.protocolError("status instead of name")
        }
    }

    public func stat(_ path: String) async throws -> SFTP.Attributes {
        let (type, reply) = try await request(.stat) { $0.writeString(path) }
        var reader = reply
        return try expectAttributes(type, &reader, path: path)
    }

    public func lstat(_ path: String) async throws -> SFTP.Attributes {
        let (type, reply) = try await request(.lstat) { $0.writeString(path) }
        var reader = reply
        return try expectAttributes(type, &reader, path: path)
    }

    public func setAttributes(_ attributes: SFTP.Attributes, path: String) async throws {
        let (type, reply) = try await request(.setstat) { writer in
            writer.writeString(path)
            attributes.encode(into: &writer)
        }
        var reader = reply
        _ = try expectStatus(type, &reader, path: path)
    }

    public func setPermissions(_ mode: UInt32, path: String) async throws {
        try await setAttributes(SFTP.Attributes(permissions: mode & 0o7777), path: path)
    }

    public func readLink(_ path: String) async throws -> String {
        let (type, reply) = try await request(.readlink) { $0.writeString(path) }
        var reader = reply
        guard type == .name else {
            _ = try expectStatus(type, &reader, path: path)
            throw SFTP.Error.protocolError("status instead of name")
        }
        _ = try reader.readUInt32()
        return try reader.readString()
    }

    public func symlink(target: String, at path: String) async throws {
        // OpenSSH reverses the documented argument order; it is what every client sends.
        let (type, reply) = try await request(.symlink) { writer in
            writer.writeString(target)
            writer.writeString(path)
        }
        var reader = reply
        _ = try expectStatus(type, &reader, path: path)
    }

    // MARK: Directories

    public func listDirectory(_ path: String) async throws -> [SFTP.Entry] {
        let (openType, openReply) = try await request(.opendir) { $0.writeString(path) }
        var openReader = openReply
        let handle = try expectHandle(openType, &openReader, path: path)
        var entries: [SFTP.Entry] = []
        defer { Task { try? await self.closeHandle(handle) } }
        while true {
            let (type, reply) = try await request(.readdir) { $0.writeBytes(handle) }
            var reader = reply
            if type == .status {
                _ = try expectStatus(type, &reader, path: path, allowEOF: true)
                break
            }
            guard type == .name else { throw SFTP.Error.protocolError("expected SSH_FXP_NAME") }
            let count = try reader.readUInt32()
            for _ in 0..<count {
                let name = try reader.readString()
                let longName = try reader.readString()
                let attributes = try SFTP.Attributes.decode(from: &reader)
                if name == "." || name == ".." { continue }
                entries.append(SFTP.Entry(name: name, longName: longName, attributes: attributes))
            }
        }
        return entries
    }

    public func makeDirectory(_ path: String, mode: UInt32? = nil) async throws {
        let (type, reply) = try await request(.mkdir) { writer in
            writer.writeString(path)
            SFTP.Attributes(permissions: mode).encode(into: &writer)
        }
        var reader = reply
        _ = try expectStatus(type, &reader, path: path)
    }

    public func removeDirectory(_ path: String) async throws {
        let (type, reply) = try await request(.rmdir) { $0.writeString(path) }
        var reader = reply
        _ = try expectStatus(type, &reader, path: path)
    }

    public func remove(_ path: String) async throws {
        let (type, reply) = try await request(.remove) { $0.writeString(path) }
        var reader = reply
        _ = try expectStatus(type, &reader, path: path)
    }

    public func rename(_ path: String, to newPath: String) async throws {
        let (type, reply) = try await request(.rename) { writer in
            writer.writeString(path)
            writer.writeString(newPath)
        }
        var reader = reply
        _ = try expectStatus(type, &reader, path: path)
    }

    /// Deletes a file, or a directory and everything in it.
    public func removeRecursively(_ path: String) async throws {
        let attributes = try await lstat(path)
        guard attributes.isDirectory else {
            try await remove(path)
            return
        }
        for entry in try await listDirectory(path) {
            try Task.checkCancellation()
            try await removeRecursively(SFTP.join(path, entry.name))
        }
        try await removeDirectory(path)
    }

    // CONTRACT (stream reachly-sftp-client implements these; the signatures are fixed).

    /// Creates an empty file at `path`. Fails if anything already exists there: never truncates or replaces.
    public func createFile(_ path: String, mode: UInt32? = nil) async throws {
        // CREAT|EXCL is atomic on the server and refuses an existing file, folder or symlink, even a dangling one.
        let handle = try await createExclusively(path, mode: mode)
        try await closeHandle(handle)
    }

    /// Copies a file, or a folder and everything in it, to `newPath` on the same server, streaming the bytes
    /// through this client (SFTP v3 has no server-side copy). Never overwrites: fails before writing anything when
    /// `newPath` exists. Symlinks are recreated as symlinks, not followed. Permissions are kept. Cancellable; on
    /// failure or cancellation the partial copy is removed.
    ///
    /// Modification times are kept too. `progress` gets the bytes copied so far and the total size of the files.
    /// Sockets, devices and pipes inside a folder are skipped, as SFTP can't make them.
    public func copyItem(_ path: String, to newPath: String, progress: Progress? = nil) async throws {
        let source = try await lstat(path)
        if source.kind == .other {
            throw SFTP.Error.status(.opUnsupported, "Only files, folders and symlinks can be copied", path: path)
        }
        if source.isDirectory, try await isSameOrInside(newPath, folder: path) {
            throw SFTP.Error.status(.failure, "A folder can't be copied into itself", path: newPath)
        }
        if let clash = await existsError(at: newPath) { throw clash }

        // Read the whole tree before creating anything, so an unreadable folder fails without leaving a half copy.
        let entries = source.isDirectory ? try await copyEntries(in: path) : []
        let total = ([source] + entries.map(\.attributes)).reduce(Int64(0)) { sum, attributes in
            attributes.kind == .regular ? sum + Int64(clamping: attributes.size ?? 0) : sum
        }
        var copied: Int64 = 0
        progress?(0, total)
        let report: (Int64) -> Void = { bytes in
            copied += bytes
            progress?(copied, total)
        }
        try Task.checkCancellation()

        // Creating `newPath` is the first write, and it is atomic (an EXCL open, mkdir or symlink): a clash that
        // appeared since the check above fails here, and nothing that was already there is touched or removed.
        // Everything after it lives under `newPath`, so removing `newPath` undoes it.
        switch source.kind {
        case .symlink:
            let target = try await readLink(path)
            try await creating(newPath) { try await self.symlink(target: target, at: newPath) }
        case .regular:
            let handle = try await createExclusively(newPath, mode: 0o600)
            do {
                try await fill(handle, at: newPath, from: path, attributes: source, progress: report)
            } catch {
                await removePartialCopy(newPath)
                throw error
            }
        case .directory:
            try await creating(newPath) { try await self.makeDirectory(newPath, mode: 0o700) }
            do {
                try await copyContents(entries, from: path, to: newPath, rootAttributes: source, progress: report)
            } catch {
                await removePartialCopy(newPath)
                throw error
            }
        case .other:
            return
        }
        progress?(copied, total)
    }

    // MARK: Copy helpers

    /// One item below the folder being copied; parents come before their children.
    private struct CopyEntry {
        var relativePath: String
        var attributes: SFTP.Attributes
    }

    private func copyEntries(in folder: String, relativeTo base: String = "") async throws -> [CopyEntry] {
        var entries: [CopyEntry] = []
        for entry in try await listDirectory(folder).sorted(by: { $0.name < $1.name }) {
            try Task.checkCancellation()
            let relative = base.isEmpty ? entry.name : base + "/" + entry.name
            let full = SFTP.join(folder, entry.name)
            // Servers send lstat-style attributes in a listing; ask when the type is missing.
            let attributes = entry.attributes.permissions == nil ? try await lstat(full) : entry.attributes
            entries.append(CopyEntry(relativePath: relative, attributes: attributes))
            if attributes.isDirectory {
                entries += try await copyEntries(in: full, relativeTo: relative)
            }
        }
        return entries
    }

    /// Copies everything under a folder into the new, empty `newPath`. Folders stay writable while their contents
    /// arrive; their own permissions and dates are set last, deepest first, so a read-only folder doesn't block
    /// its children.
    private func copyContents(_ entries: [CopyEntry], from path: String, to newPath: String, rootAttributes: SFTP.Attributes, progress: (Int64) -> Void) async throws {
        var folders: [(path: String, attributes: SFTP.Attributes)] = [(newPath, rootAttributes)]
        for entry in entries {
            try Task.checkCancellation()
            let from = SFTP.join(path, entry.relativePath)
            let to = SFTP.join(newPath, entry.relativePath)
            switch entry.attributes.kind {
            case .directory:
                try await makeDirectory(to, mode: 0o700)
                folders.append((to, entry.attributes))
            case .regular:
                let handle = try await createExclusively(to, mode: 0o600)
                try await fill(handle, at: to, from: from, attributes: entry.attributes, progress: progress)
            case .symlink:
                try await symlink(target: readLink(from), at: to)
            case .other:
                continue
            }
        }
        for folder in folders.reversed() {
            try Task.checkCancellation()
            try await setAttributes(Self.keptAttributes(folder.attributes), path: folder.path)
        }
    }

    /// Streams `path` into the new file open as `handle`, closes it, then gives it the source's permissions and
    /// dates. The handle is closed on failure too.
    private func fill(_ handle: [UInt8], at newPath: String, from path: String, attributes: SFTP.Attributes, progress: (Int64) -> Void) async throws {
        do {
            try await stream(path, into: handle, size: attributes.size, progress: progress)
        } catch {
            await closeQuietly(handle)
            throw error
        }
        try await closeHandle(handle)
        try Task.checkCancellation()
        try await setAttributes(Self.keptAttributes(attributes), path: newPath)
    }

    /// Copies the bytes of `path` into the open `target`, `pipelineDepth` chunks of `chunkSize` at a time, so
    /// memory stays at 512 KiB however large the file is.
    private func stream(_ path: String, into target: [UInt8], size: UInt64?, progress: (Int64) -> Void) async throws {
        let source = try await uncancelled { try await self.openFile(path, flags: [.read]) }
        do {
            let chunk = UInt64(Self.chunkSize)
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                // Don't ask far past the known end; one more read there confirms it (the file may have grown).
                var count = Self.pipelineDepth
                if let size {
                    let remaining = size > offset ? size - offset : 0
                    count = Int(max(1, min(UInt64(Self.pipelineDepth), (remaining + chunk - 1) / chunk)))
                }
                let starts = (0..<count).map { offset + UInt64($0) * chunk }
                let chunks = try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { group -> [[UInt8]] in
                    for (index, start) in starts.enumerated() {
                        group.addTask { (index, try await self.read(handle: source, offset: start, length: Self.chunkSize)) }
                    }
                    var results = [[UInt8]](repeating: [], count: starts.count)
                    for try await (index, bytes) in group { results[index] = bytes }
                    return results
                }
                // Keep the chunks up to the first short one: a server may send less than asked before the end, so
                // what follows a short read is read again from where it stopped.
                var writes: [(offset: UInt64, bytes: [UInt8])] = []
                var next = offset
                var ended = false
                for (start, bytes) in zip(starts, chunks) {
                    if bytes.isEmpty {
                        ended = true
                        break
                    }
                    writes.append((start, bytes))
                    next = start + UInt64(bytes.count)
                    if bytes.count < Self.chunkSize { break }
                }
                if !writes.isEmpty {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for write in writes {
                            group.addTask { try await self.write(handle: target, offset: write.offset, data: write.bytes) }
                        }
                        try await group.waitForAll()
                    }
                    progress(Int64(next - offset))
                }
                if ended { break }
                offset = next
            }
        } catch {
            await closeQuietly(source)
            throw error
        }
        await closeQuietly(source)
    }

    /// Opens a new file for writing with CREAT|EXCL. The request isn't abandoned halfway when the task is
    /// cancelled, so the caller always knows whether the file was made (and so is its own to remove).
    private func createExclusively(_ path: String, mode: UInt32?) async throws -> [UInt8] {
        try await creating(path) {
            try await self.openFile(path, flags: [.write, .create, .exclusive], mode: mode)
        }
    }

    /// Runs `create` to completion even if the task is cancelled; when it fails because something is already at
    /// `path`, says so clearly (OpenSSH only answers "Failure").
    private func creating<T: Sendable>(_ path: String, _ create: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await uncancelled(create)
        } catch {
            throw await existsError(at: path) ?? error
        }
    }

    /// Permissions (without the file type) and dates to put on a copy.
    private static func keptAttributes(_ attributes: SFTP.Attributes) -> SFTP.Attributes {
        SFTP.Attributes(permissions: attributes.mode, accessTime: attributes.accessTime, modificationTime: attributes.modificationTime)
    }

    /// A clear error when something (even a dangling symlink) is at `path`, or nil.
    private func existsError(at path: String) async -> SFTP.Error? {
        guard (try? await uncancelled({ try await self.lstat(path) })) != nil else { return nil }
        return .status(.failure, "An item with that name already exists", path: path)
    }

    /// True when `path` would land on `folder` or inside it, following symlinks on the way (the server resolves
    /// both, so "/data/link/x" counts when "/data/link" points into `folder`).
    private func isSameOrInside(_ path: String, folder: String) async throws -> Bool {
        let resolvedFolder = (try? await realPath(folder)) ?? SFTP.normalize(folder)
        let (parent, name) = Self.splitParent(path)
        let resolvedParent = (try? await realPath(parent)) ?? SFTP.normalize(parent)
        let target = SFTP.join(resolvedParent, name)
        return resolvedFolder == "/" || target == resolvedFolder || target.hasPrefix(resolvedFolder + "/")
    }

    /// The folder holding `path` and its last component; "." for a bare name, which is relative to the session's
    /// starting folder.
    private static func splitParent(_ path: String) -> (parent: String, name: String) {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return (".", String(trimmed)) }
        let parent = slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
        return (parent, String(trimmed[trimmed.index(after: slash)...]))
    }

    /// Removes what a failed or cancelled copy made at `path`, even when the copy's task is cancelled. Folders are
    /// made writable first in case their read-only permissions were already set.
    private func removePartialCopy(_ path: String) async {
        _ = try? await uncancelled { try await self.removeCopiedTree(path) }
    }

    private func removeCopiedTree(_ path: String) async throws {
        let attributes = try await lstat(path)
        guard attributes.isDirectory else {
            try await remove(path)
            return
        }
        try? await setPermissions(0o700, path: path)
        for entry in try await listDirectory(path) {
            try? await removeCopiedTree(SFTP.join(path, entry.name))
        }
        try await removeDirectory(path)
    }

    private func closeQuietly(_ handle: [UInt8]) async {
        _ = try? await uncancelled { try await self.closeHandle(handle) }
    }

    /// Runs `body` in a task of its own, so its requests go out and wait for their replies even when the calling
    /// task has been cancelled.
    private func uncancelled<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await body() }.value
    }

    // MARK: Files

    public func openFile(_ path: String, flags: SFTP.OpenFlags, mode: UInt32? = nil) async throws -> [UInt8] {
        let (type, reply) = try await request(.open) { writer in
            writer.writeString(path)
            writer.writeUInt32(flags.rawValue)
            SFTP.Attributes(permissions: mode).encode(into: &writer)
        }
        var reader = reply
        return try expectHandle(type, &reader, path: path)
    }

    public func closeHandle(_ handle: [UInt8]) async throws {
        let (type, reply) = try await request(.close) { $0.writeBytes(handle) }
        var reader = reply
        _ = try expectStatus(type, &reader, path: nil)
    }

    /// Reads up to `length` bytes; empty at end of file.
    public func read(handle: [UInt8], offset: UInt64, length: Int) async throws -> [UInt8] {
        let (type, reply) = try await request(.read) { writer in
            writer.writeBytes(handle)
            writer.writeUInt64(offset)
            writer.writeUInt32(UInt32(length))
        }
        var reader = reply
        switch type {
        case .data: return try reader.readBytes()
        case .status:
            if try expectStatus(type, &reader, path: nil, allowEOF: true) == .eof { return [] }
            return []
        default: throw SFTP.Error.protocolError("expected SSH_FXP_DATA")
        }
    }

    public func write(handle: [UInt8], offset: UInt64, data: [UInt8]) async throws {
        let (type, reply) = try await request(.write) { writer in
            writer.writeBytes(handle)
            writer.writeUInt64(offset)
            writer.writeBytes(data)
        }
        var reader = reply
        _ = try expectStatus(type, &reader, path: nil)
    }

    /// Reads a whole file into memory (for open-with and small previews).
    public func readFile(_ path: String, limit: Int = 64 * 1024 * 1024) async throws -> Data {
        let handle = try await openFile(path, flags: [.read])
        defer { Task { try? await self.closeHandle(handle) } }
        var out = Data()
        var offset: UInt64 = 0
        while out.count < limit {
            let chunk = try await read(handle: handle, offset: offset, length: Self.chunkSize)
            if chunk.isEmpty { break }
            out.append(contentsOf: chunk)
            offset += UInt64(chunk.count)
        }
        return out
    }

    public func writeFile(_ data: Data, to path: String, mode: UInt32? = nil) async throws {
        let handle = try await openFile(path, flags: [.write, .create, .truncate], mode: mode)
        var offset: UInt64 = 0
        let bytes = [UInt8](data)
        while Int(offset) < bytes.count {
            let end = min(Int(offset) + Self.chunkSize, bytes.count)
            try await write(handle: handle, offset: offset, data: Array(bytes[Int(offset)..<end]))
            offset = UInt64(end)
        }
        try await closeHandle(handle)
    }

    // MARK: Transfers

    /// Downloads `remotePath` to `localURL`, with `pipelineDepth` reads in
    /// flight. With `resume`, appends to the existing local file starting at its size.
    /// With `overwrite: .never`, the local file is created with O_CREAT|O_EXCL and a clash fails the download.
    public func download(_ remotePath: String, to localURL: URL, resume: Bool = false, overwrite: Overwrite = .allowed, progress: Progress? = nil) async throws {
        let attributes = try await stat(remotePath)
        let total = attributes.size.map(Int64.init)
        let manager = FileManager.default
        let (file, offset) = try LocalTarget.open(localURL, resume: resume, overwrite: overwrite)
        defer { try? file.close() }
        if resume, let total, Int64(offset) >= total {
            progress?(total, total)
            return
        }
        let handle = try await openFile(remotePath, flags: [.read])
        defer { Task { try? await self.closeHandle(handle) } }

        var transferred = Int64(offset)
        var nextOffset = offset
        var finished = false
        while !finished {
            try Task.checkCancellation()
            let starts = (0..<Self.pipelineDepth).map { nextOffset + UInt64($0 * Self.chunkSize) }
            let chunks = try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { group -> [[UInt8]] in
                for (index, start) in starts.enumerated() {
                    group.addTask { (index, try await self.read(handle: handle, offset: start, length: Self.chunkSize)) }
                }
                var results = [[UInt8]](repeating: [], count: starts.count)
                for try await (index, bytes) in group { results[index] = bytes }
                return results
            }
            for chunk in chunks {
                if chunk.isEmpty {
                    finished = true
                    break
                }
                try file.write(contentsOf: chunk)
                transferred += Int64(chunk.count)
                nextOffset += UInt64(chunk.count)
                progress?(transferred, total)
                if chunk.count < Self.chunkSize {
                    finished = true
                    break
                }
            }
        }
        if let modified = attributes.modificationTime {
            try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: localURL.path)
        }
        progress?(transferred, total ?? transferred)
    }

    /// Uploads `localURL` to `remotePath` with `pipelineDepth` writes in flight.
    /// With `resume`, continues from the remote file's current size.
    /// With `overwrite: .never`, the remote file is created with CREAT|EXCL and a clash fails the upload.
    public func upload(_ localURL: URL, to remotePath: String, resume: Bool = false, mode: UInt32? = nil, overwrite: Overwrite = .allowed, progress: Progress? = nil) async throws {
        let total = Int64((try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        let (handle, start) = try await openUploadTarget(remotePath, resume: resume, mode: mode, total: total, overwrite: overwrite)
        var offset = start
        try file.seek(toOffset: offset)
        var transferred = Int64(offset)
        progress?(transferred, total)
        do {
            while true {
                try Task.checkCancellation()
                var batch: [(UInt64, [UInt8])] = []
                for _ in 0..<Self.pipelineDepth {
                    guard let data = try file.read(upToCount: Self.chunkSize), !data.isEmpty else { break }
                    batch.append((offset, [UInt8](data)))
                    offset += UInt64(data.count)
                }
                if batch.isEmpty { break }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (start, bytes) in batch {
                        group.addTask { try await self.write(handle: handle, offset: start, data: bytes) }
                    }
                    try await group.waitForAll()
                }
                transferred += Int64(batch.reduce(0) { $0 + $1.1.count })
                progress?(transferred, total)
            }
        } catch {
            // Without waiting: a paused or failed transfer shouldn't hang on a server that stopped answering.
            Task { [handle] in try? await self.closeHandle(handle) }
            throw error
        }
        try await closeHandle(handle)
        progress?(transferred, total)
    }

    /// Opens the remote file an upload writes into and the offset to start at.
    private func openUploadTarget(_ path: String, resume: Bool, mode: UInt32?, total: Int64, overwrite: Overwrite) async throws -> (handle: [UInt8], offset: UInt64) {
        guard case .never(let claim) = overwrite else {
            var offset: UInt64 = 0
            if resume, let existing = try? await stat(path).size, Int64(existing) <= total {
                offset = existing
            }
            let flags: SFTP.OpenFlags = offset > 0 ? [.write] : [.write, .create, .truncate]
            return (try await openFile(path, flags: flags, mode: mode), offset)
        }
        if claim.current == .remote(path: path) {
            // The file an earlier attempt of this transfer made: continue it, or start it over.
            do {
                let existing = try await lstat(path)
                guard existing.kind == .regular else { throw Self.alreadyExists(path) }
                var offset: UInt64 = 0
                if resume, let size = existing.size, Int64(size) <= total {
                    offset = size
                }
                let flags: SFTP.OpenFlags = offset > 0 ? [.write] : [.write, .create, .truncate]
                return (try await openFile(path, flags: flags, mode: mode), offset)
            } catch let error as SFTP.Error where error.isNoSuchFile {
                // Removed since: start again with a new file.
            }
        }
        // Atomic on the server, and the request is not abandoned when the task is cancelled, so the claim is
        // recorded whenever the file was made.
        let handle = try await createExclusively(path, mode: mode)
        claim.record(.remote(path: path))
        return (handle, 0)
    }
}

/// Reassembles SFTP packets from the channel and hands each reply to the
/// request that is waiting for it.
final class SFTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    static let versionKey: UInt32 = UInt32.max

    private let pending = Mutex<[UInt32: CheckedContinuation<[UInt8], Swift.Error>]>([:])
    private var framer = SFTPFramer()

    func register(id: UInt32, continuation: CheckedContinuation<[UInt8], Swift.Error>) {
        let duplicate = pending.withLock { table -> CheckedContinuation<[UInt8], Swift.Error>? in
            let existing = table[id]
            table[id] = continuation
            return existing
        }
        duplicate?.resume(throwing: SFTP.Error.protocolError("duplicate request id"))
    }

    func fail(id: UInt32, error: Swift.Error) {
        pending.withLock { $0.removeValue(forKey: id) }?.resume(throwing: error)
    }

    func failAll(_ error: Swift.Error) {
        let all = pending.withLock { table -> [CheckedContinuation<[UInt8], Swift.Error>] in
            let values = Array(table.values)
            table.removeAll()
            return values
        }
        for continuation in all { continuation.resume(throwing: error) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        for packet in framer.feed(bytes) {
            guard let type = packet.first else { continue }
            let id: UInt32
            if type == SFTP.PacketType.version.rawValue {
                id = Self.versionKey
            } else {
                guard packet.count >= 5 else { continue }
                id = UInt32(packet[1]) << 24 | UInt32(packet[2]) << 16 | UInt32(packet[3]) << 8 | UInt32(packet[4])
            }
            pending.withLock { $0.removeValue(forKey: id) }?.resume(returning: packet)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(SFTP.Error.closed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Swift.Error) {
        failAll(error)
        context.close(promise: nil)
    }
}
